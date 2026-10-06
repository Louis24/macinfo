<#
1_mac-ci.ps1 -- deploy to the GitHub-hosted macOS runner: push, wait, download, verify.

Prerequisite: scripts\0_init_local_git.bat (creates .git and the origin remote).
This script may additionally create the *remote* repository through the API when the
owner/name it resolved does not exist yet -- a .bat cannot do that, so it lives here.

Actions (default: build):
  build    ensure the remote repo exists -> commit + push -> wait for macOS -> download -> verify
  status   list recent runs              wait    poll one run until it finishes
  jobs     per-step results of a run     logs    error lines of a run
  download fetch one artifact into the output folder
  verify   compare local SHA256 with the SHA256SUMS produced by CI
  check    read file headers to prove the binaries really are Mach-O / .dmg / .pkg

Examples:
  powershell -ExecutionPolicy Bypass -File .\scripts\1_mac-ci.ps1
  powershell -ExecutionPolicy Bypass -File .\scripts\1_mac-ci.ps1 -m "tweak the dmg"
  powershell -ExecutionPolicy Bypass -File .\scripts\1_mac-ci.ps1 -Action logs -Id 123456

Reads .env.local in the project root (git-ignored):
  GITHUB_TOKEN=ghp_...      classic token with the "repo" scope; creating the remote
                            repository also needs repo-creation permission
  HTTPS_PROXY=http://...    optional, only if you reach GitHub through a proxy
  GITHUB_REPO=owner/name    optional, only used when there is no origin remote

Keep this file ASCII: Windows PowerShell 5.1 decodes .ps1 without a BOM as ANSI/GBK,
so non-ASCII text here breaks parsing. Prose belongs in the markdown docs.
#>
[CmdletBinding()]
param(
    [ValidateSet('build', 'status', 'wait', 'jobs', 'logs', 'download', 'verify', 'check')]
    [string]$Action = 'build',
    [Alias('m')]
    [string]$Msg = '',
    [Alias('i')]
    [string]$Id = '',
    [string]$Out = '',
    [Alias('r')]
    [string]$RepoOverride = '',
    [switch]$Force,
    # cmd.exe sometimes drops the quotes around a multi-word argument, which would make
    # "-Msg one two three" fail parameter binding. Collect the leftovers and rejoin them.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)
$ErrorActionPreference = 'Stop'
if (-not $Msg) { $Msg = 'Rebuild ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
if ($Rest -and $Rest.Count -gt 0) { $Msg = ($Msg + ' ' + ($Rest -join ' ')).Trim() }

function Show-Section($Title) { Write-Output ("`n" + ('=' * 60) + "`n  $Title`n" + ('=' * 60)) }

# ------------------------------------------------------------------ config
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
if (-not $Out) { $Out = Join-Path $root 'artifacts' }

$conf = @{}
$envFile = Join-Path $root '.env.local'
if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match '=' } | ForEach-Object {
        $i = $_.IndexOf('=')
        $conf[$_.Substring(0, $i).Trim()] = $_.Substring($i + 1).Trim()
    }
}
$Token = if ($conf['GITHUB_TOKEN']) { $conf['GITHUB_TOKEN'] } else { $env:GITHUB_TOKEN }
$Proxy = if ($conf['HTTPS_PROXY']) { $conf['HTTPS_PROXY'] } elseif ($env:HTTPS_PROXY) { $env:HTTPS_PROXY } else { '' }
if (-not $Token) { throw 'no GITHUB_TOKEN (put it in .env.local or set it in the environment)' }

$Api = 'https://api.github.com'
$Hdr = @{ Authorization = "token $Token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'mac-ci' }

function Invoke-Api {
    param($Uri, $Method = 'GET', $Body = $null, $OutFile = $null, $TimeoutSec = 90)
    $call = @{ Uri = $Uri; Method = $Method; Headers = $Hdr; TimeoutSec = $TimeoutSec }
    if ($Proxy) { $call['Proxy'] = $Proxy }
    if ($null -ne $Body) {
        $call['Body'] = ($Body | ConvertTo-Json -Depth 8)
        $call['ContentType'] = 'application/json'
    }
    if ($OutFile) { $call['OutFile'] = $OutFile; return Invoke-WebRequest @call }
    return Invoke-RestMethod @call
}
function Get-ApiStatus($ErrorRecord) {
    try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return 0 }
}
function Redact($Text) { return ($Text -replace [regex]::Escape($Token), '***') }

# git writes progress and errors to stderr, which PowerShell 5.1 turns into red
# NativeCommandError records even when the command succeeded. Everything goes through
# this helper so both streams land in the return value and the exit code survives.
function Invoke-Git {
    param([string[]]$GitArgs, [switch]$Show)
    if ($Show) { Write-Output ('+ git ' + ($GitArgs -join ' ')) }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = & git @GitArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    $lines = @($raw | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}
function Invoke-GitOrThrow {
    param([string[]]$GitArgs, [switch]$Show)
    $r = Invoke-Git -GitArgs $GitArgs -Show:$Show
    if ($r.Code -ne 0) { throw ('git ' + ($GitArgs -join ' ') + ' failed: ' + (Redact ($r.Text -replace '\s+', ' ').Trim())) }
    return $r
}
function Get-GitOutput {
    param([string[]]$GitArgs)
    $r = Invoke-Git -GitArgs $GitArgs
    if ($r.Code -ne 0) { return '' }
    return (@($r.Lines | Where-Object { $_.Trim() }) -join "`n").Trim()
}

# ------------------------------------------------------------------ repo wiring
function Get-GitHubLogin {
    if ($script:Login) { return $script:Login }
    try { $script:Login = (Invoke-Api "$Api/user").login }
    catch { throw ('GITHUB_TOKEN is not usable (HTTP ' + (Get-ApiStatus $_) + ' from /user): ' + $_.Exception.Message) }
    return $script:Login
}

function Resolve-Repo {
    param([string]$Override)
    if ($Override) { return $Override }
    if ($conf['GITHUB_REPO']) { return $conf['GITHUB_REPO'] }
    $url = Get-GitOutput @('remote', 'get-url', 'origin')
    if ($url -match 'github\.com[:/]+([^/]+)/([^/.]+)') { return "$($matches[1])/$($matches[2])" }
    throw "cannot work out the GitHub repo: run scripts\0_init_local_git.bat or set GITHUB_REPO in .env.local"
}

function Ensure-Remote([string]$Slug) {
    $parts = $Slug.Split('/')
    if ($parts.Count -ne 2) { throw "expected owner/name as the repo slug, got '$Slug'" }
    $owner, $name = $parts

    $exists = $true
    try { Invoke-Api "$Api/repos/$Slug" | Out-Null }
    catch {
        $status = Get-ApiStatus $_
        # 409 = repository exists but has no commit yet
        if ($status -eq 404) { $exists = $false }
        elseif ($status -ne 409) { throw "HTTP $status from GET /repos/$Slug - check the token scope" }
    }

    if (-not $exists) {
        if ($owner -ne (Get-GitHubLogin)) {
            throw "remote repository $Slug does not exist; this token can only create repos for $(Get-GitHubLogin), not for '$owner'"
        }
        Show-Section "CREATE REMOTE REPO $Slug (public)"
        Invoke-Api "$Api/user/repos" -Method Post -Body @{
            name        = $name
            private     = $false
            description = 'C++ macOS app built from a Windows machine by GitHub Actions'
            has_wiki    = $false
        } | Out-Null
    }

    # origin stores the clean URL: the token is injected per push and never persisted
    $clean = "https://github.com/$Slug.git"
    $current = Get-GitOutput @('remote', 'get-url', 'origin')
    if (-not $current) { Invoke-GitOrThrow @('remote', 'add', 'origin', $clean) -Show }
    elseif ($current.Trim() -ne $clean) { Invoke-GitOrThrow @('remote', 'set-url', 'origin', $clean) -Show }
}

# ------------------------------------------------------------------ ci helpers
function Show-RunTable($Runs) {
    foreach ($r in $Runs) {
        Write-Output ("run={0} status={1} conclusion={2} branch={3} title={4}" -f `
                $r.id, $r.status, $r.conclusion, $r.head_branch, $r.name)
        Write-Output ("     {0}" -f $r.html_url)
    }
}

function Wait-Run([long]$RunId) {
    for ($i = 0; $i -lt 60; $i++) {
        $r = Invoke-Api "$Api/repos/$Repo/actions/runs/$RunId"
        Write-Output ("  [{0,2}] status={1} conclusion={2}" -f $i, $r.status, $r.conclusion)
        if ($r.status -eq 'completed') { return $r }
        Start-Sleep -Seconds 15
    }
    throw "run $RunId still running after 15 minutes"
}

function Show-Failure([long]$RunId) {
    Show-Section 'BUILD FAILED - details'
    $jobs = Invoke-Api "$Api/repos/$Repo/actions/runs/$RunId/jobs"
    foreach ($job in $jobs.jobs) {
        foreach ($s in $job.steps) {
            if ($s.conclusion -eq 'failure') { Write-Output ("  failing step: {0}" -f $s.name) }
        }
    }
    $resp = Invoke-Api "$Api/repos/$Repo/actions/runs/$RunId/logs" -TimeoutSec 180
    $lz = Join-Path $env:TEMP "maclogs_$RunId.zip"
    [IO.File]::WriteAllBytes($lz, $resp.Content)
    $ld = Join-Path $env:TEMP "maclogs_$RunId"
    if (Test-Path $ld) { Remove-Item $ld -Recurse -Force }
    Expand-Archive -Path $lz -DestinationPath $ld -Force
    Get-ChildItem "$ld\*\*.txt" | ForEach-Object {
        $hits = Get-Content $_.FullName | Where-Object { $_ -match 'error|unrecognized|No rule|unable|failed|rejected' }
        if ($hits) {
            Write-Output "----- $($_.Name)"
            $hits | Select-Object -Last 8 | ForEach-Object { Write-Output "  $_" }
        }
    }
    Write-Output "full logs: $ld"
}

function Get-Artifact([long]$RunId) {
    $arts = Invoke-Api "$Api/repos/$Repo/actions/runs/$RunId/artifacts"
    if ($arts.artifacts.Count -eq 0) { throw 'this run produced no artifact' }
    return $arts.artifacts[0]
}

function Save-Artifact($Art) {
    $zip = Join-Path $env:TEMP "macartifact_$($Art.id).zip"
    Invoke-Api $Art.archive_download_url -OutFile $zip -TimeoutSec 600 | Out-Null
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    Expand-Archive -Path $zip -DestinationPath $Out -Force
    Write-Output ("artifact: {0}  {1} KB  -> {2}" -f $Art.name, [math]::Round($Art.size_in_bytes / 1kb, 1), $Out)
}

function Invoke-Verify {
    Show-Section 'VERIFY SHA256 (local vs CI)'
    $sumFile = Join-Path $Out 'SHA256SUMS'
    if (-not (Test-Path $sumFile)) { Write-Output '  SHA256SUMS not found, nothing to compare'; return }
    $sums = @{}
    Get-Content $sumFile | ForEach-Object {
        if ($_ -match '^([0-9a-f]{64})\s+\*?(.+)$') { $sums[$matches[2].Trim()] = $matches[1].ToLower() }
    }
    foreach ($name in $sums.Keys) {
        $f = Join-Path $Out $name
        if (-not (Test-Path $f)) { Write-Output ("  {0,-22} MISSING" -f $name); continue }
        $h = (Get-FileHash -Algorithm SHA256 -Path $f).Hash.ToLower()
        $verdict = if ($h -eq $sums[$name]) { 'MATCH' } else { 'MISMATCH' }
        Write-Output ("  {0,-22} {1,9} B  {2}" -f $name, (Get-Item $f).Length, $verdict)
    }
}

function Read-BE32($Bytes, [int]$Offset) {
    $q = @($Bytes[$Offset], $Bytes[$Offset + 1], $Bytes[$Offset + 2], $Bytes[$Offset + 3])
    [array]::Reverse($q)
    return [BitConverter]::ToUInt32($q, 0)
}

function Format-FileKind($Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 8) { return 'too small' }
    $magic = ($bytes[0..3] | ForEach-Object { $_.ToString('X2') }) -join ''
    switch ($magic) {
        'CAFEBABE' {
            $list = @()
            for ($i = 0; $i -lt 8; $i++) {
                $off = 8 + $i * 20
                if ($off + 4 -gt $bytes.Length) { break }
                $cpu = Read-BE32 $bytes $off
                if ($cpu -eq 0) { break }
                $list += $(if ($cpu -eq 0x0100000C) { 'arm64' } elseif ($cpu -eq 0x01000007) { 'x86_64' } else { ('cpu=0x{0:X8}' -f $cpu) })
            }
            return ("Mach-O universal [{0}]" -f ($list -join ' + '))
        }
        'CFFAEDFE' {
            $t = [BitConverter]::ToUInt32($bytes, 4)
            $which = $(if ($t -eq 0x0100000C) { 'arm64' } elseif ($t -eq 0x01000007) { 'x86_64' } else { ('0x{0:X}' -f $t) })
            return "Mach-O thin $which"
        }
        '78617221' { return 'xar archive = .pkg installer' }
        '1F8B0800' { return 'gzip (tar.gz)' }
        default {
            if ($bytes.Length -gt 512) {
                $tail = ($bytes[($bytes.Length - 512)..($bytes.Length - 509)] | ForEach-Object { $_.ToString('X2') }) -join ''
                if ($tail -eq '6B6F6C79') { return 'UDIF disk image = .dmg' }
            }
            # printable ASCII head: treat as text (checksums, notes)
            $head = [byte[]]$bytes[0..([Math]::Min(63, $bytes.Length - 1))]
            if (-not ($head | Where-Object { $_ -lt 9 -or ($_ -gt 13 -and $_ -lt 32) })) {
                $line = (([Text.Encoding]::ASCII.GetString($head)) -split "`n")[0].Trim()
                return "text: $line"
            }
            return "unknown (magic $magic)"
        }
    }
}

function Invoke-Check {
    Show-Section 'FILE SIGNATURES IN THE OUTPUT FOLDER'
    Get-ChildItem $Out -File | Sort-Object Name | ForEach-Object {
        Write-Output ("  {0,-24} {1,9} B  {2}" -f $_.Name, $_.Length, (Format-FileKind $_.FullName))
    }
}

function Wait-ForRun([string]$Sha) {
    Write-Output "waiting for a macOS runner to pick up commit $($Sha.Substring(0, 7)) ..."
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 10
        $list = Invoke-Api "$Api/repos/$Repo/actions/runs?head_sha=$Sha"
        if ($list.workflow_runs.Count -gt 0) { return $list.workflow_runs[0] }
    }
    return $null
}

function Complete-Build($Run) {
    if ($null -eq $Run) { throw 'no Actions run appeared for this commit within 5 minutes' }
    Show-Section 'ACTIONS RUN'
    Write-Output "run = $($Run.id)  $($Run.html_url)"
    $Run = Wait-Run ([long]$Run.id)
    if ($Run.conclusion -ne 'success') { Show-Failure ([long]$Run.id); throw 'the build failed' }
    Write-Output 'build succeeded.'
    Show-Section 'DOWNLOAD ARTIFACTS'
    Save-Artifact (Get-Artifact ([long]$Run.id))
    Invoke-Verify
    Invoke-Check
}

# ------------------------------------------------------------------ actions
# The repo slug is resolved lazily: "verify" and "check" work offline on local files.
$Repo = ''

switch ($Action) {
    'status' {
        $Repo = Resolve-Repo $RepoOverride
        Show-Section 'RECENT RUNS'
        Show-RunTable (Invoke-Api "$Api/repos/$Repo/actions/runs?per_page=5").workflow_runs
        break
    }

    'wait' {
        if (-not $Id) { throw '-Id <runId> required' }
        $Repo = Resolve-Repo $RepoOverride
        Wait-Run ([long]$Id) | Out-Null
        break
    }

    'jobs' {
        if (-not $Id) { throw '-Id <runId> required' }
        $Repo = Resolve-Repo $RepoOverride
        Show-Section "STEPS OF RUN $Id"
        $jobs = Invoke-Api "$Api/repos/$Repo/actions/runs/$Id/jobs"
        foreach ($job in $jobs.jobs) {
            Write-Output ("job {0}  {1}" -f $job.name, $job.conclusion)
            foreach ($s in $job.steps) {
                Write-Output ("  {0,-8} {1}" -f $s.conclusion, $s.name)
            }
        }
        break
    }

    'logs' {
        if (-not $Id) { throw '-Id <runId> required' }
        $Repo = Resolve-Repo $RepoOverride
        Show-Failure ([long]$Id)
        break
    }

    'download' {
        if (-not $Id) { throw '-Id <artifactId> required' }
        $Repo = Resolve-Repo $RepoOverride
        Save-Artifact (Invoke-Api "$Api/repos/$Repo/actions/artifacts/$Id")
        Invoke-Verify
        Invoke-Check
        break
    }

    'verify' { Invoke-Verify; break }

    'check' { Invoke-Check; break }

    'build' {
        if (-not (Test-Path (Join-Path $root '.git'))) {
            throw 'no local git repository: run scripts\0_init_local_git.bat first'
        }
        $Repo = Resolve-Repo $RepoOverride
        Ensure-Remote $Repo
        Show-Section "PROJECT $root  ->  github.com/$Repo"

        # .gitignore decides what is excluded; a second whitelist here went stale once already
        Invoke-GitOrThrow @('add', '-A') -Show | Out-Null
        # an unborn HEAD has nothing to diff against, so compare the index to git's empty tree
        $head = Get-GitOutput @('rev-parse', '--verify', '-q', 'HEAD')
        $base = if ($head) { $head } else { '4b825dc642cb6eb9a060e54bf8d69288fbee4904' }
        $staged = @((Get-GitOutput @('diff', '--cached', '--name-only', $base)) -split "`n" | Where-Object { $_ })
        if ($staged.Count -gt 0) {
            Write-Output 'staged files:'
            $staged | ForEach-Object { Write-Output "  $_" }
            # a fresh machine may have no git identity; supply one for this commit only
            # instead of writing into the user's config
            $who = @()
            if (-not (Get-GitOutput @('config', '--get', 'user.email'))) {
                $login = Get-GitHubLogin
                $who = @('-c', "user.name=$login", '-c', "user.email=$login@users.noreply.github.com")
                Write-Output "git user.email is not set: committing as $login <$login@users.noreply.github.com>"
            }
            Invoke-GitOrThrow ($who + @('commit', '-m', $Msg)) -Show | Out-Null
            Write-Output "committed: $(Get-GitOutput @('log', '--oneline', '-1'))"
        } else {
            Write-Output 'nothing newly staged; pushing the existing HEAD'
        }

        $head = Get-GitOutput @('rev-parse', '--verify', '-q', 'HEAD')
        if (-not $head) { throw "nothing to publish under $root - the project looks empty" }

        # push when the remote branch is missing or points somewhere else, even with no new commit
        $remoteSha = ''
        try { $remoteSha = (Invoke-Api "$Api/repos/$Repo/commits/main").sha }
        catch {
            $status = Get-ApiStatus $_
            if ($status -ne 404 -and $status -ne 409) { throw "HTTP $status from GET /repos/$Repo/commits/main" }
        }

        if ($remoteSha -eq $head) {
            Show-Section 'NOTHING TO PUSH - TRIGGER A REBUILD'
            Write-Output 'same commit already on the remote: workflow_dispatch'
            Invoke-Api -Method Post -Uri "$Api/repos/$Repo/actions/workflows/build-macos.yml/dispatches" -Body @{ ref = 'main' } | Out-Null
            Complete-Build (Wait-ForRun $head)
            break
        }

        Show-Section 'PUSH'
        $pushUrl = "https://x-access-token:$Token@github.com/$Repo.git"
        $gitArgs = @()
        if ($Proxy) { $gitArgs += @('-c', "http.proxy=$Proxy", '-c', "https.proxy=$Proxy") }
        $gitArgs += @('push', '--quiet')
        if ($Force) { $gitArgs += '--force' }
        $gitArgs += @($pushUrl, 'HEAD:refs/heads/main')
        Write-Output ('+ git push ' + $(if ($Force) { '--force ' } else { '' }) + "https://github.com/$Repo.git HEAD:main")
        $r = Invoke-Git $gitArgs
        if ($r.Code -ne 0) {
            $text = Redact ($r.Text -replace '\s+', ' ').Trim()
            if ($text -match 'rejected|fetch first|non-fast-forward') {
                throw "remote $Repo/main has history this local repo does not share (left over from a previous .git wipe). Re-run with -Force to overwrite the remote branch, or pick a new name with -RepoOverride owner/name."
            }
            throw "git push failed: $text"
        }
        Write-Output ("pushed: {0} -> {1} main{2}" -f $head.Substring(0, 7), $Repo, $(if ($Force) { ' (forced)' } else { '' }))

        Complete-Build (Wait-ForRun $head)
    }
}

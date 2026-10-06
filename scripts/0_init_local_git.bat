@echo off
setlocal EnableExtensions
chcp 65001 >nul

rem 0_init_local_git.bat -- create the local git repository and wire up "origin".
rem Idempotent: safe to run again. Building and downloading is 1_mac-ci.ps1's job,
rem because creating the repository on GitHub needs the API and a token.

set "ROOT=%~dp0\.."
pushd "%ROOT%"
if errorlevel 1 (
    echo Failed to enter the project root.
    exit /b 1
)

where git >nul 2>nul
if errorlevel 1 (
    echo Git is not available in PATH.
    popd
    exit /b 1
)

if not exist ".git\" (
    echo Initializing the local git repository...
    git init
    if errorlevel 1 ( popd & exit /b 1 )
) else (
    echo Local git repository already exists.
)

rem git init may default to another branch name; Actions builds main
git rev-parse --verify HEAD >nul 2>nul
if errorlevel 1 (
    git symbolic-ref HEAD refs/heads/main
    if errorlevel 1 ( popd & exit /b 1 )
)

rem GITHUB_REPO=owner/name in .env.local tells us where this project lives
set "SLUG="
for /f "usebackq tokens=1,* delims==" %%A in ("%~dp0..\.env.local") do (
    if "%%~A"=="GITHUB_REPO" set "SLUG=%%~B"
)
if defined SLUG set "SLUG=%SLUG: =%"

if not defined SLUG (
    git remote get-url origin >nul 2>nul
    if errorlevel 1 (
        echo No origin remote and GITHUB_REPO is not set in .env.local.
        echo Add this line to .env.local, then run me again:
        echo     GITHUB_REPO=your-login/your-repo-name
        popd
        exit /b 1
    )
)

if defined SLUG (
    set "PUSH_URL=https://github.com/%SLUG%.git"
) else (
    for /f "delims=" %%U in ('git remote get-url origin') do set "PUSH_URL=%%U"
)

git remote get-url origin >nul 2>nul
if errorlevel 1 (
    echo Adding remote origin: %PUSH_URL%
    git remote add origin "%PUSH_URL%"
    if errorlevel 1 ( popd & exit /b 1 )
) else (
    echo Remote origin already points at:
    git remote get-url origin
)

echo Staging every file that .gitignore does not exclude...
git add -A
if errorlevel 1 ( popd & exit /b 1 )

git diff --cached --quiet
if errorlevel 1 (
    echo Creating the initial commit...
    git commit -m "Initial macinfo repository"
    if errorlevel 1 ( popd & exit /b 1 )
) else (
    echo Nothing to commit.
)

git status --short
echo.
echo Local git init done. Next:  powershell -ExecutionPolicy Bypass -File "%~dp01_mac-ci.ps1"
popd
endlocal

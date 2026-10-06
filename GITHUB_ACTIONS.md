# GitHub Actions 流水线说明

本文拆解 `.github/workflows/build-macos.yml` 在云端 macOS 运行器上做的每一步，以及本项目踩过的坑。
日常使用方式见 [README.md](README.md)。

---

## 1. 为什么用 GitHub Actions

Windows 上的 MSVC / MinGW **无法**生成 macOS 的 Mach-O 或 `.app`：缺 Apple Clang、缺 macOS SDK、
缺代码签名工具链。可行的三条路里：

| 方案 | 需要 Mac | 难度 | 结论 |
|---|---|---|---|
| GitHub Actions macOS runner | 否 | 低 | **本项目采用**：公开仓库免费，机器是真 Apple 硬件 |
| 租云 Mac（SSH 上去手动编译） | 否 | 中 | 适合偶尔一次，但要自己维护一台机器的环境 |
| Docker / LLVM 交叉编译 | 否 | 极高 | 签名、SDK、framework 全靠手工凑，不值得 |

GitHub 对**公开仓库**的标准 GitHub-hosted runner 不收分钟数费用；macOS 按 10 倍费率扣的是私有仓库
每月 2000 分钟的额度。artifact 保留 90 天、单仓库 500 MB。本项目单次构建约 45 秒、产物约 3.9 MB。

整体数据流：

```
Windows/Linux 编辑代码
   ↓ git push（scripts/1_mac-ci.ps1 自动完成）
GitHub Actions
   ↓ runs-on: macos-latest —— Apple M1 虚拟机 + Xcode 工具链
Apple clang 21 + CMake 4.4
   ↓
MacInfo.app（Universal 2）
   ├── hdiutil   → MacInfo-1.0.0.dmg   ┐
   ├── pkgbuild  → MacInfo-1.0.0.pkg   ├→ artifact → 自动下载回 artifacts/
   └── tar -czf  → macinfo-cli.tar.gz  ┘
```

流水线自身打印的运行环境（CI 日志原样）：

```
ProductName: macOS   ProductVersion: 26.6.2   BuildVersion: 25G83
arm64
cmake version 4.4.3
Apple clang version 21.0.0 (clang-2100.1.1.101)
cpu : Apple M1 (Virtual)   cores : 3
```

## 2. 触发方式

```yaml
on:
  push:                # 任何 push 自动跑
  workflow_dispatch:   # Actions 页面可手动点；本地脚本在无代码改动时也用它触发一次构建

env:
  APP_NAME: MacInfo
  APP_VERSION: 1.0.0
  BUNDLE_ID: com.louis24.macinfo
```

## 3. 逐步骤解析

| 步骤 | 做什么 / 为什么需要 |
|---|---|
| `actions/checkout@v4` | 拉取代码 |
| Show toolchain | `sw_vers` / `uname -m` / `cmake --version` / `clang --version`，把机器环境钉进日志；出问题先排除环境漂移 |
| Configure | `cmake -B build -DCMAKE_BUILD_TYPE=Release -DUNIVERSAL=ON`。`UNIVERSAL` 是本项目自定义开关，内部展开为 `CMAKE_OSX_ARCHITECTURES="arm64;x86_64"` |
| Build | `cmake --build build -j $(sysctl -n hw.ncpu)`，同时产出 CLI `macinfo` 与 bundle `MacInfo.app` |
| Generate app icon | `sips` 缩放出 10 个尺寸 → `iconutil -c icns` → 写入 `MacInfo.app/Contents/Resources/AppIcon.icns`，由 `Info.plist` 的 `CFBundleIconFile` 认领 |
| Inspect bundle | `find` 列 bundle 结构、`plutil -lint` 校验 Info.plist、`lipo -info` 确认架构。打包出错时现象往往是"看起来成功了"，所以先验结构 |
| Smoke test | 执行 `./build/macinfo`，再执行 `MacInfo.app/Contents/MacOS/MacInfo --report`。CI 上没有窗口服务器，GUI 起不来，因此 App 提供 `--report`：只打印不建窗口，让 bundle 里的二进制本身仍被真实执行 |
| Ad-hoc code sign | `codesign --force --sign - MacInfo.app`（`-` 即 ad-hoc，不需要证书）；随后 `spctl -a` 输出 `rejected` 属预期，见第 5 节 |
| Build .dmg | 拷贝 App 到 `dmg-root/`，加一个指向 `/Applications` 的软链接，`hdiutil create -format UDZO` 生成压缩磁盘镜像并 `hdiutil verify`。用户双击后看到的就是"把图标拖到 Applications"的标准窗口 |
| Build .pkg | `pkgbuild --component MacInfo.app --install-location /Applications --version ... --identifier ...`，再用 `pkgutil --payload-files` 证明包内确实是 `./MacInfo.app/Contents/...` |
| Package CLI | `tar -czf`（用 tar 而非 zip 是为了保留可执行位） |
| Checksums | `shasum -a 256 ... \| tee SHA256SUMS`，供本地脚本比对 |
| Upload artifact | `actions/upload-artifact@v4` 上传 4 个文件，并设 `if-no-files-found: error`，让"漏产物"直接判失败而不是静默成功 |

## 4. Universal 2：一次编译覆盖 Intel 与 Apple Silicon

CMake 里只是几行：

```cmake
option(UNIVERSAL "Build a universal (arm64 + x86_64) binary on macOS" OFF)
if(APPLE AND UNIVERSAL)
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "" FORCE)
endif()
```

CI 日志确认产物确实是胖二进制：

```
Architectures in the fat file: build/MacInfo.app/Contents/MacOS/MacInfo are: x86_64 arm64
```

回到 Windows 后 `scripts/1_mac-ci.ps1 -Action check` 会直接读文件头复核：`CA FE BA BE` 是 fat 容器，
其中 `0x01000007` = x86_64、`0x0100000C` = arm64；`CF FA ED FE` 则是单架构 Mach-O。不需要 Mac 也能确认。

## 5. 签名：目前做到的是哪一档

当前只做 ad-hoc 签名，效果边界要说清楚：

- `codesign --verify` 通过：`valid on disk` / `satisfies its Designated Requirement`
- `spctl -a -t exec` **rejected**：因为既没有 Apple Developer ID 证书签名，也没有做公证（notarization）

实际影响与对策：

- 浏览器、邮件、网盘下载会带来 `com.apple.quarantine` 扩展属性，**首次打开被 Gatekeeper 拦**
  → 右键 → 打开（一次即可），或 `xattr -dr com.apple.quarantine /Applications/MacInfo.app`
- `gh run download`、`scp` 取回的产物不带 quarantine，可直接打开
- 仅加 `--options runtime`（hardened runtime）不能过 `spctl`，缺的是公证而不是编译选项
- 正式分发：第 8 步换成 `codesign --sign "Developer ID Application: ..."`，再
  `xcrun notarytool submit` + `xcrun stapler staple`，其余步骤不动；需要 Apple Developer 账号

## 6. 踩坑记录

每一条都对应一次真实失败，日志关键字附在后面。

1. **大小写不敏感的文件系统撞坏 CMake target**
   `add_executable(macinfo)` 与 `add_executable(MacInfo)` 并存时，`CMakeFiles/macinfo.dir` 与
   `CMakeFiles/MacInfo.dir` 在 APFS 上是同一个目录，报
   `make[2]: *** No rule to make target 'CMakeFiles/macinfo.dir/depend'. Stop.`
   解法：GUI target 命名 `MacInfoApp`，用 `OUTPUT_NAME "MacInfo"` 保住产物文件名。
2. **`pkgbuild` 没有 `--install-prefix`**
   正确参数是 `--install-location`（component 包默认即 `/Applications`），写错直接
   `unrecognized option`。
3. **`pkgutil --dump-info` 不存在**
   应该用 `--pkg-info` / `--payload-files` / `--check-signature`。另外 `--pkg-info` 对尚未安装的 pkg
   文件会输出 `No receipt for 'X.pkg' found at '/'`，这是它的正常行为，流水线里不能当成失败。
4. **`hdiutil verify` 紧跟 `hdiutil create` 会随机失败**
   `unable to recognize "X.dmg" as a disk image. (Resource temporarily unavailable)`——DiskArbitration
   尚未登记完镜像。解法是重试循环（5 次，每次 `sleep 5`）。注意步骤是以 `bash -e` 执行的，写成
   `hdiutil verify && break` 会在失败时直接终止 job，必须用 `if ...; then ok=1; break; fi` 包住。
5. **Windows PowerShell 5.1 读取无 BOM 的 UTF-8 `.ps1` 时按 ANSI/GBK 解码**
   脚本里写中文注释会让多字节序列吞掉引号，报出"字符串缺少终止符"之类与真因无关的解析错误。
   因此 `scripts/*.ps1` 保持纯 ASCII，中文一律放文档里。
6. **Actions artifact 的下载字段是 `archive_download_url`**
   不是 `download_url`；取错字段会得到空值。
7. **“有没有新提交”不能用来判断“要不要 push”**
   本地 `.git` 被删、远端仓库被重建后，工作区是干净的（没东西可提交）但远端一个 commit 也没有。
   若因此改走 `workflow_dispatch`，会拿到 `404 Not Found`——空仓库里并没有 workflow 文件。
   正确做法：拿本地 HEAD 与 `GET /repos/{slug}/commits/main` 的 sha 比较（空仓库返回 404/409），
   不一致就 push，一致才 dispatch。
8. **提交白名单会过期**
   早期脚本写死 `git add .gitignore CMakeLists.txt src resources ...`，新增 `.env.example`、
   `build-mac.cmd` 时静默漏掉。改成 `git add -A`，由 `.gitignore` 单独决定什么不入库。
9. **`powershell -File` 会吞掉多词参数的引号**
   `-Msg "a b c"` 从 cmd 传进来时可能变成三个位置参数，报
   `找不到接受实际参数“b”的位置形式参数`。解法：声明
   `[Parameter(ValueFromRemainingArguments=$true)]` 收集散落的参数再拼回消息。

## 7. 扩展到真实项目时还要补什么

- **第三方依赖**：流水线里先 `brew install opencv` 或配置 vcpkg 的 `arm64-osx` triplet；随后需要把
  dylib/framework 拷进 `MacInfo.app/Contents/Frameworks`，并用 `install_name_tool -change` 改成
  `@rpath`，否则换一台 Mac 就会 dyld 找不到库。本项目只用系统框架，所以没有这一步。
- **多机型**：Intel 专用 runner 正在退役，用 Universal 2 覆盖即可，不必开 matrix。
- **正式发布**：追加一个 job，用 `actions/create-release` + `actions/upload-release-asset` 把 dmg/pkg
  挂到 GitHub Release，别人点链接即可下载。
- **换仓库**：脚本按 `-RepoOverride` > `.env.local` 的 `GITHUB_REPO` > `origin` URL 的顺序确定归属，
  `.env.local` 换成自己的 token 与仓库名即可；远端仓库不存在时 `1_mac-ci.ps1` 会自动创建。

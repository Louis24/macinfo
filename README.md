# macinfo

[![Build for macOS](https://github.com/Louis24/macinfo/actions/workflows/build-macos.yml/badge.svg)](https://github.com/Louis24/macinfo/actions/workflows/build-macos.yml)

在 Windows 或 Linux 上写 C++，用 GitHub Actions 提供的**真实 macOS 运行器**（Apple Clang + Xcode SDK）
编译出可以双击安装的 Mac 程序。仓库自带一条命令把「推送 → 云端编译 → 下载产物 → 校验」整条链路跑完。

产物同时是 **Universal 2**（`x86_64` + `arm64`），一份文件通吃 Intel Mac 和 Apple Silicon Mac。

- 零第三方依赖：GUI 只用系统 AppKit（Objective-C++），构建只用 CMake
- 云端完成 icns 生成、bundle 打包、ad-hoc 签名、`hdiutil` 出 dmg、`pkgbuild` 出 pkg
- CI 会真正执行编译出来的二进制（App 带 `--report` 无界面模式），不是"编过就算成功"
- 下载后本地重算 SHA256，与 CI 生成的 `SHA256SUMS` 逐个比对

---

## 快速开始

```bash
# 1) 一次性配置：把 token 放进 .env.local（已被 .gitignore 排除）
cp .env.example .env.local      # 填入 GITHUB_TOKEN，以及 GITHUB_REPO=你的登录名/macinfo

# 2) 一次性初始化本地仓库并关联 origin（幂等，重复跑无害；.git 被删后也从这里重建）
scripts\0_init_local_git.bat

# 3) 改完代码，一条命令跑完全流程
powershell -ExecutionPolicy Bypass -File .\scripts\1_mac-ci.ps1
```

第 3 步依次做五件事：确认远端仓库存在（不存在就用 API 建一个）→ `git add -A` + commit + push
（**没有新改动时也把现有 HEAD 推上去**，然后改用 `workflow_dispatch` 手动触发）→ 轮询本次 commit
的 Actions run → 失败则自动抓出失败步骤和报错行 → 把 artifact 解压到 `artifacts\` 并校验 SHA256、
识别文件类型。一次完整执行约 1 分钟（排队 ~10 秒、编译 ~45 秒、下载校验几秒）。

自定义提交信息（`-m` 等价于 `-Msg`）：

```bat
powershell -ExecutionPolicy Bypass -File .\scripts\1_mac-ci.ps1 -m "tune the dmg layout"
```

## 编译结果在哪里

全部落在 `artifacts/`（该目录被 gitignore，不会污染仓库）：

| 文件 | 大小 | 说明 | 在 Mac 上怎么用 |
|---|---|---|---|
| `MacInfo-1.0.0.dmg` | ~2.2 MB | 磁盘镜像，内含 App 和 `/Applications` 快捷方式 | **双击挂载 → 把图标拖进 Applications** |
| `MacInfo-1.0.0.pkg` | ~1.7 MB | 组件安装包，安装位置 `/Applications` | 双击走安装向导 |
| `macinfo-cli.tar.gz` | ~8 KB | 命令行版 `bin/macinfo`，Universal 2 | `tar -xzf macinfo-cli.tar.gz && ./bin/macinfo` |
| `SHA256SUMS` | | CI 用 `shasum` 生成的校验值 | `shasum -a 256 -c SHA256SUMS` |

> 用 `tar` 而不是 zip 打包命令行版，是为了保留可执行权限位；从 Windows 直接拷出的裸文件需要
> 手动 `chmod +x`。

## 目录结构

```
.
├── .github/workflows/
│   └── build-macos.yml      GitHub Actions 流水线：云端 Mac 编译 + 签名 + dmg/pkg 打包 + 上传
├── resources/
│   ├── AppIcon.png          1024×1024 图标源图
│   ├── Info.plist.in        .app 的 bundle 身份模板（bundle id、版本、NSPrincipalClass…）
│   └── make_icns.sh         CI 里用 sips + iconutil 把 PNG 生成 AppIcon.icns
├── scripts/
│   ├── 0_init_local_git.bat 一次性：git init + 分支 main + 关联 origin + 初始提交（幂等）
│   └── 1_mac-ci.ps1         日常入口：build / status / wait / jobs / logs / download / verify / check
├── src/
│   ├── sysinfo.h            系统信息采集接口（CLI 与 GUI 共用同一份实现）
│   ├── sysinfo.cpp          用 sysctl MIB 读取 CPU 型号/核数/macOS 版本/编译器/架构，含 Rosetta 检测
│   ├── main.cpp             命令行入口，打印报告
│   └── gui_mac.mm           Objective-C++ + AppKit 窗口 App；--report 参数供 CI 无界面冒烟测试
├── .env.example             本地凭据模板（复制成 .env.local）
├── .gitignore               排除构建产物与凭据；scripts 依赖它而非白名单来决定提交什么
├── CMakeLists.txt           两个 target：macinfo（CLI）、MacInfoApp（→ MacInfo.app）
├── GITHUB_ACTIONS.md        流水线逐步骤解析、Universal 2 做法、签名限制、踩坑记录
└── README.md
```

`artifacts/`、`build/` 之类目录不在上面的树里，因为它们都是被 gitignore 的生成物。

## 其他命令

```powershell
$p = ".\scripts\1_mac-ci.ps1"
powershell -ExecutionPolicy Bypass -File $p -Action status              # 最近 5 次构建
powershell -ExecutionPolicy Bypass -File $p -Action jobs -Id <runId>    # 每个步骤的结论
powershell -ExecutionPolicy Bypass -File $p -Action logs -Id <runId>    # 失败步骤 + 报错行
powershell -ExecutionPolicy Bypass -File $p -Action download -Id <artifactId>
powershell -ExecutionPolicy Bypass -File $p -Action verify              # SHA256 比对
powershell -ExecutionPolicy Bypass -File $p -Action check               # 读文件头，确认是 Mach-O/dmg/pkg
```

仓库归属的判定顺序：`-RepoOverride owner/name` > `.env.local` 里的 `GITHUB_REPO` > `origin` 的 URL。
换仓库不用改脚本。远端分支与本地 HEAD 不一致时才 push，一致时直接触发一次重新构建。
如果远端留着旧历史（本地 `.git` 被删过），push 会被拒，脚本会让你显式加 `-Force` 覆盖。

## 在 macOS 上直接构建

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release -DUNIVERSAL=ON
cmake --build build -j
open build/MacInfo.app          # 或 ./build/macinfo
sudo cmake --install build      # App 装到 /usr/local/bin 与 .app 目录
```

`-DUNIVERSAL=OFF`（默认）只编译当前机器架构；`-DBUILD_MAC_APP=OFF` 可以只出命令行工具。

## 在其他平台上能验证到哪一步

`src/gui_mac.mm` 依赖 AppKit，**只有 macOS 能编译**。在非苹果系统上唯一可行的检查是命令行分支：

```bash
g++ -std=c++17 -Wall -Wextra -O2 src/main.cpp src/sysinfo.cpp -o macinfo && ./macinfo
```

它走 `#else` 分支，只能证明语法与非苹果分支的正确性。Mach-O / bundle / 签名 / 打包一律交给云端，
不建议在 Windows 上交叉编译 macOS 二进制。

## 签名与 Gatekeeper（已知限制）

CI 只做 **ad-hoc 签名**（`codesign --sign -`，无需证书）。因此 `codesign --verify` 通过，但没有
Apple Developer ID 签名与公证（notarization），`spctl` 会判 `rejected`。表现为：用浏览器下载 dmg
后**首次打开会被 Gatekeeper 拦**。

绕过方式（任选其一）：右键 App → 打开 → 再点"打开"（只需一次）；或
`xattr -dr com.apple.quarantine /Applications/MacInfo.app`；或用 `gh run download` / `scp` 取产物
（不会打上 quarantine 属性）。

要正式对外分发，需要在流水线里换成 `Developer ID Application` 证书签名并接
`xcrun notarytool submit` + `xcrun stapler staple`，这需要一个 Apple Developer 账号。

## 改成你自己的程序

1. 替换 `src/` 下的源码，在 `CMakeLists.txt` 里改 target 名。注意 macOS 文件系统大小写不敏感，
   不要同时存在仅大小写不同的两个 target 名（会让 make 崩，详见 GITHUB_ACTIONS.md）
2. 改 `.github/workflows/build-macos.yml` 顶部的 `APP_NAME` / `APP_VERSION` / `BUNDLE_ID`
3. 删掉旧的 `.git` 目录，在 `.env.local` 里写上你的 `GITHUB_REPO`，跑一次 `scripts\0_init_local_git.bat`
   重建本地仓库，之后每次只跑 `scripts\1_mac-ci.ps1`（远端仓库不存在时它会自动创建）

## 相关文档

- [GITHUB_ACTIONS.md](GITHUB_ACTIONS.md) —— 云端那台 Mac 上每一步在做什么、免费额度、6 条踩坑记录、
  加入第三方依赖（OpenCV/Qt/Boost）时还要补什么

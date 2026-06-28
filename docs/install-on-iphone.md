# 在 iPhone 上安装 Lattice

这份文档是快速安装版。完整的编译、签名、真机运行、导出 `.ipa`、故障排查流程见 [ios-build-deploy.md](ios-build-deploy.md)。

## 前置条件

- macOS 上已安装完整 Xcode，路径通常是 `/Applications/Xcode.app`。
- Xcode 里已登录 Apple ID。
- iPhone 系统版本 iOS 16 或更高。
- iPhone 已连接 Mac，已点 Trust，并能在 Xcode run destination 里看到。

如果当前选中的是 Command Line Tools，而不是完整 Xcode：

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

如果不想修改全局 Xcode 选择，可以对本项目命令加前缀：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/doctor-ios.sh
```

如果 Xcode license 未接受：

```sh
sudo xcodebuild -license
```

阅读后按提示同意。

## 环境检查

在项目根目录运行：

```sh
./scripts/doctor-ios.sh
```

它会检查：

- `xcodebuild` 是否可用
- 当前是否指向完整 Xcode
- Xcode license 是否已接受
- iPhoneOS SDK 是否存在
- `Astra` scheme 是否可见
- iOS Simulator build 是否能通过

## Xcode 真机安装

1. 打开 `Astra.xcodeproj`。
2. 选择左侧 project navigator 顶部的 `Astra` project。
3. 选择 `Astra` target。
4. 打开 Signing & Capabilities。
5. Team 选择你的 Apple ID team。
6. 如果 `org.roobli.astra` 不可用，把 Bundle Identifier 改成自己的，例如 `com.yourname.lattice`。长期自用时，选定后尽量保持不变。
7. 顶部 run destination 选择你的 iPhone。
8. 按 Run。
9. 如果 iPhone 提示开发者未受信任，到 iPhone 设置中信任该 Apple ID。
10. 手机上打开 App。桌面显示名是 `Lattice`。

## 首次配置

进入 App 的 Settings 页：

1. 填 Lattice server URL，例如：
   - `https://lattice.example.com`
   - `http://192.168.1.20:8088`
   - 也可以粘贴 `https://lattice.example.com/api/nodes`，App 会归一化为 API base。
2. 选择一种认证方式：
   - Personal access token：填一个有 `node:read` 权限的 token。
   - 用户名密码：填 username/password，点 `Login and save session`。
3. 如果启用了 TOTP：
   - 第一次登录会提示需要 TOTP。
   - 在 TOTP code 输入框填 6 位验证码。
   - 再点一次 `Login and save session`。
4. 点 `Test Lattice connection`，确认能加载节点数量。
5. Bark server 默认是 `http://bark.roobli.org`，按需修改。
6. 填 Bark device key。
7. 点 `Send test notification`。
8. 点 `Save and refresh`。
9. 回 Nodes 页刷新或启动轮询。

## 命令行真机构建

如果你知道自己的 Team ID，可以用脚本构建真机 Debug 包：

```sh
ASTRA_TEAM_ID=ABCDE12345 \
./scripts/build-ios-device.sh
```

变量说明：

- `ASTRA_TEAM_ID`：Apple Developer Team ID，必填。
- `ASTRA_BUNDLE_ID`：可选。默认读取 Xcode 工程里的当前 Bundle Identifier；只有临时覆盖时才需要传。
- `ASTRA_DESTINATION`：默认 `generic/platform=iOS`。通常不用改。

## 导出 Development IPA

```sh
ASTRA_TEAM_ID=ABCDE12345 \
./scripts/archive-ios-development.sh
```

如果需要临时覆盖工程里的 Bundle Identifier，可以给上面两个命令额外加：

```sh
ASTRA_BUNDLE_ID=com.yourname.lattice
```

默认输出：

- Archive: `DerivedData/Astra.xcarchive`
- Export options: `DerivedData/ExportOptions.Development.generated.plist`
- IPA/export files: `DerivedData/export/`

这个导出方式使用 development signing，适合自己的设备安装和调试，不是 App Store/TestFlight 发布流程。

## 后台刷新行为

App 注册的后台任务 ID 是：

```text
org.roobli.astra.refresh
```

它使用 iOS `BGAppRefreshTask`。系统不保证固定频率，也不保证每次都执行。Settings 页会显示最近一次后台刷新结果。

如果你需要可靠的 24 小时告警，不要依赖 iOS 后台刷新。把 always-on 告警放在 Lattice server 或常驻告警系统中。

## 长期自用建议

- 固定 Apple Team 和 Bundle Identifier，避免重装/升级时变成另一个 App。
- Lattice server 和 Bark server 尽量使用手机在蜂窝网络下也能访问的稳定 HTTPS 域名，或稳定 VPN 入口。
- 优先使用专门给手机 App 创建的低权限 `node:read` Personal Access Token。
- 每次升级 Xcode、iOS 或 Lattice API 后，先跑 `./scripts/check-local.sh`，再做一次真机安装验证。

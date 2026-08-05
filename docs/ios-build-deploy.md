# iOS 编译、签名、部署教程

这份文档按从零到手机可用的顺序写。照着做，可以完成本地验证、Xcode 真机安装、命令行真机构建、development `.ipa` 导出，以及 App 首次配置。

## 1. 准备 Lattice 服务

iOS 客户端需要能访问 Lattice control plane。

至少确认：

- iPhone 所在网络能访问 Lattice server。
- Lattice server 暴露 API：
  - `POST /api/login`
  - `POST /api/login/totp`
  - `GET /api/nodes`
- 你有一种认证方式：
  - Personal Access Token，权限包含 `node:read`。
  - 或可登录的 username/password。
- 如果使用 HTTPS，证书必须被 iOS 信任。
- 如果使用局域网 HTTP，例如 `http://192.168.1.20:8088`，需要确保 iPhone 和 Mac 在同一网络，且服务没有被防火墙挡住。

建议先在 Mac 上试：

```sh
curl -i https://lattice.example.com/api/nodes
```

如果需要 PAT：

```sh
curl -i \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  https://lattice.example.com/api/nodes
```

返回 200 且 body 是节点列表后，再处理 iOS。

## 2. 准备 macOS/Xcode 环境

需要：

- 完整 Xcode，通常安装在 `/Applications/Xcode.app`。
- Xcode 已打开过一次。
- Xcode license 已接受。
- Xcode 里已登录 Apple ID。
- iPhone iOS 16 或更高。

检查当前 developer directory：

```sh
xcode-select -p
```

如果输出不是 `/Applications/Xcode.app/Contents/Developer`，切换：

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

如果不想改全局设置，后续命令可以这样运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/doctor-ios.sh
```

接受 Xcode license：

```sh
sudo xcodebuild -license
```

检查 Xcode 版本和 SDK：

```sh
xcodebuild -version
xcodebuild -showsdks | grep iphoneos
```

## 3. 跑项目本地检查

在项目根目录：

```sh
./scripts/check-local.sh
```

这个检查不需要连接 iPhone，主要确认：

- plist 能被解析。
- Xcode scheme XML 正常。
- App source 都在 target membership 里。
- 没有把明显 secret 写进源码。
- Lattice core check 通过。
- SwiftUI app sources 能用当前 SDK type-check。

如果你想在本地检查里强制确认某个个人 Bundle Identifier，可以传：

```sh
ASTRA_BUNDLE_ID=com.yourname.lattice ./scripts/check-local.sh
```

不传 `ASTRA_BUNDLE_ID` 时，检查脚本会接受 Xcode 工程里 Debug/Release 一致的当前 Bundle Identifier。

只跑核心协议检查：

```sh
swift run --scratch-path .build AstraCoreCheck
```

## 4. 跑 iOS doctor

```sh
./scripts/doctor-ios.sh
```

它会：

1. 确认 `xcodebuild` 存在。
2. 确认当前 developer directory 指向完整 Xcode。
3. 确认 license 已接受。
4. 确认 iPhoneOS SDK 存在。
5. 列出 `Astra.xcodeproj` 的 scheme。
6. 做一次 iOS Simulator build，且关闭 code signing。

如果这一步失败，先不要打开手机调试。按错误信息修环境。

## 5. 用 Xcode 安装到 iPhone

这是最直接的个人使用方式。

1. 用 Xcode 打开：

   ```sh
   open Astra.xcodeproj
   ```

2. 左侧 project navigator 选择最上面的 `Astra`。
3. 中间选择 `Astra` target。
4. 打开 Signing & Capabilities。
5. 勾选 Automatically manage signing。
6. Team 选择你的 Apple ID team。
7. Bundle Identifier 改成自己的唯一值，例如：

   ```text
   com.yourname.lattice
   ```

   默认 `org.roobli.astra` 可能在你的账号下不可用。长期自用时，选定一个 Bundle Identifier 后尽量保持不变；频繁更换会让 iOS 把安装包当成不同 App，配置、权限和 Keychain 状态也会变得难排查。

8. 连接 iPhone。
9. iPhone 上点 Trust this computer。
10. Xcode 顶部 destination 选择你的 iPhone。
11. 按 Run。
12. 如果 iPhone 弹出 Untrusted Developer，到：

    ```text
    Settings -> General -> VPN & Device Management
    ```

    信任你的 Apple ID developer profile。

安装后桌面 App 名称是 `Lattice`。

## 6. 命令行真机 Debug build

如果只是确认能签名构建，不一定要打开 Xcode。

先找到 Team ID。常见路径：

- Apple Developer 网站。
- Xcode Account 详情。
- 既有 provisioning profile。

然后运行：

```sh
ASTRA_TEAM_ID=ABCDE12345 \
./scripts/build-ios-device.sh
```

脚本默认使用 Xcode 工程里的当前 Bundle Identifier。只有在你想临时覆盖工程设置时，才需要额外传：

```sh
ASTRA_TEAM_ID=ABCDE12345 \
ASTRA_BUNDLE_ID=com.yourname.lattice \
./scripts/build-ios-device.sh
```

脚本内部会先跑 `doctor-ios.sh`，再执行：

```sh
xcodebuild \
  -project Astra.xcodeproj \
  -scheme Astra \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  DEVELOPMENT_TEAM="$ASTRA_TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_STYLE=Automatic \
  build
```

这会验证 iOS 真机签名 build 能过，但不会自动安装到某台设备。要安装到设备，最省事仍然是 Xcode Run。

## 7. 导出 development IPA

运行：

```sh
ASTRA_TEAM_ID=ABCDE12345 \
./scripts/archive-ios-development.sh
```

同样，`ASTRA_BUNDLE_ID` 默认来自 Xcode 工程当前设置；只有需要临时覆盖时再传。

默认路径：

- Archive: `DerivedData/Astra.xcarchive`
- Export options: `DerivedData/ExportOptions.Development.generated.plist`
- Export output: `DerivedData/export/`

脚本会复制 `Config/ExportOptions.Development.plist`，写入你的 Team ID，然后执行 archive/export。

注意：

- 这是 development export。
- 设备必须在你的 Apple 开发账号或自动签名 profile 覆盖范围内。
- 这不是 App Store/TestFlight 发布流程。

## 8. 长期自用建议

个人长期使用时，推荐把稳定性放在签名、服务入口和告警位置上：

- 固定 Apple Team 和 Bundle Identifier，避免每次重装都像新 App。
- 如果要脱离 Mac 长期安装，优先使用 Apple Developer Program 的签名能力；免费个人签名适合短期测试，不适合长期可用。
- Lattice 和 Bark 尽量使用稳定 HTTPS 域名，或稳定 VPN 入口，避免手机离开家用 Wi-Fi 后不可访问。
- App 内优先保存低权限 `node:read` PAT；用户名密码 session 更适合临时登录，不适合作为长期机器凭据。
- iOS 后台刷新是 best-effort。不能漏报的告警应放在 Lattice server、Bark server、Prometheus/Alertmanager 或其他常驻服务中。
- 每次升级 Xcode、iOS 或 Lattice API 后，先跑 `./scripts/check-local.sh`，再做一次真机 Run。

## 9. 首次打开 App

打开手机上的 `Lattice`。

进入 Settings。

### Lattice URL

支持这些输入：

```text
https://lattice.example.com
http://192.168.1.20:8088
lattice.example.com:8088
https://lattice.example.com/api
https://lattice.example.com/api/nodes
```

App 会归一化为正确 API base，并为 Bark tap-through 生成 dashboard URL。

### 认证方式 A: PAT

1. 在 Lattice control plane 创建 PAT。
2. 权限至少包含 `node:read`。
3. 在 Settings 的 Personal access token 输入框粘贴。
4. 点 `Save and refresh`。
5. 点 `Test Lattice connection`。

PAT 会存入 Keychain。

### 认证方式 B: 用户名密码 session

1. 填 username。
2. 填 password。
3. 点 `Login and save session`。
4. 成功后 App 保存 `lattice_session` cookie 和 CSRF token。
5. App 会清空 PAT，之后优先使用 session。

如果服务器要求 TOTP：

1. 第一次登录会提示 TOTP required。
2. 填 TOTP code。
3. 再点 `Login and save session`。

### 删除 secret

把对应 secret 输入框清空，再点 `Save and refresh`，会删除 Keychain item。

## 10. 配置 Bark

默认：

```text
Server: http://bark.roobli.org
Group: Lattice
Sound: minuet
Level: Time Sensitive
```

填入 Bark device key。

如果粘贴完整 Bark URL：

```text
https://api.day.app/YOUR_KEY/body
http://bark.example:7001/YOUR_KEY/
```

App 会自动提取 `YOUR_KEY`。

点：

```text
Send test notification
```

手机收到测试通知后，再开启轮询。

## 11. 轮询和阈值

Settings 中可以调整：

- Poll interval。
- Offline timeout。
- Notification cooldown。
- CPU threshold。
- Memory threshold。
- Disk threshold。
- Background refresh 开关。

设置位于 `More → Settings`。Overview 页显示 Fleet 概览，Nodes 页显示节点状态，本地健康事件历史在 `More → Activity`。

## 12. 后台刷新现实情况

App 注册：

```text
org.roobli.astra.refresh
```

使用 iOS `BGAppRefreshTask`。

iOS 会自己决定：

- 是否给后台运行机会。
- 何时唤醒。
- 一次给多少运行时间。
- 低电量、网络、用户使用习惯下是否暂停。

所以它不能保证每分钟、每 5 分钟或任何固定频率。Settings 页会显示最近一次后台刷新结果。

严肃告警建议：

- Lattice server 侧做 always-on 检测。
- Bark server 或其他常驻服务负责推送。
- iOS 客户端只做个人面板和辅助通知。

## 13. 常见故障

### `xcode-select is not pointing at full Xcode`

执行：

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

或给命令加：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

### `Xcode license has not been accepted`

执行：

```sh
sudo xcodebuild -license
```

### Bundle Identifier unavailable

把 `org.roobli.astra` 改成自己的：

```text
com.yourname.lattice
```

### iPhone 上打不开，提示开发者未受信任

iPhone 上进入：

```text
Settings -> General -> VPN & Device Management
```

信任你的 developer profile。

### `Test Lattice connection` 失败

按顺序检查：

1. iPhone Safari 能不能打开 Lattice server URL。
2. URL 是否带正确协议，HTTP/HTTPS 是否匹配。
3. PAT 是否有 `node:read`。
4. session 是否过期，重新登录。
5. HTTPS 证书是否被 iOS 信任。
6. 反向代理是否把 `/api/nodes` 转发到 Lattice server。

### 收不到 Bark 通知

检查：

1. Bark device key 是否正确。
2. Bark server URL 是否正确。
3. 点 `Send test notification` 是否成功。
4. iPhone 系统通知权限是否允许。
5. Bark server 是否返回 `code: 200`。

### 后台没有按固定频率刷新

这是 iOS 限制，不是 App bug。`BGAppRefreshTask` 只能 best-effort。需要可靠告警时，把告警放到常驻服务端。

# 当前项目结构

这个目录是 Lattice 的 iOS 客户端。它从早期的个人监控原型演进而来，所以工程名仍然是 `Astra`，但产品语义已经切换为 `Lattice`。

## 顶层目录

```text
Astra/
├── Astra.xcodeproj/
├── AstraApp/
├── Checks/
├── Config/
├── Sources/
├── Tests/
├── docs/
├── scripts/
├── Package.swift
└── README.md
```

## Xcode 工程

`Astra.xcodeproj/` 是 iOS App 工程。

当前保持：

- Project: `Astra`
- Target: `Astra`
- Scheme: `Astra`
- Installed app display name: `Lattice`
- Bundle ID default: `org.roobli.astra`
- Marketing version: `0.1.0`
- iOS deployment target: `16.0`

保留 `Astra` 工程名的原因是减少 Xcode project 重命名带来的噪音。用户看到的是 `Lattice`。

## App 层

`AstraApp/App/` 放 SwiftUI App 入口和界面状态。

- `AstraApp.swift`
  - App 入口。
  - 注册后台刷新。
  - 注入 `DashboardModel`。
- `ContentView.swift`
  - 主界面。
  - Tabs: Nodes、Events、Settings。
  - Settings 页负责 Lattice、Bark、轮询、阈值和后台刷新配置。
- `DashboardModel.swift`
  - 主状态机。
  - 负责保存设置、读取 Keychain secret、刷新节点、启动/停止轮询、登录 Lattice、发送 Bark。
- `ServerDetailView.swift`
  - 节点详情页。
  - 目前文件名仍叫 ServerDetailView，但输入模型已经是 `LatticeNode`。
- `BackgroundRefresh.swift`
  - iOS background app refresh 入口。
  - 在系统给机会时拉取节点、保存快照、评估事件、发送 Bark。
- `AppSettings.swift`
  - Codable settings。
  - Keychain wrapper。
  - `NodeStore` 本地节点快照。
  - 兼容读取旧设置键。

## 核心库

`Sources/AstraCore/AstraCore.swift` 是可测试核心。

它包含：

- URL normalizer
  - Lattice server URL 归一化。
  - dashboard URL 归一化。
  - Bark server/device key 归一化。
- Lattice model
  - `LatticeNode`
  - `LatticeMetrics`
  - `LatticeHostFacts`
  - `LatticeGeo`
- Lattice client
  - PAT bearer token 请求。
  - session cookie + CSRF 请求。
  - `/api/login`
  - `/api/login/totp`
  - `/api/nodes`
  - Lattice error envelope 解码。
- Monitor engine
  - disabled/offline/stale 判断。
  - CPU/memory/disk 阈值判断。
  - recovery 事件。
  - cooldown。
- Bark client
  - `/push` JSON API。
  - Bark response 校验。
  - notification payload 构造。

这里故意不依赖 SwiftUI，方便用 SwiftPM 在本机跑检查。

## 检查和测试

`Checks/AstraCoreCheck/main.swift` 是轻量级回归检查。

覆盖：

- Lattice `/api/nodes` 解码。
- Lattice URL 归一化。
- Lattice request header 构造。
- login 和 TOTP session cookie 处理。
- Monitor engine 事件生成。
- Bark request 和 response 校验。

运行：

```sh
swift run --scratch-path .build AstraCoreCheck
```

整体本地检查：

```sh
./scripts/check-local.sh
```

## 构建脚本

`scripts/` 下的脚本：

- `check-local.sh`
  - plist 检查。
  - Xcode scheme 检查。
  - target membership 检查。
  - secret hygiene 检查。
  - `AstraCoreCheck`。
  - SwiftUI app source type-check。
- `doctor-ios.sh`
  - 检查完整 Xcode、license、iPhoneOS SDK、scheme、Simulator build。
- `build-ios-device.sh`
  - 使用 `ASTRA_TEAM_ID` 和 `ASTRA_BUNDLE_ID` 做 signed device build。
- `archive-ios-development.sh`
  - 生成 development archive，并导出 development `.ipa`。
- `generate-icons.swift`
  - 生成 App icon set。

## 配置文件

- `AstraApp/Info.plist`
  - App display name。
  - local network usage description。
  - background task identifier。
  - background fetch mode。
- `Config/ExportOptions.Development.plist`
  - development `.ipa` export 的模板。
- `.gitignore`
  - 忽略 `.build/`、`DerivedData/`、Xcode 用户状态。

## Lattice API 对齐

当前 iOS 客户端按本地 Lattice server/source 对齐：

- Server route:
  - `POST /api/login`
  - `POST /api/login/totp`
  - `GET /api/nodes`
- Auth:
  - `Authorization: Bearer <PAT>`
  - 或 `Cookie: lattice_session=...` + `X-CSRF-Token`
- Node fields:
  - identity: `id`, `name`, `tags`, `role`
  - status: `online`, `disabled`, `last_seen`
  - network: `wireguard_ip`, `public_ip`, `public_ipv6`
  - metrics: `cpu_percent`, `load1`, memory, disk, traffic, uptime
  - facts: hostname, OS, platform, kernel, arch, CPU, virtualization
  - geo: country, region, city, coordinates

如果 Lattice server 后续调整 API shape，需要先更新 `Sources/AstraCore/AstraCore.swift` 和 `Checks/AstraCoreCheck/main.swift`，再改 UI。

# 当前项目结构

这个目录是 Lattice 的 iOS 客户端。它从早期的个人监控原型演进而来，所以工程名仍然是 `Astra`，但产品语义已经切换为 `Lattice`。v2 把它扩展成一个手机优先的控制面伴侣 App（详见 [v2-architecture.md](v2-architecture.md)）。

## 顶层目录

```text
Astra/
├── Astra.xcodeproj/      # iOS App 工程（target/scheme 仍叫 Astra）
├── AstraApp/             # SwiftUI App 层
├── Sources/AstraCore/    # 可测试核心逻辑（无 SwiftUI）
├── Checks/AstraCoreCheck # 不依赖真机的 Swift 回归检查
├── Config/               # ExportOptions plist 等
├── docs/                 # 文档
├── scripts/              # 本地检查 / doctor / 构建脚本
├── Package.swift         # SwiftPM：构建 AstraCore + AstraCoreCheck
├── AGENTS.md
└── README.md
```

`AstraCore` 同时被两个消费方编译：Xcode App target（直接把 `Sources/AstraCore/*.swift` 编进 App）和 SwiftPM 的 `AstraCoreCheck` 可执行 target。**新增核心文件时，SwiftPM 自动纳入，但必须手动加进 `Astra.xcodeproj/project.pbxproj`** 才能被 App target 编译。

## Xcode 工程

- Project / Target / Scheme: `Astra`
- 安装后 App 显示名: `Lattice`
- Bundle ID 默认: `org.roobli.astra`
- iOS deployment target: `16.0`，Swift 6（严格并发）

保留 `Astra` 工程名是为了减少 Xcode project 重命名噪音；用户看到的是 `Lattice`。

## App 层 `AstraApp/App/`

入口与基础设施：

- `AstraApp.swift` — App 入口，注册后台刷新，注入 `DashboardModel`。
- `ContentView.swift` — 根 `TabView`：Overview / Nodes / Monitors / Inventory / More。
- `DashboardModel.swift` — 单一的 `@MainActor` 状态机：设置持久化、Keychain secret、节点刷新与轮询、登录、Bark，以及各控制面分区的加载/动作（machines、monitors、notify、audit、tasks、logs、geo、network）。
- `BackgroundRefresh.swift` — `BGAppRefreshTask` 入口（best-effort 拉取 + 评估 + Bark）。
- `AppSettings.swift` — Codable 设置、Keychain wrapper、`NodeStore`/`EventStore`/`MonitorEngineStateStore` 等本地存储、旧键兼容。
- `DesignSystem.swift` — 统一视觉语言：`Theme`、`LatticeCard`、`SectionHeaderView`、`StatusPill`、`StatTile`、`RingGauge`、`MetricBar`、`Sparkline`(Swift Charts)、`DetailRow`、`AstraEmptyStateView`、`InlineStatusView`。

各 Tab 与详情页：

- `OverviewView.swift` — Fleet 健康环、统计卡、MapKit Fleet Map、关注节点、最近告警。
- `NodesView.swift` — 可搜索/过滤节点列表 + 共享 `NodeRow`。
- `ServerDetailView.swift` — 节点详情 `NodeDetailView`（实时趋势图、host facts、网络、geo、启用/禁用、轮换 token）。文件名仍叫 ServerDetailView 是历史遗留。
- `NodeActions.swift` — QR 生成、一次性 token 展示 `TokenRevealSheet`、节点注册 `EnrollNodeView`。
- `MonitorsView.swift` — 探针列表/详情（uptime 环、延迟图）、新建/删除。
- `InventoryView.swift` — 机器成本与续费清单 + 增删改续费。
- `MoreHubView.swift` — More 入口（含 pending 审批角标）+ `AboutView`。
- `ActivityView.swift` — 审计事件 + 本地告警时间线。
- `AccountView.swift` — 身份/scopes/服务器版本 + PAT 创建/吊销。
- `NotificationsView.swift` — 通知通道/规则 + 测试。
- `LogsView.swift` — 日志源 + 行查询（分页）。
- `TasksView.swift` — 远程任务 + 结果。
- `NetworkView.swift` — 网络与安全只读视图：审批队列、NetPolicy + 可达性图、nft baseline、tunnels，以及 SHA-256 绑定的受控 approve。
- `SettingsView.swift` — Lattice/Bark/轮询/阈值/后台刷新配置。

## 核心库 `Sources/AstraCore/`

故意不依赖 SwiftUI，方便用 SwiftPM 在本机跑检查。

- `AstraCore.swift` — `LatticeClient`（PAT / session+CSRF、`/api/login`、`/api/login/totp`、`/api/nodes`、error envelope）、`LatticeNode`/`LatticeMetrics`/`LatticeHostFacts`/`LatticeGeo`、`MonitorEngine`（offline/CPU/mem/disk 阈值 + cooldown + recovery）、`BarkClient`、URL 归一化、格式化器、内部 `DateValue`/`AstraDateParser`。
- `LatticeModels.swift` — 控制面领域模型：identity、version、token、machine inventory、monitor(+result)、notify channel/rule、audit、task、log source/line、node geo view。
- `LatticeAPI.swift` — `LatticeClient` 的完整 typed 端点扩展 + 请求/响应 envelope；通用 `perform`/`performData` 复用鉴权与校验。
- `LatticeNetwork.swift` — 网络/安全模型（NetPolicy/NetRule/NetEndpoint、NetGraph、NFTInputs、TunnelProfile、Approval）、`PlanHasher`（CryptoKit SHA-256）、对应只读端点 + 受控 approve。
- `LatticeAnalytics.swift` — `FleetSummary`、`MetricsHistory`（趋势缓冲）、`InventorySummary`（成本/续费）、`MonitorStats`、货币/相对时间/uptime 格式化。

## 检查和测试

`Checks/AstraCoreCheck/main.swift` 是轻量级回归检查，覆盖：节点解码、URL 归一化、请求 header/鉴权、login/TOTP、MonitorEngine 事件、Bark 请求/响应、控制面 API 客户端（machines/monitors/audit/notify/logs）、分析层、以及网络层（SHA-256 向量、netpolicy/graph/nft/tunnels/approvals 解码、approve 请求体）。

```sh
swift run --scratch-path .build AstraCoreCheck
```

完整本地检查 / 模拟器编译整 App（无需签名）：

```sh
./scripts/check-local.sh
xcodebuild -project Astra.xcodeproj -scheme Astra \
  -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## 构建脚本 `scripts/`

- `check-local.sh` — plist / scheme / target membership / secret hygiene 检查 + `AstraCoreCheck` + SwiftUI 源码 type-check。
- `doctor-ios.sh` — 检查完整 Xcode、license、iPhoneOS SDK、scheme、Simulator build。
- `build-ios-device.sh` — 用 `ASTRA_TEAM_ID` / `ASTRA_BUNDLE_ID` 做 signed device build。
- `archive-ios-development.sh` — 生成 development archive 并导出 `.ipa`。
- `generate-icons.swift` — 生成 App icon set。

## 配置文件

- `AstraApp/Info.plist` — 显示名、local network usage、`BGTaskSchedulerPermittedIdentifiers`、background fetch mode。
- `Config/ExportOptions.Development.plist` — development `.ipa` export 模板。
- `.gitignore` — 忽略 `.build/`、`DerivedData/`、Xcode 用户状态。

## Lattice API 对齐

API 形状与契约（envelope、严格解码、secret-free view、鉴权）详见 [v2-architecture.md](v2-architecture.md)。原则不变：**Lattice server 改 API shape 时，先更新 `Sources/AstraCore/`（模型 + `LatticeAPI`/`LatticeNetwork`）和 `Checks/AstraCoreCheck/main.swift`，再改 UI。**

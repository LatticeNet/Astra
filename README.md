# Lattice iOS Client

`Astra` 现在是 Lattice 的个人 iOS 客户端。Xcode 工程和 target 仍然叫 `Astra`，这是为了保留原工程结构；安装到手机后的 App 显示名是 `Lattice`。

v2 把它从只读监控原型升级成一个手机优先的 Lattice 控制面伴侣 App：覆盖控制面里大部分适合在手机上操作的功能，配合一套统一的 SwiftUI 设计语言（卡片、环形仪表、Swift Charts 趋势图、Fleet Map）。它仍然不是完整控制面替代品——网络策略、proxy、DNS、存储、插件这类重操作仍留在 Web dashboard；手机端只暴露 Network & security 的只读视图和已经审阅计划的受控批准入口。

## 界面结构（v2）

底部五个 Tab：

- **Overview**：Fleet 健康环、在线/critical/月度成本/续费 统计卡、Fleet Map（MapKit 地图标注各节点）、需要关注的节点、最近告警。
- **Nodes**：可搜索/过滤的节点列表 → 节点详情（CPU/内存/磁盘实时趋势图、host facts、网络、geo、启用/禁用、轮换 agent token、节点注册二维码）。
- **Monitors**：上线/延迟探针列表 → 探针详情（uptime 环、延迟折线图、最近探测记录）、新建/删除。
- **Inventory**：机器成本与续费清单（月度开销汇总、到期/逾期提醒）、新增/编辑/续费/删除、跑提醒。
- **More**：Activity（审计 + 本地告警）、Network & security（pending approvals、NetPolicy、reachability、nft baseline、Cloudflare tunnels，只读 + SHA-256 绑定 approve）、Notifications（通道/规则 + 测试）、Logs（日志源 + 行查询）、Tasks（远程任务 + 结果）、Account（身份/scopes/服务器版本/PAT 管理）、Settings、About。

## 覆盖的 Lattice API

`Sources/AstraCore/LatticeAPI.swift` 里的 `LatticeClient` 现在覆盖：

- 身份：`/api/me`、`/api/version`
- 节点：`/api/nodes`、disable/enable、rotate-token、enroll-token、geo get/set/resolve
- Token（PAT）：list / create / revoke
- 机器清单：list / update / delete / renew / reminders-run
- Monitors：list / create / delete / results
- Notify：channels、rules、test
- Network & security：approvals、NetPolicy list/graph、nft baseline inputs、tunnels，以及带 `plan_sha256` 的 approve
- Audit：查询（分页）+ 链校验
- Tasks：tasks + task-results
- Logs：sources / query（分页）/ stats

鉴权同时支持 PAT 和 `/api/login` session cookie + `X-Lattice-CSRF`，含 TOTP 登录挑战。请求体严格按服务端结构体字段构造（服务端开启了 `DisallowUnknownFields`）。

## 保留的 v1 能力

- 本地节点快照缓存（重开 App 先显示缓存再刷新）。
- 本地健康事件引擎：disabled/offline/stale、CPU/内存/磁盘阈值、恢复事件。
- Bark 自托管 `/push` 通知，带规范化 dashboard 点击 URL 和可配置 interruption level。
- Token、session cookie、CSRF token、Bark device key 全部进 iOS Keychain。
- `BGAppRefreshTask` best-effort 后台刷新，并在设置页显示最近一次结果。

## 目录结构

详细结构说明在 [docs/project-structure.md](docs/project-structure.md)。

核心文件：

- `Astra.xcodeproj/`：iOS App 工程。target 和 scheme 仍叫 `Astra`。
- `AstraApp/App/`：SwiftUI App 层（设计系统、各 Tab 与详情页）。
- `Sources/AstraCore/`：可测试的核心逻辑——`AstraCore.swift`（节点/登录/监控/Bark）、`LatticeModels.swift`（领域模型）、`LatticeAPI.swift`（完整控制面 API 客户端）、`LatticeNetwork.swift`（网络策略/审批/隧道模型与 API）、`LatticeAnalytics.swift`（Fleet/库存/Monitor 汇总与趋势缓冲）。
- `Checks/AstraCoreCheck/`：轻量级 Swift 回归检查，不依赖真机。
- `scripts/`：本地检查、iOS doctor、真机构建、development archive/export 脚本。
- `docs/`：项目结构、iOS 编译部署、实现计划。

## 快速使用

1. 打开 `Astra.xcodeproj`。
2. 在 `Astra` target 的 Signing & Capabilities 中选择你的 Apple Team。
3. 如果 `org.roobli.astra` 被占用，把 Bundle Identifier 改成自己的，例如 `com.yourname.lattice`.
4. 连接 iPhone，选择真机作为 run destination。
5. 按 Run。
6. 手机上打开 `Lattice`，进入 `More → Settings`。
7. 填入 Lattice server URL。
8. 填入 `node:read`（或更高权限）PAT，或用用户名密码登录保存 session。
9. 点 `Test Lattice connection`。
10. 填入 Bark device key，点 `Send test notification`。
11. 回到 Overview / Nodes 开始刷新和轮询，其余功能按权限自动加载。

## 本地验证 App 编译

除了 `AstraCoreCheck` 核心回归检查，本机可直接用模拟器编译整个 App（无需签名）：

```sh
xcodebuild -project Astra.xcodeproj -scheme Astra \
  -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

完整教程见 [docs/ios-build-deploy.md](docs/ios-build-deploy.md)。

## 本地验证

先跑不依赖真机的检查：

```sh
./scripts/check-local.sh
```

只跑核心协议和告警回归检查：

```sh
swift run --scratch-path .build AstraCoreCheck
```

检查本机 Xcode/iPhoneOS SDK/Simulator build 环境：

```sh
./scripts/doctor-ios.sh
```

`doctor-ios.sh` 需要完整 Xcode，而不是只安装 Command Line Tools。

## 命令行构建

真机 Debug build：

```sh
ASTRA_TEAM_ID=ABCDE12345 \
ASTRA_BUNDLE_ID=com.yourname.lattice \
./scripts/build-ios-device.sh
```

Development archive 并导出 `.ipa`：

```sh
ASTRA_TEAM_ID=ABCDE12345 \
ASTRA_BUNDLE_ID=com.yourname.lattice \
./scripts/archive-ios-development.sh
```

导出产物默认写到 `DerivedData/export/`。

## Bark 默认值

当前 Bark 默认配置来自个人自托管环境：

- Server: `http://bark.roobli.org`
- Group: `Lattice`
- Sound: `minuet`

Bark device key 不会硬编码进源码。第一次在 Settings 输入后会进入 iOS Keychain。把 secret 输入框清空并保存，会删除对应 Keychain 项。

如果 Bark server 没写协议，App 会默认补 `http://`，匹配当前自托管 Bark 部署。把完整 Bark URL 粘到 device key 输入框也可以，App 会提取第一个 path segment 作为 key。

## 重要限制

iOS 不允许普通 App 做可靠的 24 小时后台轮询。这个客户端的轮询在 App 运行时可靠，后台刷新只依赖 `BGAppRefreshTask`，由系统决定是否唤醒、何时唤醒、给多少时间。

因此：

- 手机端 Bark 告警适合个人辅助提醒。
- 严肃的 always-on 告警仍应放在 Lattice server、Bark server、Prometheus/Alertmanager 或其他常驻服务上。
- App 会把后台刷新结果显示出来，避免造成“以为在后台监控，其实系统没给机会运行”的误解。

## 参考文档

- [docs/project-structure.md](docs/project-structure.md)
- [docs/ios-build-deploy.md](docs/ios-build-deploy.md)
- [docs/install-on-iphone.md](docs/install-on-iphone.md)
- [docs/implementation-plan.md](docs/implementation-plan.md)

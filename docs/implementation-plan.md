# Lattice iOS Client 实现说明

## 目标

把原本的 Astra iOS 个人监控原型，改造成 Lattice 的手机优先控制面伴侣 App：在手机上尽量覆盖适合移动端的控制面功能，配合一套统一的 SwiftUI 设计语言。架构细节见 [v2-architecture.md](v2-architecture.md)。

## 参考来源

按本地 Lattice 代码对齐（只读，不修改）：

- Umbrella repo: `/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice`
- Server handlers: `lattice-server/internal/server/*.go`、view 投影 `server_views.go`
- Shared models: `lattice-sdk/model/model.go`
- RBAC scopes: `lattice-server/internal/rbac/rbac.go`

错误 envelope（所有非 2xx）：

```json
{ "error": { "code": "...", "message": "...", "request_id": "..." } }
```

客户端会把非空 `request_id` 追加到 `LatticeAPIError.serverError`
的 message 文本中，所以 Settings、后台刷新状态和本地检查输出能直接带上
server 端排障 ID。

## v1 已实现（个人监控原型）

- SwiftUI iOS App、节点 dashboard、节点详情、事件历史、设置。
- Lattice PAT 与 session cookie + CSRF 鉴权、TOTP 登录挑战。
- node/metrics/host facts/geo 解码、本地节点快照。
- 本地健康事件 + Bark `/push`（含 tap-through dashboard URL）。
- Keychain secret 存储、best-effort 后台刷新、Swift 回归检查、构建脚本。

## v2 已实现（控制面伴侣）

- 5-Tab 外壳（Overview / Nodes / Monitors / Inventory / More）+ 设计系统。
- 节点：禁用/启用、轮换 agent token、节点注册（一次性 token + QR）、geo get/set/resolve。
- Token(PAT)：列表 / 创建 / 吊销。
- 机器清单：列表 / 新增 / 编辑 / 删除 / 续费 / 跑提醒；月度成本与到期汇总。
- Monitors：列表 / 新建 / 删除 / 探测结果（uptime、延迟）。
- Notify：通道 / 规则 / 测试。
- Audit：分页查询 + 链校验；Activity 合并审计与本地告警。
- Tasks：远程任务 + 结果。Logs：日志源 / 行查询（分页）/ stats。
- Account：身份 / scopes / 服务器版本。
- 网络与安全（只读 + 受控 approve）：NetPolicy 列表/可达性图、nft baseline inputs、Cloudflare tunnels、审批队列；approve 时回传 `plan_sha256`（审阅计划的 SHA-256，TOCTOU 防护）。

## 当前边界（仍留在 Web dashboard）

- 网络**写操作**：建/改 NetPolicy、plan nft·wireguard、建/改 tunnels（手机端只读 + approve）。
- DNS / DDNS / geo-routing、proxy / 订阅、storage / KV / workers / static、plugins、OIDC provider 管理、2FA 注册/禁用。
- 不在 App 内内嵌 dashboard WebView（用系统浏览器打开）。

这些等需求稳定或确有手机端价值时再逐块加。

## 不承诺持续后台轮询

iOS 普通 App 不能可靠长时间后台轮询。前台轮询可靠，后台只依赖 `BGAppRefreshTask`（系统调度的 best-effort）。严肃 always-on 告警仍应放服务端/常驻系统；App 会显示最近一次后台刷新结果，避免误以为在后台监控。

## 监控事件规则

`MonitorEngine`（在 `AstraCore.swift`）处理：节点 disabled / offline / `last_seen` 超时、CPU/内存/磁盘超阈值、进入异常后 cooldown、恢复后 recovery 事件。

`MonitorEvent` 字段：`id`、`occurrenceID`、`nodeID`、`nodeName`、`kind`（offline/recovered/cpuCritical/memoryCritical/diskCritical）、`title`、`body`、`date`；解码兼容旧键 `serverID`/`serverName`。

## 配置和 secret

普通设置走 `UserDefaults`（Lattice URL、Bark、轮询/阈值、后台刷新开关与状态）。secret 走 Keychain（Lattice PAT、session cookie、CSRF token、Bark device key）。清空 secret 输入框并保存会删除对应 Keychain item。

## 验证策略

```sh
swift run --scratch-path .build AstraCoreCheck   # 核心 + API + 分析 + 网络层回归
./scripts/check-local.sh                          # 完整本地检查
./scripts/doctor-ios.sh                           # iOS 环境检查
xcodebuild -project Astra.xcodeproj -scheme Astra -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

真机安装、活数据、Bark 通知、后台刷新仍需在 iPhone 上人工验证（签名、设备 trust、通知权限、后台调度都依赖本地 Apple 账号与设备状态）。

## 后续可以做的事

- 把 `ServerDetailView.swift` 文件名改成 `NodeDetailView.swift`（类型已是 `NodeDetailView`），并更新 pbxproj 引用。
- 把某个 web-only 面（DNS、proxy/订阅、storage）按手机价值逐块搬进来。
- 网络面增加更多上下文（按 plugin 过滤审批、可达性图的图形化布局）。
- 更明确的 session 过期提示；TestFlight 发布脚本。
- 若 Lattice 提供 SSE/WebSocket/event API，减少手机端轮询。

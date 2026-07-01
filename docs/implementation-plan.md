# Lattice iOS Client 实现说明

## 目标

把原本的 Astra iOS 个人监控原型改造成 Lattice 的个人 iOS 客户端。

v1 的目标不是完整控制面，而是：

- 手机上查看 Lattice 节点状态。
- 保存最近一次节点快照。
- 做基础健康判断。
- 通过 Bark 发送个人提醒。
- 能从 Xcode 安装到 iPhone。

## 参考来源

本次实现按本地 Lattice 代码对齐：

- Umbrella repo: `/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice`
- Server routes:
  - `lattice-server/internal/server/server.go`
- Shared models:
  - `lattice-sdk/model/model.go`

已对齐的 API：

- `POST /api/login`
- `POST /api/login/totp`
- `GET /api/nodes`

已对齐的 error envelope：

```json
{
  "error": {
    "code": "...",
    "message": "...",
    "request_id": "..."
  }
}
```

客户端会把非空 `request_id` 追加到 `LatticeAPIError.serverError`
的 message 文本中，所以 Settings、后台刷新状态和本地检查输出能直接带上
server 端排障 ID。

## v1 已实现范围

- SwiftUI iOS App。
- Nodes dashboard。
- Node detail。
- Events history。
- Settings。
- Lattice PAT 鉴权。
- Lattice session cookie + CSRF 鉴权。
- TOTP login challenge。
- Lattice node/metrics/host facts/geo 解码。
- 本地节点快照。
- 基础健康事件。
- Bark `/push` JSON API。
- Bark tap-through Lattice dashboard URL。
- Keychain secret storage。
- Best-effort background app refresh。
- 本地 Swift 回归检查。
- Xcode/命令行构建脚本。

## 当前边界

### 不做完整控制面

v1 只读节点状态，不做：

- 节点创建/删除。
- token 管理。
- plugin 管理。
- dashboard 内嵌 WebView。
- agent 更新控制。

这些都应等 Lattice API 和交互需求稳定后再加。

### 不承诺持续后台轮询

iOS 普通 App 不能可靠地长时间后台轮询。当前实现使用 `BGAppRefreshTask`，但这是系统调度的 best-effort。

严肃告警应该放在服务端或常驻告警系统中。iOS 客户端只做个人辅助提醒。

## 监控事件规则

`MonitorEngine` 当前处理：

- 节点 disabled。
- 节点 offline。
- `last_seen` 超过 offline timeout。
- CPU 高于阈值。
- memory used/total 高于阈值。
- disk used/total 高于阈值。
- 进入异常后 cooldown。
- 状态恢复后生成 recovery event。

事件字段使用 Lattice 语义：

- `nodeID`
- `nodeName`
- `kind`
- `severity`
- `message`
- `createdAt`

为了读旧本地数据，解码时兼容旧键 `serverID/serverName`。

## 配置和 secret

普通设置走 `UserDefaults`：

- Lattice URL。
- Bark server/group/sound/level。
- poll/offline/cooldown/threshold。
- background refresh 开关。
- 最近一次后台刷新状态。

secret 走 Keychain：

- Lattice PAT。
- Lattice session cookie。
- Lattice CSRF token。
- Bark device key。

清空 secret 输入框并保存，会删除对应 Keychain item。

## 验证策略

轻量检查：

```sh
swift run --scratch-path .build AstraCoreCheck
```

完整本地检查：

```sh
./scripts/check-local.sh
```

iOS 环境检查：

```sh
./scripts/doctor-ios.sh
```

真机安装和 Bark 通知需要人工在 iPhone 上验证，因为签名、设备 trust、通知权限和后台刷新都依赖本地 Apple 账号和设备状态。

## 后续可以做的事

- 把 `ServerDetailView.swift` 文件名改成 `NodeDetailView.swift`，同时更新 Xcode project 引用。
- 增加节点搜索、tag 过滤和 role 过滤。
- 增加按 tag/role 配置阈值。
- 增加 Lattice dashboard deep link 或 universal link。
- 增加更明确的 session 过期提示。
- 做 TestFlight 发布脚本。
- 如果 Lattice server 提供 SSE/WebSocket/event API，可以减少手机端轮询。

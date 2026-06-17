# Lattice iOS Client

`Astra` 现在是 Lattice 的个人 iOS 客户端。Xcode 工程和 target 仍然叫 `Astra`，这是为了保留原工程结构；安装到手机后的 App 显示名是 `Lattice`。

当前定位很明确：它不是 Lattice 控制面的完整替代品，而是手机上的节点状态面板、基础健康告警器和 Bark 通知入口。

## 当前功能

- 连接自托管 Lattice control plane。
- 通过 `GET /api/nodes` 拉取节点列表。
- 支持两种 Lattice 鉴权方式：
  - Personal Access Token，要求至少有 `node:read` 权限。
  - `/api/login` 用户名密码登录，保存 `lattice_session` cookie 和 CSRF token。
- 支持 Lattice TOTP 登录挑战。第一次登录返回 TOTP challenge 后，在设置页输入 TOTP code 再点一次登录即可保存 session。
- 解码并展示 Lattice 节点字段：
  - 在线、离线、禁用状态
  - CPU、load、内存、磁盘、网络流量、uptime
  - public IP、IPv6、WireGuard IP、endpoint、agent version
  - host facts，包括 hostname、OS、kernel、arch、CPU、内存、虚拟化信息
  - geo 信息
- 保存最近一次节点快照，重新打开 App 时先显示本地缓存，再刷新远端数据。
- 内置基础健康事件：
  - disabled/offline/stale
  - CPU 阈值
  - 内存阈值
  - 磁盘阈值
  - 从异常恢复时生成 recovery 事件
- 通过 Bark 自托管 `/push` JSON API 发送通知。
- Bark 通知包含规范化后的 Lattice dashboard URL，点击通知可以打开控制面，而不是打开 `/api/nodes`。
- 支持 Bark interruption level，默认 `timeSensitive`。
- Lattice token、session cookie、CSRF token、Bark device key 都存入 iOS Keychain。
- 注册 iOS `BGAppRefreshTask`，让系统在允许时做 best-effort 后台刷新。
- 设置页会记录最近一次后台刷新结果，后台失败不会静默吞掉。

## 目录结构

详细结构说明在 [docs/project-structure.md](docs/project-structure.md)。

核心文件：

- `Astra.xcodeproj/`：iOS App 工程。target 和 scheme 仍叫 `Astra`。
- `AstraApp/App/`：SwiftUI App 层。
- `Sources/AstraCore/`：可测试的 Lattice 协议、模型、监控和 Bark 核心逻辑。
- `Checks/AstraCoreCheck/`：轻量级 Swift 回归检查，不依赖真机。
- `scripts/`：本地检查、iOS doctor、真机构建、development archive/export 脚本。
- `docs/`：项目结构、iOS 编译部署、实现计划。

## 快速使用

1. 打开 `Astra.xcodeproj`。
2. 在 `Astra` target 的 Signing & Capabilities 中选择你的 Apple Team。
3. 如果 `org.roobli.astra` 被占用，把 Bundle Identifier 改成自己的，例如 `com.yourname.lattice`.
4. 连接 iPhone，选择真机作为 run destination。
5. 按 Run。
6. 手机上打开 `Lattice`，进入 Settings。
7. 填入 Lattice server URL。
8. 填入 `node:read` PAT，或用用户名密码登录保存 session。
9. 点 `Test Lattice connection`。
10. 填入 Bark device key，点 `Send test notification`。
11. 回到 Nodes 页开始刷新和轮询。

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

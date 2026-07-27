# Spec：bound-file-watcher-footprint

## 意图

把长期运行时 watcher/FD 增长从“疑似泄漏”变成可测量契约，并消除已由代码证明的跨窗口重复：多个 `TabManager` 打开同一个 repository 时，当前每个 window 都创建一套相同 `.git` FSEventStream。关闭最后一个消费者后，底层 stream 必须确定释放并回到 baseline。

## 方案摘要

先在 `FileSystemEventStream` 增加线程安全的 active-stream 计数，固定 start/stop/deinit 平衡；再把 `SidebarGitMetadataService` 当前仅 service 内共享的 watcher 提升到进程级、引用计数的 `WorkspaceGitMetadataWatcherRegistry`。registry 只按现有 normalized full watched-path set 共享完全相同的 watcher，并向各 service fan-out 事件；每 service 的 snapshot/cache generation 继续本地持有。

## 范围 / 非目标

### 范围内

- 为实际启动的 FSEventStream 提供进程级 active count debug/test seam。
- 保证 explicit stop 与 deinit 都只 decrement 一次并同步释放 stream ownership。
- 同一进程内跨 window/service、完全相同 watched-path set 只保留一个 watcher。
- 每个 service 显式释放自己持有的 registry subscriptions；最后一个释放时停止 watcher 和 refresh task。
- 保持 event fan-out、probe key、generation 与 snapshot eligibility 语义。

### 范围外

- 不宣称或修复尚未证实的 840 个 `DIR` fd 泄漏。
- 不把 FileExplorer whole-tree watcher 与 Sidebar Git watcher 合并。
- 不做 ancestor coalescing。
- 不拆分 linked-worktree 的 shared common-dir 与 per-worktree git-dir watcher；full path set 不同仍保留独立 stream。
- 不改变 Git metadata refresh 内容或 throttle 时序。

## 可观察行为

1. 一个真实 `FileSystemEventStream` 启动时 active count 增加 1；`stop()` 或 owner deinit 后回到原 baseline，重复 stop 不重复 decrement。
2. 两个独立 `SidebarGitMetadataService` 订阅同一 normalized watched-path set 时，只创建一个底层 watcher。
3. 任一 service 释放订阅不影响另一个仍存活的 service；最后一个订阅释放后 watcher/refresh task 被销毁，active count 回落。
4. shared watcher 的一次 filesystem event 分别通知每个订阅 service；每个 service 只推进自己的 generation/cache。
5. 不同 repos、parent 与 submodule、不同 linked worktrees（full set 不同）不被错误合并。
6. 连续创建/销毁多个模拟 window/service 后 active count 有界，不随 churn 单调增长。

## Bug 复现证据

- live cmux 曾观测到约 834 个 `DIR`、252 个 `PIPE`、38 个 `KQUEUE` fd；该数值本身不足以证明 watcher 泄漏。
- 代码事实：`WorkspaceGitMetadataWatchedPathsKey` 已在单个 service 内按 `Array(Set(paths)).sorted()` 去重，`FileSystemEventStream.stop()` 也调用 Stop/Invalidate/Release。
- 代码事实：每个 `TabManager` 单独构造 `SidebarGitMetadataService`，watcher map 属于 service；同一 repo 跨 window 因而必然创建 N 份完全相同的 stream。这是本 change 修复的已证实冗余。

## First-Principles Snapshot

- 真实目标：长期 window/panel churn 不得无界占用 watcher/kqueue/fd；完全相同输入只付一次 OS watcher 成本。
- 最小机制：一个 start/stop 平衡计数器；一个按现有 full-set key 的进程级 ref-count registry；明确 subscription teardown。
- 边界 / 非目标：不把高 baseline 当 leak，不跨不同 consumer domain 合并，不优化 linked-worktree overlap。
- 当前事实：单 service exact-set dedup 与底层 stop 已存在；缺的是跨 service ownership。
- 关键未知：FSEventStreamRelease 后 OS fd 是否有短暂异步回收窗口；测试/运行 smoke 使用有界等待而非假设瞬时 lsof 变化。
- 证据门槛：package tests 证明 count balance、cross-service sharing、fan-out 和 last-release；tagged app 多 window 同 repo 的 active count/lsof 有界。
- 推荐选择：仅共享完全相同 full watched-path set；这是最小、可逆且不改变 submodule/linked-worktree correctness 的方案。

## 受影响文件 / 模块

| 路径 / 模块 | 预期动作 | 作用 / 链路 |
|---|---|---|
| `Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/Concurrency/AtomicUInt64Counter.swift` | add | 同步 lifecycle callback 可用的 C11 atomic increment/decrement metric |
| `Packages/macOS/CmuxFoundation/Sources/CmuxFoundationAtomicsC/CmuxFoundationAtomicsC.c`、`Packages/macOS/CmuxFoundation/Sources/CmuxFoundationAtomicsC/include/CmuxFoundationAtomicsC.h` | modify | counter 原子 increment/decrement primitives |
| `Packages/macOS/CmuxFoundation/Tests/CmuxFoundationTests/Concurrency/AtomicUInt64CounterTests.swift` | add | 并发 balance、underflow/saturation behavior |
| `Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/FileWatch/FileSystemEventStream.swift` | modify | active stream count 与 exactly-once stop accounting |
| `Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/FileWatch/RecursivePathWatcher.swift` | modify | 暴露 debug/test count seam |
| `Packages/macOS/CmuxFoundation/Tests/CmuxFoundationTests/FileWatch/RecursivePathWatcherTests.swift` | modify | start/stop/deinit balance tests |
| `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/WorkspaceGitMetadataWatcherRegistry.swift` | add | process-wide exact-set watcher subscription registry |
| `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/WorkspaceGitMetadataWatcherSource.swift` | add | production RecursivePathWatcher adapter 与 package-internal injectable event-source seam |
| `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/SidebarGitMetadataService.swift` | modify | registry injection、ownership 与 deinit teardown |
| `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/SidebarGitMetadataService+Watchers.swift` | modify | watcher acquire/release/fan-out 路径 |
| `Packages/macOS/CmuxSidebarGit/Tests/CmuxSidebarGitTests/ProbeSnapshotCacheTests.swift` | modify | 既有 per-service cache/generation 语义 |
| `Packages/macOS/CmuxSidebarGit/Tests/CmuxSidebarGitTests/WorkspaceGitMetadataWatcherRegistryTests.swift` | add | cross-service sharing/refcount/distinctness tests |
| `Sources/TabManager.swift` | modify | 注入唯一 process-wide registry |
| `Sources/AppDelegate.swift` | modify | app composition root 持有并向后续 window 传递同一 registry |
| `Sources/cmuxApp.swift`、`Resources/Localizable.xcstrings` | modify | DEBUG 菜单输出 production registry instance metrics |

## 设计 / 决策

### 关键决策

- 新增 `AtomicUInt64Counter` 复用现有 `CmuxFoundationAtomicsC`，以 C11 atomic 实现 synchronous increment/decrement；这是一项 production diagnostic metric，不是可替换的 test override。`FileSystemEventStream` 只在成功创建/启动 ownership 后 increment，既有 idempotent `stopOnQueue()` 在 Stop/Invalidate/Release 时 decrement。
- registry 为 `actor` service，key 复用 `WorkspaceGitMetadataWatchedPathsKey`；entry 持有一个 injectable watcher source、一个唯一 event-pump task 和按 subscription token 区分的 `@Sendable` event sinks。production adapter 独占迭代 `RecursivePathWatcher.events`；tests 注入可控 fake source。
- registry 暴露 instance-scoped async snapshot（entry/subscription count）和 deterministic `waitUntilIdle()`；global active-stream counter 只验证底层 ownership，不作为并行 registry tests 的唯一 oracle。
- subscription token 明确属于某个 service/probe key。service initializer 提供每实例新 registry 的非-singleton default；production 由 `TabManager` 注入共享实例。现有同步 `stop`/`stopAll`/deinit 只取消 listener tasks；listener cancellation 的 `defer` 复制 Sendable registry/token 后启动不捕获 self 的 async release。tests/smoke 再 await registry `waitUntilIdle()`，最后 token 消失时 entry cancel + stop，不把 async ripple 扩散到同步 @MainActor callers。
- registry 只负责 OS event multiplexing；`sourceDirectoryByKey`、snapshot eligibility 和 generation map 不移出 service，避免窗口间 cache state 污染。
- `TabManager` 以 initializer parameter 接收 registry；初始 manager 创建默认实例，`AppDelegate.configure` 像现有 `PullRequestProbeService` 一样 adopt 该实例，后续 windows 显式复用。不得新增 `static let shared` 或 package singleton；DEBUG 菜单通过该 production instance 输出 registry 与 active-stream metrics。

### 不采用的方案

- 根据 path ancestor 合并 FileExplorer 与 Git watcher：生命周期和 consumer 语义不同，且会让隐藏状态错误耦合。
- 按 repository common-dir 直接合并：linked worktree 仍有不同 git-dir paths，需要拆分 event ownership，当前证据不足。
- 只依赖 `lsof` 数值：无法在 unit tests 中区分 framework baseline、WebKit 与 cmux ownership。
- 仅在 service deinit 靠 ARC：shared registry 会延长 watcher 寿命，必须显式 release subscriptions。

## 验证计划

- `swift test --package-path Packages/macOS/CmuxFoundation --filter RecursivePathWatcherTests`，预期：`.serialized` active-count tests 对 start/stop/deinit 平衡且重复 stop 安全。
- `swift test --package-path Packages/macOS/CmuxSidebarGit --filter WorkspaceGitMetadataWatcherRegistryTests` 与 `--filter ProbeSnapshotCacheTests`，预期：fake event source 确定性证明 cross-service exact-set sharing、fan-out、last release、idle 与 distinct repo/submodule。
- `./scripts/reload.sh --tag dev --launch`，在 baseline、3 个同 repo window、全部关闭三个阶段分别执行 Debug → Log Workspace Git Watcher Metrics 并读取 `/tmp/cmux-debug-dev.log`，同时采样 scoped `lsof`；预期 entry 只 +1、subscriptions +3、关闭后 5 秒内三项 metrics 回 baseline。

## 风险 / 回退

最大风险是共享 ownership 下漏 release，反而把临时 watcher 变为进程级泄漏。deinit/stopAll/last-release tests 是强制门槛。若 registry fan-out 引入 correctness 回归，可回退跨 service sharing，但保留 active-count instrumentation；不得声称未测的 fd leak 已修复。

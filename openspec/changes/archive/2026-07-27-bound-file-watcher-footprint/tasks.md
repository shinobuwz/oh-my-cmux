# Tasks：bound-file-watcher-footprint

## 1. 可测量的 stream ownership

- [x] 1.1 为 FSEventStream start/stop 增加 exactly-once active count
  - Allowed Files: `Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/Concurrency/AtomicUInt64Counter.swift`, `Packages/macOS/CmuxFoundation/Sources/CmuxFoundationAtomicsC/CmuxFoundationAtomicsC.c`, `Packages/macOS/CmuxFoundation/Sources/CmuxFoundationAtomicsC/include/CmuxFoundationAtomicsC.h`, `Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/FileWatch/FileSystemEventStream.swift`, `Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/FileWatch/RecursivePathWatcher.swift`, `Packages/macOS/CmuxFoundation/Tests/CmuxFoundationTests/Concurrency/AtomicUInt64CounterTests.swift`, `Packages/macOS/CmuxFoundation/Tests/CmuxFoundationTests/FileWatch/RecursivePathWatcherTests.swift`
  - Blockers: 无
  - 验收：C11 counter 并发 increment/decrement 正确且不 underflow；真实 watcher start 后 count +1；explicit stop、重复 stop、deinit 都回到原 baseline；public counter API 有 DocC，unsafe primitive 有安全说明。所有断言 process-global active count 的 tests 置于 `.serialized` suite，每个 test 用 `defer`/显式 stop 清理，避免并行 suite 污染 baseline。
  - 验证：`swift test --package-path Packages/macOS/CmuxFoundation --filter AtomicUInt64CounterTests --filter RecursivePathWatcherTests`，预期 counter 与序列化 watcher balance/churn tests 全通过。

## 2. 跨 service exact-set 共享

- [x] 2.1 新增 process-wide ref-counted watcher registry、可注入 event source 与行为 tests
  - Allowed Files: `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/WorkspaceGitMetadataWatcherRegistry.swift`, `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/WorkspaceGitMetadataWatcherSource.swift`, `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Model/WorkspaceGitMetadataWatchedPathsKey.swift`, `Packages/macOS/CmuxSidebarGit/Tests/CmuxSidebarGitTests/WorkspaceGitMetadataWatcherRegistryTests.swift`
  - Blockers: 1.1
  - 验收：registry 构造器接受 package-internal watcher/event-source factory；production adapter 独占迭代一个 `RecursivePathWatcher.events` 并 fan-out，tests 注入可控 fake source，不跨模块访问 CmuxFoundation internal seam；两个 subscription 的 normalized full path set 相同只启动一个 source；事件 fan-out；单方 release 不停 source；last release 停止；不同 set 不共享。actor 暴露 instance-scoped async debug snapshot（entry/subscription count）和 deterministic `waitUntilIdle()` test seam，不用 sleep 或 process-global count 断言 registry 行为。
  - 验证：`swift test --package-path Packages/macOS/CmuxSidebarGit --filter WorkspaceGitMetadataWatcherRegistryTests`，预期 sharing/refcount/fan-out/distinctness/idle 全通过。

- [x] 2.2 将 SidebarGitMetadataService 接入 registry并保持 cache/generation 本地
  - Allowed Files: `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/SidebarGitMetadataService.swift`, `Packages/macOS/CmuxSidebarGit/Sources/CmuxSidebarGit/Service/SidebarGitMetadataService+Watchers.swift`, `Packages/macOS/CmuxSidebarGit/Tests/CmuxSidebarGitTests/ProbeSnapshotCacheTests.swift`, `Packages/macOS/CmuxSidebarGit/Tests/CmuxSidebarGitTests/ProbeSchedulingTests.swift`, `Packages/macOS/CmuxSidebarGit/Tests/CmuxSidebarGitTests/ProbeApplyRaceTests.swift`, `Packages/macOS/CmuxSidebarGit/Tests/CmuxSidebarGitTests/PassiveMetadataActivityTests.swift`, `Sources/TabManager.swift`, `Sources/AppDelegate.swift`, `Sources/cmuxApp.swift`, `Resources/Localizable.xcstrings`
  - Blockers: 2.1
  - 验收：service initializer 提供“每实例新 registry”的非 singleton default，production 由 TabManager 注入共享 registry，既有 tests/callers 保持可编译；各 service 的 listener task 独占 subscription，现有同步 `stop`/`stopAll`/deinit 只取消 listener task，不引入 async ripple；listener cancellation 的 `defer` 复制 Sendable registry/token 后启动不捕获 self 的 async unsubscribe。tests/smoke 通过 registry `waitUntilIdle()` 等待 release 完成。每 service generation/eligibility 独立；parent/submodule/linked-worktree 不误合并；initial manager 与后续 windows 由 AppDelegate composition root 复用同一实例，不新增 singleton。DEBUG 菜单动作调用 AppDelegate production registry 的 async debug snapshot，并通过 `cmuxDebugLog` 输出 `workspaceGitWatcher entries=<n> subscriptions=<n> activeStreams=<n>`。
  - 验证：`swift test --package-path Packages/macOS/CmuxSidebarGit --filter ProbeSnapshotCacheTests --filter WorkspaceGitMetadataWatcherRegistryTests` 与 `./scripts/test-unit.sh build`，预期 package 行为 tests 和 Swift 6 app composition 编译通过；本地化 debug key 有 en/ja。

## 3. Runtime FD 验收

- [x] 3.1 验证多窗口 churn 后 watcher/FD 回到 baseline
  - Allowed Files: `openspec/changes/bound-file-watcher-footprint/tasks.md`, `openspec/changes/bound-file-watcher-footprint/evidence.md`
  - Blockers: 2.2
  - 验收：tagged app baseline 先执行 Debug → Log Workspace Git Watcher Metrics 并从 `/tmp/cmux-debug-dev.log` 记录三项 metrics；打开 3 个同 repo window 后再次执行，registry entry 仅 +1 而 subscription +3；关闭全部后反复执行至有界 5 秒内 entries/subscriptions/activeStreams 回到 baseline；记录 lsof 但不把全局 DIR 数误归因为 watcher leak。
  - 验证：`./scripts/reload.sh --tag dev --launch`，通过 `agent-cu` 操作 Debug 动作，并读取 `/tmp/cmux-debug-dev.log` 的 `workspaceGitWatcher` 行与 `lsof -nP -p <pid>`；预期 exact-set 共享、last-close 回落且无单调增长。

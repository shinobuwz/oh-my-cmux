# Evidence：stabilize-git-terminal-creation

## Final Verification

- Fresh verification: `CmuxFoundation` selected suites passed 26 tests (`CommandRunnerTests`, `AtomicUInt64CounterTests`, `RecursivePathWatcherTests`); `CmuxGit` worktree runner passed 10 tests; `CmuxTerminal` restore/renderer suites passed 21 tests.
- Tagged app 首次 smoke 暴露 `CommandTimer` 释放未激活 DispatchSource 的真实启动崩溃；修复为先 resume 再 cancel，并由 64 路 regression 覆盖。
- App focused tests were re-attempted but the shared `cmuxTests` target is currently blocked by unrelated stale `TabManagerUnitTests` group APIs (`childWorkspaceIds` / `groupId`). Per the user's archive-now decision, this unrelated suite blocker and the slow-Git wrapper dogfood were not pursued further.
- `./scripts/lint-pbxproj-test-wiring.sh`, pbxproj normalization/check, and Package.resolved policy checks passed. `./scripts/reload.sh --tag dev` succeeded; `agent-cu` confirmed the live `~/cmux` window, terminal creation control, and DEBUG failure-once action. All 11 new terminal/browser/debug UI keys parse with English/Japanese translations.

## Decisions

- 将 Git runner、Diff lifecycle 与 terminal shim/runtime 创建放在同一 change：现场证据显示它们构成一个用户可见故障链，任一半单独交付都不能证明“Git 卡住时仍可新建 terminal”。
- 用户选择 shim 失败时降级为普通 terminal；native runtime 失败时保留 tab、显示错误与 Retry，不静默无限重试。
- `.aiknowledge/codemap/index.md` 与 `.aiknowledge/pitfalls/index.md` 当前不存在；本 change 不依赖未验证 knowledge。若实现确认可复用的 Process/terminal failure mode，归档后触发 bounded knowledge capture 初始化对应 codemap/pitfall。

## Failures / Rollbacks

- 原假设“当前 Git 仓库扫描本身很慢”被现场命令证伪：相同 `git status` 约 0.09 秒；方向收敛为 Process/Pipe 生命周期修复。

## Deferred Coverage

- Final reviewer found no P0/P1 production defect. P2 coverage still missing: owner-level `FileExplorerStore` cancellation for root/monitoring/deinit, deterministic Diff stop/restart polling, and an observed terminal Retry-to-ready transition. Per the user's archive-now decision, these were recorded rather than pursued.


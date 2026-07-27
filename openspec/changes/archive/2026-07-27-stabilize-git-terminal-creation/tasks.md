# Tasks：stabilize-git-terminal-creation

## 1. 有界且可取消的进程执行

- [x] 1.1 修复共享 `CommandRunner` 的取消与 Pipe 生命周期
  - Allowed Files: `Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/Process/CommandRunner.swift`, `Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/Process/CommandRunning.swift`, `Packages/macOS/CmuxFoundation/Tests/CmuxFoundationTests/Process/CommandRunnerTests.swift`
  - Blockers: 无
  - 验收：父 Task 取消或 deadline 到达时只完成一次、终止 child、关闭由 runner 拥有的 fd；stdout/stderr capture 不占用 Swift cooperative worker 做无限阻塞 read；现有大输出和 descendant-holds-pipe 行为保持。
  - 验证：`swift test --package-path Packages/macOS/CmuxFoundation --filter CommandRunnerTests`，预期全部通过，新增 cancellation test 在旧实现上可复现非及时返回。

## 2. Git 调用收敛与 Diff 生命周期

- [x] 2.1 将 Git Diff store 迁移到统一 runner并按可见性启停
  - Allowed Files: `Sources/RightSidebarPanelView.swift`, `cmuxTests/SidebarGitProcessCompositionTests.swift`
  - Blockers: 1.1
  - 验收：同一 store 最多一个 scan；切目录、隐藏 Diff 或销毁 store 会取消旧命令和 poll；超时/失败清除 loading 并显示 Retry；恢复可见立即刷新。
  - 验证：`./scripts/test-unit.sh test -only-testing:cmuxTests/SidebarGitProcessCompositionTests`，预期 generation、visibility、timeout 行为通过。

- [x] 2.2 将文件侧栏 Git status、app worktree 与 packaged worktree 命令迁移到统一 runner
  - Allowed Files: `Sources/GitStatusProvider.swift`, `Sources/FileExplorerStore.swift`, `Sources/GitWorktreeStore.swift`, `Packages/macOS/CmuxGit/Sources/CmuxGit/Worktree/SystemGitWorktreeCommandRunner.swift`, `Packages/macOS/CmuxGit/Tests/CmuxGitTests/SystemGitWorktreeCommandRunnerTests.swift`, `cmuxTests/FileExplorerGitStatusProviderTests.swift`, `cmuxTests/GitWorktreeStoreTests.swift`, `cmux.xcodeproj/project.pbxproj`
  - Blockers: 1.1
  - 验收：三个调用域均设置 deadline；`GitStatusProvider` 为 async，`FileExplorerStore` 持有并在 root/monitoring/teardown 变化时取消实际 query Task；app `GitWorktreeStore` 注入 runner 并覆盖 read-only (`GIT_OPTIONAL_LOCKS=0`) 与 mutating env、timeout/cancel/output/error mapping；packaged runner 保留 `GitWorktreeCommandOutcome`；取消后无 Process/Pipe；新 app test 已正确 wiring 到 cmuxTests target。
  - 验证：`./scripts/test-unit.sh test -only-testing:cmuxTests/FileExplorerGitStatusProviderTests -only-testing:cmuxTests/GitWorktreeStoreTests`，`./scripts/lint-pbxproj-test-wiring.sh`，`python3 scripts/normalize-pbxproj.py` 后 `./scripts/check-pbxproj.sh`，以及 `swift test --package-path Packages/macOS/CmuxGit --filter SystemGitWorktreeCommandRunnerTests`；预期三个调用域 focused tests 全通过、app tests 非 0 tests、project file normalized。

## 3. Terminal 创建 fail-open 与显式失败态

- [x] 3.1 解除 shim 对 native terminal 创建的硬门控
  - Allowed Files: `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+ClaudeCommandShimLifecycle.swift`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeLifecycle.swift`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift`, `Packages/macOS/CmuxTerminal/Tests/CmuxTerminalTests/TerminalSurfaceRestoreSpawnSchedulerTests.swift`
  - Blockers: 无
  - 验收：shim install 被 gate 或返回 nil 时本次 create 仍尝试 native surface；shim 之后完成只缓存供未来 respawn，不能二次创建 live surface。
  - 验证：`swift test --package-path Packages/macOS/CmuxTerminal --filter TerminalSurfaceRestoreSpawnSchedulerTests`，预期 delayed/failed shim 行为通过，旧实现在 delayed case 上失败。

- [x] 3.2 增加 terminal runtime 创建失败状态、共享 Retry、本地化 overlay 与 DEBUG failure-once seam
  - Allowed Files: `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalRuntimeCreationPhase.swift`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalRuntimeCreationState.swift`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeLifecycle.swift`, `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+Debug.swift`, `Packages/macOS/CmuxTerminal/Tests/CmuxTerminalTests/TerminalSurfaceRestoreSpawnSchedulerTests.swift`, `Sources/Panels/TerminalPanelView.swift`, `Sources/cmuxApp.swift`, `Resources/Localizable.xcstrings`
  - Blockers: 3.1
  - 验收：runtime app 缺失或 surface nil 时进入 failed；child state 使用 `@Observable` 而非新增 Combine；tab 显示 English/Japanese 错误与 Retry；Retry 走共享 create path，成功后为 ready；teardown 清理状态；public package symbols有 DocC。DEBUG 菜单的本地化“Fail Next New Terminal Creation”arm package 内 `@MainActor` process-global 一次性 flag；下一条新 `TerminalSurface` 的 shared native creation point 原子消费 flag并返回 nil，后续 surface 不受影响；该 seam 不复制/绕过 production failure 状态机。
  - 验证：`swift test --package-path Packages/macOS/CmuxTerminal --filter TerminalSurfaceRestoreSpawnSchedulerTests`；再 `./scripts/reload.sh --tag dev --launch`，用 `agent-cu` 执行 Debug → Fail Next New Terminal Creation、创建新 terminal、观察 overlay并点 Retry；预期第一次新建失败、Retry 成功、再新建不失败；本地化 JSON 可解析且新增 key 含 en/ja。

## 4. 集成验收

- [x] 4.1 验证 Git 卡住不再阻止创建 terminal
  - Allowed Files: `openspec/changes/stabilize-git-terminal-creation/tasks.md`, `openspec/changes/stabilize-git-terminal-creation/evidence.md`
  - Blockers: 2.1, 2.2, 3.2
  - 验收：创建 `/tmp/cmux-slow-git/git` wrapper：仅对 `status`/`diff` 写 PID 到 `/tmp/cmux-slow-git/pid` 后阻塞并 `trap TERM/INT/EXIT` 记录退出，其他命令 `exec /usr/bin/git "$@"`；用 `launchctl setenv PATH "/tmp/cmux-slow-git:/usr/bin:/bin:/usr/sbin:/sbin"` 后通过 `agent-cu` 打开 tagged app，开启 Diff 等待 PID 文件，隐藏/切换 Diff 后 2 秒内 wrapper PID 退出；随后新建 terminal 产生新的 `/dev/ptmx`/login 且界面可交互；关闭面板后 PIPE 数回落。smoke 结束必须 `launchctl unsetenv PATH` 并删除 wrapper。
  - 验证：先 `./scripts/reload.sh --tag dev`，通过 `agent-cu open <reload 输出的 App path>` 启动受控环境；用 `CMUX_TAG=dev scripts/cmux-debug-cli.sh debug-terminals` 记录前后 surface/PTY，`sample <app-pid> 2` 与 `lsof -nP -p <app-pid>` 记录取消后状态；预期无目标 wrapper PID、无持久 `GitDiffSnapshotStore.waitUntilExit`，新 surface `runtime_surface_ready=true`。

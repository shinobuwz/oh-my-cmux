# Spec：stabilize-git-terminal-creation

## 意图

消除 Git Diff 永久停在 “Loading changes…” 并进一步饿死新终端创建的级联故障。任何 Git 子进程卡住、workspace 切换或辅助 CLI shim 安装失败，都不得阻止用户获得一个可用 PTY；native terminal 创建失败必须成为可见、可重试的状态，而不是空白 tab。

## 方案摘要

把 Git 调用收敛到一个有 deadline、结构化取消和非 cooperative-blocking 管道读取的 `CommandRunner`；Diff 面板仅在可见且处于 Diff 模式时刷新。终端创建不再等待 Claude/Codex shim，shim 作为 best-effort 集成异步完成；native runtime 创建失败时保留 tab，展示错误和 Retry，所有 attach/input/retry 入口走同一创建状态机。

## 范围 / 非目标

### 范围内

- 修复 `CommandRunner` 的父 Task 取消、Pipe 读端和子进程终止生命周期。
- 将 Git Diff、文件侧栏 Git status、worktree Git 命令迁移到同一有界 runner；旧扫描取消时真实终止进程。
- Diff 面板隐藏或切离 `.diff` 时停止轮询；恢复可见时立即刷新。
- terminal shim 不再是 `ghostty_surface_new`/PTY 创建的前置条件。
- 为 native runtime 创建失败增加明确状态、可见错误和 Retry；保留工作目录与 tab。
- 新增用户文案的 English/Japanese 本地化。

### 范围外

- 不改变 Git diff 内容语义，不移除 `--untracked-files=all`。
- 不修改 terminal renderer reclaim/IOSurface 状态机；由 sibling change `repair-terminal-renderer-recovery` 处理。
- 不改变 Claude/Codex wrapper 行为，只把安装从核心创建链解耦。
- 不把单次 terminal 创建失败升级为 app/session 级熔断。

## 可观察行为

1. Git 命令超过 deadline 或其调用 Task 被取消时，调用方及时返回；子进程被终止，Pipe reader 不占用 Swift cooperative worker 等待 EOF。
2. workspace 快速切换只允许最新目录结果落地，旧命令被终止；不会按切换次数累积 `waitUntilExit`/PIPE。
3. 右侧栏隐藏或模式不是 `.diff` 时不再执行 5 秒 Git Diff 轮询；重新显示 Diff 时立即刷新。
4. Git 命令失败或超时后，Diff 面板停止 loading 并显示现有错误/Retry 状态。
5. bundled Claude/Codex shim 不存在、安装失败或安装任务延迟时，新 terminal 仍创建普通 PTY；shim 完成后只供未来 respawn 使用。
6. `runtimeApp` 不可用或 `ghostty_surface_new` 返回 nil 时，tab 保持存在并显示本地化错误与 Retry；Retry 使用同一 runtime 创建入口，成功后错误消失。
7. 已有 terminal 的健康状态不参与新 terminal 创建判定。

## Bug 复现证据

- `/tmp/cmux-stuck-terminal-second.sample.txt`：6 个 worker 在整个采样期间停在 `GitDiffSnapshotStore.runGit → NSConcreteTask.waitUntilExit`，另有 Pipe reader 停在 `read(2)`。
- 同时运行完全相同的 `git status --porcelain=v1 -z --untracked-files=all` 约 0.09 秒，证明 spinner 不是当前仓库计算耗时。
- 空白 tab 出现时运行进程仍只有 8 个 `/usr/bin/login`、8 个 `/dev/ptmx` 和 8 组 ghostty runtime 线程，没有第 9 个 PTY/runtime。

## First-Principles Snapshot

- 真实目标：长期运行和外部资源压力下，Git 辅助功能失败不能破坏创建新 shell 这一核心能力。
- 最小机制：一个可取消有界进程 runner；一个由可见性驱动的 Diff refresh 生命周期；一个不依赖 shim 的 terminal 创建入口；一个显式失败/重试状态。
- 边界 / 非目标：不重写 Git UI，不改变 diff 语义，不处理 renderer/WebKit。
- 当前事实：现有三个 Git runner 均存在阻塞 `Process`/Pipe 路径；terminal `createSurface` 在 shim ready 前 return；Release 的 native create 失败静默。
- 关键未知：不同 macOS Foundation 版本对 Pipe 父写端的隐式关闭行为不同，因此实现必须显式拥有并关闭 fd，不能依赖该细节。
- 证据门槛：取消/descendant-holds-pipe 行为测试；Diff store 可见性与 generation 测试；terminal shim gate/native failure 状态测试；tagged app 中实际打开 terminal 并观察 PTY 数增长。
- 推荐选择：终端 fail-open 到普通 PTY；native create 失败保留 tab并提供 Retry。用户已确认。

## 受影响文件 / 模块

| 路径 / 模块 | 预期动作 | 作用 / 链路 |
|---|---|---|
| `Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/Process/CommandRunner.swift` | modify | 取消、deadline、Pipe capture 和 process teardown 的唯一实现 |
| `Packages/macOS/CmuxFoundation/Tests/CmuxFoundationTests/Process/CommandRunnerTests.swift` | modify | cancellation/pipe descendant red-capable tests |
| `Sources/RightSidebarPanelView.swift` | modify | Diff store 使用统一 runner并受可见性驱动 |
| `Sources/GitStatusProvider.swift` | modify | 文件侧栏 Git status 迁移到统一 runner |
| `Sources/FileExplorerStore.swift` | modify | 持有并取消当前 async Git-status Task，generation 只保护结果一致性 |
| `Sources/GitWorktreeStore.swift` | modify | 注入共享 runner；worktree read/mutate 命令使用 deadline、结构化取消与正确 env |
| `Packages/macOS/CmuxGit/Sources/CmuxGit/Worktree/SystemGitWorktreeCommandRunner.swift` | modify | packaged worktree 调用复用有界 `CommandRunner`，移除第四套 Process/Pipe 生命周期 |
| `Packages/macOS/CmuxGit/Tests/CmuxGitTests/SystemGitWorktreeCommandRunnerTests.swift` | add | packaged runner cancellation/deadline/output 映射 |
| `cmuxTests/SidebarGitProcessCompositionTests.swift`、`cmuxTests/FileExplorerGitStatusProviderTests.swift` | modify | Diff store lifecycle、async status cancellation/deadline 与 runner composition 行为覆盖 |
| `cmuxTests/GitWorktreeStoreTests.swift`、`cmux.xcodeproj/project.pbxproj` | add/modify | app runner read/mutate env、timeout/cancel/output/error mapping 与 test target wiring |
| `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+ClaudeCommandShimLifecycle.swift` | modify | shim best-effort，取消核心创建门控 |
| `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeLifecycle.swift` | modify | runtime failure 状态与 shared retry path |
| `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalRuntimeCreationPhase.swift`、`TerminalRuntimeCreationState.swift` | add | `@Observable @MainActor` creation state 与独立 phase value |
| `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface.swift` | modify | 持有 creation state；不新增 Combine/`@Published` |
| `Packages/macOS/CmuxTerminal/Tests/CmuxTerminalTests/TerminalSurfaceRestoreSpawnSchedulerTests.swift` | modify | shim 延迟仍创建、failure-once、failure/retry 行为 |
| `Sources/Panels/TerminalPanelView.swift`、`Sources/cmuxApp.swift` | modify | terminal 创建失败 overlay、Retry 与 DEBUG failure-once menu |
| `Resources/Localizable.xcstrings` | modify | English/Japanese terminal failure、Retry 与 debug menu 文案 |

## 设计 / 决策

### 关键决策

- `CommandRunner` 保持现有 `CommandRunning` API；实现改为 `DispatchSourceRead`/fd ownership，不在 `Task.detached` 上执行无限阻塞 `read(2)`。父 Task cancellation 与 deadline 竞争通过现有 one-shot claim 状态只完成一次。
- 所有 Git 调用给出有限 deadline；generation guard 只负责结果一致性，取消负责资源回收，两者不互相替代。
- `GitDiffPanelView` 显式接收 active/visible 状态；store 提供 `start(directory:)`/`stop()` 或等价单一生命周期入口，隐藏时终止 scan 和 poll。
- app `GitWorktreeStore` 与 packaged runner 都通过注入的 `CommandRunning` seam 验证；read-only 命令设置 `GIT_OPTIONAL_LOCKS=0`，mutating 命令不设置该值，二者共享同一 deadline/cancellation contract。
- `claudeCommandShimStateForSurface` 可以启动安装但不得返回“禁止创建”；本次创建使用当下已就绪 shim，否则传 nil。完成回调若 native surface 已存在只缓存结果，不二次创建。
- runtime creation 由独立 `@MainActor @Observable` `TerminalRuntimeCreationState` 持有，phase 最少为 `idle/creating/ready/failed`；`TerminalSurface` 只持有该 child model，不新增 `@Published`。所有 create/retry 成功和 teardown 路径保持状态一致，用户点击 Retry 调用共享 action，不直接操作 C pointer。
- DEBUG failure-once seam 是 CmuxTerminal package 内 `@MainActor` process-global one-shot，只由 debug menu arm，并由下一条新 `TerminalSurface` 的 shared native creation point 原子消费；它不绕过 production failure state/retry path，且消费后后续创建正常。

### 不采用的方案

- 仅把 `Task.detached` priority 调高：仍会阻塞 cooperative worker，不能修复取消和 fd 生命周期。
- 仅缩短 Git 轮询或改为 `--untracked-files=normal`：只能减轻触发，不能终止已卡进程。
- 等 shim 超时后再创建 PTY：仍把辅助集成放在核心路径；直接 fail-open 更小且确定。
- native create 失败后静默自动无限重试：会制造新的资源风暴并继续表现为空白。

## 验证计划

- `swift test --package-path Packages/macOS/CmuxFoundation --filter CommandRunnerTests`，预期：取消、超时、descendant 持 pipe 和大输出均通过。
- `swift test --package-path Packages/macOS/CmuxTerminal --filter TerminalSurfaceRestoreSpawnSchedulerTests`，预期：shim 延迟不阻塞创建，failure-once 进入失败状态且 Retry 使用同一创建路径成功。
- `./scripts/test-unit.sh test -only-testing:cmuxTests/SidebarGitProcessCompositionTests -only-testing:cmuxTests/FileExplorerGitStatusProviderTests -only-testing:cmuxTests/GitWorktreeStoreTests`、`./scripts/lint-pbxproj-test-wiring.sh`、`python3 scripts/normalize-pbxproj.py` 与 `./scripts/check-pbxproj.sh`，预期 app 三个 Git domain tests 实际执行、project normalized；packaged runner focused tests 也通过。
- tagged smoke 使用 `/tmp/cmux-slow-git/git` PATH wrapper 验证 Diff 取消与 terminal 创建；另从 Debug 菜单执行 Fail Next New Terminal Creation 后新建 terminal，触发 shared native create failure，实际观察 localized overlay并点击 Retry，再新建一次确认 flag 已消费。最终以 debug CLI/lsof/sample 证明 wrapper PID 退出、PTY 增加、失败 tab 可恢复；finally unset launchctl PATH 并删除 wrapper。
- 本地化审计：解析 `Resources/Localizable.xcstrings`，确认 terminal/error/retry/debug keys 同时含 English/Japanese，检查触及 Swift 文件无新 bare user-facing English。

## 风险 / 回退

进程 runner 是共享基础设施，回归可能影响其他 CLI 调用；以现有 CommandRunner 全套测试和调用方 focused tests 守门。若 terminal failure overlay 引发 portal 层级问题，可回退 UI 表现但保留显式状态和非阻塞 shim；不得恢复 shim 硬门控。

# Spec：repair-terminal-renderer-recovery

## 意图

保证 terminal renderer 在内存压力回收、portal 隐藏/重挂和 mailbox 满载后可以可靠恢复，不再因 dropped realize 消息停在 `swap_chain.defunct` 并永久空白，同时保留非阻塞 MainActor 和不销毁 PTY/terminal state 的设计。

## 方案摘要

保留 `ghostty_surface_set_renderer_realized` 的非阻塞 `.instant` push，但在 Ghostty renderer 每次真实 drain mailbox 后发出独立 `MAILBOX_DRAINED` instrumentation event。cmux 只在 presentation repair 已 armed 时消费该事件并重试，实现与 frame/visibility 无关的可靠恢复；现有 20 秒 controller 仅保留为兜底，不再是 correctness 条件。

## 范围 / 非目标

### 范围内

- 扩展 Ghostty renderer event contract，增加 mailbox-drained 事件。
- 在 renderer thread drain 完成后无论 surface visible/occluded 都发事件。
- cmux callback 改为消费 mailbox-drained，而不是借用 `UPDATE_FRAME_END`。
- 保持 realize/unrealize 严格交替、state mirror 只在 enqueue 成功时推进。
- 更新 Ghostty fork 文档、submodule commit/push 和 parent pointer。

### 范围外

- 不把 `error.Defunct` 当 PTY death，不重建整个 `ghostty_surface_t`。
- 不改变 memory-pressure 选择哪些隐藏 renderer 的策略和阈值。
- 不增加 app-level display link 或手工 draw loop。
- 不用阻塞 `.forever` push 卡住 MainActor。

## 可观察行为

1. renderer-realize enqueue 因 mailbox 满返回 false 后，presentation phase 保持未完成并 armed repair。
2. renderer thread 下一次 drain mailbox 时，即使 surface occluded/`flags.visible == false`、没有 frame update，也发出 mailbox-drained event。
3. cmux 收到该事件后只重试对应 surface；enqueue 成功后 phase 变为 presented 并恢复 occlusion-visible。
4. surface 已隐藏、关闭或已 presented 时，迟到事件不触碰 native pointer，不产生重复 realize。
5. memory-pressure reclaim 只释放 swapchain/shaders/IOSurface，PTY、scrollback 和 terminal state 保持。
6. 正常 frame instrumentation 语义不变。

## Bug 复现证据

- `ghostty_surface_set_renderer_realized` 当前使用 `.instant`，mailbox 满时允许返回 false。
- repair 只由 `GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_END` 触发；macOS `drawFrame`/render callback 在 `!flags.visible` 时早退，released+occluded renderer 可能永远不产生该事件。
- 现有 package test 必须手工发送 `UPDATE_FRAME_END` 才能恢复，正好暴露 correctness 对 frame 的错误依赖。

## First-Principles Snapshot

- 真实目标：状态消息可以丢，但丢失后的恢复信号必须独立于被该消息关闭的渲染行为。
- 最小机制：一个 mailbox-drained 事件 + 现有 atomic armed gate + 现有 targeted retry。
- 边界 / 非目标：不销毁 terminal，不改变 reclaim 策略，不阻塞 MainActor。
- 当前事实：Defunct 是预期 unrealized 中态；错误是恢复通知依赖不可见 surface 的 frame event。
- 关键未知：mailbox drain 的 external/internal 两条路径都必须发事件且不得递归触发；用 Ghostty 单元测试固定。
- 证据门槛：Ghostty test 证明 hidden drain 发事件；CmuxTerminal test 证明 mailbox failure 后 mailbox-drained 恢复且迟到事件安全；tagged app 反复 reclaim/show 不空白。
- 推荐选择：独立 mailbox acknowledgement；拒绝 `.forever` 阻塞 push。该选择保持当前 MainActor latency invariant。

## 受影响文件 / 模块

| 路径 / 模块 | 预期动作 | 作用 / 链路 |
|---|---|---|
| `ghostty/include/ghostty.h` | modify | 新增 renderer mailbox-drained event ABI |
| `ghostty/src/renderer/instrumentation.zig` | modify | event enum 与 C header 一致 |
| `ghostty/src/renderer/Thread.zig` | modify | drainMailbox 完成后发独立事件并增加测试 |
| `ghostty/src/apprt/embedded.zig`、`ghostty/src/renderer/message.zig` | modify | 更新可靠恢复契约注释 |
| 根 `GhosttyKit.xcframework` symlink 与 dirty-key cache artifact | regenerate (ignored) | 用 pinned Zig 0.15.2 + `ensure-ghosttykit.sh` 以 ReleaseFast 刷新并重指向 SwiftPM 实际读取的 header/archive |
| `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Runtime/TerminalRendererEventCallback.swift` | modify | 只消费 mailbox-drained event |
| `Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/SurfaceCallbacks/GhosttySurfaceCallbackContext.swift` | modify if needed | 保持 atomic armed gate 的 mailbox acknowledgement 语义 |
| `Packages/macOS/CmuxTerminal/Tests/CmuxTerminalTests/TerminalSurfaceRendererPresentationTests.swift` | modify | dropped enqueue/hidden drain/late event 行为 |
| `Packages/macOS/CmuxTerminal/Tests/GhosttyRuntimeTestStubs/*` | modify | 新 event test ABI |
| `Sources/cmuxApp.swift`、`Resources/Localizable.xcstrings` | modify | DEBUG 菜单确定性调用 production memory-pressure reclaim，供 dogfood 使用 |
| `docs/ghostty-fork.md` | modify | fork change 与冲突说明 |
| `ghostty` parent submodule pointer | modify | 指向已推送 `origin/ghostty-main` 的 commit |

## 设计 / 决策

### 关键决策

- 新事件命名 `GHOSTTY_RENDERER_EVENT_MAILBOX_DRAINED`，语义是 renderer thread 完成一轮 mailbox drain；不承诺 frame 已更新或 drawable 可用。
- C/Zig enum raw value 为 4；所有 raw-value-indexed test arrays 必须同步扩为 5 或由 enum count 派生。
- event 从 renderer thread 发出；Swift trampoline 只通过现有 `GhosttySurfaceCallbackContext.rendererMailboxDidDrain()` atomic gate 调度 MainActor repair，未 armed 时为 no-op。
- `ensureRendererPresented` 继续在 push 前 arm、成功后 cancel；状态只随成功 push 推进，维持非幂等交替。
- 当前 checkout 的可写 fork remote 为 `origin`，集成分支为 `ghostty-main`；Ghostty 子模块提交必须先 push 到 `origin/ghostty-main` 并证明可达，再更新 parent pointer。不得向只读 `upstream` 推送或留在 detached HEAD。
- Ghostty 命令固定使用已安装的 `/opt/homebrew/opt/zig@0.15/bin/zig` 0.15.2；ABI 构建通过根目录 `scripts/ensure-ghosttykit.sh` 的 dirty-key cache 流程，不直接假设 submodule build output 会刷新根 symlink。

### 不采用的方案

- 恢复 `.forever`：保证投递但可在 MainActor 等 renderer mailbox，违反输入/界面延迟约束。
- 固定延时重试或更频繁 20 秒轮询：没有 readiness signal，可能忙循环或继续长期空白。
- 在不可见 surface 上强制 draw 一帧：引入 app-level draw loop并破坏 reclaim 目的。
- memory pressure 后重建整个 surface：会丢 PTY 和 terminal state，解决了错误的问题。

## 验证计划

- `cd ghostty && PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" zig build test -Dtest-filter=mailbox` 及完整 `zig build test`，预期 hidden/external mailbox drain event 独立于 frame。
- `PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" CMUX_GHOSTTYKIT_NO_PREBUILT=1 ./scripts/ensure-ghosttykit.sh`，预期根 `GhosttyKit.xcframework` symlink 指向当前 dirty-key ReleaseFast artifact，根 header 含新 ABI。
- `swift test --package-path Packages/macOS/CmuxTerminal --filter TerminalSurfaceRendererPresentationTests`，预期 dropped realize 经 mailbox-drained 恢复，非 update-frame event，迟到事件安全。
- `./scripts/reload.sh --tag dev --launch`，从 Debug 菜单触发 production `reclaimForSystemMemoryPressure`，对同一 terminal 连续 5 轮隐藏/reclaim/显示并对比 PTY、shell PID 与 scrollback marker；预期身份不变、renderer 恢复、无持续 `error.Defunct` 空白。
- `cd ghostty && git merge-base --is-ancestor HEAD origin/ghostty-main`，预期成功后才允许 parent pointer 收口。

## 风险 / 回退

这是 C ABI、Swift callback 与 renderer-thread 时序变更。若 event 频率过高，atomic gate 应使未 armed 路径为常数 no-op；若仍有成本，可在 Ghostty thread 内仅当本轮实际 pop 过消息时 emit，但不能重新依赖 frame。回退时可撤销新 event并恢复旧 callback，不能以 `.forever` 阻塞作为临时修复。

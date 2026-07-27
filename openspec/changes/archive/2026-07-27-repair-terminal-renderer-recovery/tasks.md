# Tasks：repair-terminal-renderer-recovery

## 1. Ghostty mailbox acknowledgement

- [x] 1.1 为 renderer mailbox drain 增加独立 event contract
  - Allowed Files: `ghostty/include/ghostty.h`, `ghostty/src/renderer/instrumentation.zig`, `ghostty/src/renderer/Thread.zig`, `ghostty/src/apprt/embedded.zig`, `ghostty/src/renderer/message.zig`, `ghostty/src/renderer/*test*`
  - Blockers: 无；preflight 必须满足 `/opt/homebrew/opt/zig@0.15/bin/zig version` 输出 `0.15.2`，后续 Ghostty 命令一律用该固定 PATH，不使用系统 Zig 0.16。
  - 验收：新增 C/Zig enum `MAILBOX_DRAINED = 4`；所有按 event raw value 索引的 test storage（当前 `Thread.zig` 的 `EventCounts.values`）扩为 5 或从 enum count 派生；每轮实际 mailbox drain 后发事件且不依赖 visible/frame update；正常 frame events 不变；hidden/external drain 行为有 Zig test。red baseline 是 enum/count 已扩、assert 已写但 emit 尚未接线时 test 失败，避免越界伪红。
  - 验证：`cd ghostty && PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" zig build test -Dtest-filter=mailbox`，随后 `cd ghostty && PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" zig build test`；预期 mailbox focused test 与完整 Ghostty test step 均通过。

- [x] 1.2 重建并重指向 ReleaseFast GhosttyKit，使新 C ABI 进入 SwiftPM binary target
  - Allowed Files: `GhosttyKit.xcframework` symlink 与 `~/.cache/cmux/ghosttykit/*/GhosttyKit.xcframework`（generated/ignored artifacts）
  - Blockers: 1.1
  - 验收：使用 dirty-submodule cache key 构建 universal ReleaseFast GhosttyKit，根目录 `GhosttyKit.xcframework` symlink 被 `ensure-ghosttykit.sh` 重指向该新 cache artifact；根路径的 macOS header 包含 `GHOSTTY_RENDERER_EVENT_MAILBOX_DRAINED`；不提交生成二进制。
  - 验证：`PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" CMUX_GHOSTTYKIT_NO_PREBUILT=1 ./scripts/ensure-ghosttykit.sh`；然后 `readlink GhosttyKit.xcframework` 指向当前 dirty key，并用文件读取/内容搜索确认 `GhosttyKit.xcframework/*/Headers/ghostty.h` 含 `GHOSTTY_RENDERER_EVENT_MAILBOX_DRAINED`。预期 SwiftPM 实际读取的新 header/archive 已刷新。

## 2. cmux targeted repair

- [x] 2.1 将 presentation repair 从 frame-end 切到 mailbox-drained，并增加确定性 DEBUG reclaim 入口
  - Allowed Files: `Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Runtime/TerminalRendererEventCallback.swift`, `Packages/macOS/CmuxTerminalCore/Sources/CmuxTerminalCore/SurfaceCallbacks/GhosttySurfaceCallbackContext.swift`, `Packages/macOS/CmuxTerminal/Tests/CmuxTerminalTests/TerminalSurfaceRendererPresentationTests.swift`, `Packages/macOS/CmuxTerminal/Tests/GhosttyRuntimeTestStubs/GhosttyRuntimeTestStubs.c`, `Packages/macOS/CmuxTerminal/Tests/GhosttyRuntimeTestStubs/include/GhosttyRuntimeTestStubs.h`, `Sources/cmuxApp.swift`, `Resources/Localizable.xcstrings`
  - Blockers: 1.2
  - 验收：failed `.instant` realize 在 mailbox-drained event 后重试；UPDATE_FRAME_END 不再是修复信号；hidden/closed/already-presented 的迟到 event 为 no-op；DEBUG 菜单提供本地化的“Reclaim Hidden Terminal Renderers”动作，直接调用 production `RendererRealizationController.reclaimForSystemMemoryPressure`，不复制 reclaim/repair 逻辑。
  - 验证：`swift test --package-path Packages/macOS/CmuxTerminal --filter TerminalSurfaceRendererPresentationTests`，预期 dropped/late event tests 全部通过；本地化 JSON 可解析且 debug key 含 en/ja。

## 3. Fork 与集成收口

- [x] 3.1 更新 Ghostty fork 文档、推送 submodule commit 并更新 parent pointer
  - Allowed Files: `ghostty`, `docs/ghostty-fork.md`
  - Blockers: 1.2, 2.1
  - 验收：Ghostty 变更已提交并进入当前可写 fork 的 `origin/ghostty-main`；fork 文档记录 event ABI/冲突点；parent pointer 指向可达 commit。
  - 验证：`cd ghostty && git merge-base --is-ancestor HEAD origin/ghostty-main` 与 remote ref 检查，预期成功；不得留下 detached/unpushed commit。

- [x] 3.2 Dogfood reclaim/show 恢复
  - Allowed Files: `openspec/changes/repair-terminal-renderer-recovery/tasks.md`, `openspec/changes/repair-terminal-renderer-recovery/evidence.md`
  - Blockers: 3.1
  - 验收：tagged app 中先在 terminal 写入唯一 PTY/scrollback marker，再把该 terminal 隐藏；从 Debug 菜单执行 task 2.1 的 production-backed reclaim 动作，日志确认 hidden renderer 已 unrealize；重新显示同一 terminal 后 marker 与 shell PID 不变、renderer 恢复，连续 5 轮无永久空白。
  - 验证：`./scripts/reload.sh --tag dev --launch`，通过 `agent-cu` 操作 Debug → Reclaim Hidden Terminal Renderers 与 terminal hide/show，并用 `CMUX_TAG=dev scripts/cmux-debug-cli.sh debug-terminals` 记录同一 surface/PTY identity；预期每轮 mailbox repair 完成且无持续空白。

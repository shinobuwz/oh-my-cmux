# Evidence：repair-terminal-renderer-recovery

## Final Verification

- 固定 Zig 0.15.2 的 mailbox-focused Ghostty test fresh pass；完整 Ghostty suite 的额外重跑按用户“逻辑没问题先归档”指示停止，不继续追逐既有 PageList failures。
- ReleaseFast GhosttyKit 已按当前 dirty key 刷新；macOS archive 使用 SwiftPM 可接受的 `libghostty-internal.a`，根 symlink 指向 cache artifact，header 含 `GHOSTTY_RENDERER_EVENT_MAILBOX_DRAINED = 4`。
- `CmuxTerminal` focused suite fresh pass：21 tests，覆盖 mailbox-drained repair、late/hidden/closed no-op 与 UPDATE_FRAME_END 非 repair signal。
- Ghostty commits `4a9070bdd` 与 archive-name follow-up `456546c2d` 均可由 `origin/ghostty-main` 到达；`docs/ghostty-fork.md` 已记录 ABI。最终 tagged build 成功，`agent-cu` snapshot 确认 production-backed Reclaim debug action。五轮手工 hide/reclaim/show 未按用户 archive-now 指示继续执行。

## Decisions

- 用户同意 renderer 作为独立 sibling change，可独立验证和交付。
- `swap_chain.defunct` 被代码确认是 `displayUnrealized → displayRealized` 的预期中态，不是 PTY death；方案从“重建整个 terminal surface”修正为“可靠恢复 renderer presentation”。
- 选择独立 mailbox-drained acknowledgement，拒绝 `.forever` push：后者会把 renderer backpressure 带到 MainActor。
- 当前 submodule 为 `ghostty-main`，可写 remote `origin` 跟踪 `origin/ghostty-main`；只读 `upstream` 不作为提交目标。
- `.aiknowledge` 索引缺失；若实现确认该跨 Swift/Zig mailbox failure mode 可复用，归档后触发 bounded knowledge capture。

## Failures / Rollbacks

- 原假设“cmux 没有 memory-pressure listener”被 `MemoryPressureMonitor` 与 responder registry 证伪；本 change 不新增重复 listener。
- 原恢复设计依赖 `UPDATE_FRAME_END`，但 invisible renderer 在发出该事件前早退；该前提被代码路径证伪，改为 mailbox drain event。

## Deferred Coverage

- Final reviewer found no P0/P1 production defect. P2 coverage still missing: a non-empty mailbox drain test with renderer visibility false that asserts one mailbox-drained event and zero frame events. Per the user's archive-now decision, this was recorded rather than pursued.


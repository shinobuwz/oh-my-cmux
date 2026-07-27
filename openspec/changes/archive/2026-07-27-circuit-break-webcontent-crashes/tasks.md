# Tasks：circuit-break-webcontent-crashes

## 1. Per-panel circuit 状态机

- [x] 1.1 在共享 termination chokepoint 实现两次连续失败预算与 commit reset
  - Allowed Files: `Sources/Panels/BrowserPanel.swift`, `cmuxTests/BrowserWebContentProcessTests.swift`, `cmuxTests/BrowserConfigTests.swift`
  - Blockers: 无
  - 验收：计数与熔断必须位于 production delegate 和 `debugSimulateWebContentProcessTermination()` 共用的 `replaceWebViewAfterContentProcessTermination`；第一次 termination 走自动 replacement/navigation 且不显示 overlay；第二次在成功 commit 前 termination 时只保存 restore URL、打开 circuit、保持当前 instance identity，不调用 generic replacement；current non-blank main-frame commit 清零；empty tab/stale/circuit-open callback no-op；现有单次手工恢复 assertions 改为新语义。
  - 验证：`./scripts/test-unit.sh test -only-testing:cmuxTests/BrowserWebContentProcessTests -only-testing:cmuxTests/BrowserConfigTests`，预期：新增 red-capable state transitions 全部通过。

## 2. Fail-fast UI 与共享恢复入口

- [x] 2.1 展示本地化 circuit 错误，将所有 WebView reactivation 接入单一 invariant，并暴露 DEBUG app seam
  - Allowed Files: `Sources/Panels/BrowserPanel.swift`, `Sources/Panels/BrowserPanelView.swift`, `Sources/Panels/BrowserDiscardRestoreHeal.swift`, `Sources/cmuxApp.swift`, `Resources/Localizable.xcstrings`, `cmuxTests/BrowserWebContentProcessTests.swift`, `cmuxTests/BrowserDiscardRestoreHealPredicateTests.swift`
  - Blockers: 1.1
  - 验收：circuit 打开时不挂载 WebView，显示 title/message/diagnostics/Retry；Retry 与 toolbar reload 调用同一 recovery action，原子式清零预算/关闭 circuit 后才创建新实例并恢复 URL；所有 `shouldRenderWebView = true` 路径（普通/pending navigation、reactivation、discard restore、blank-shell heal）在 circuit-open 时拒绝，只有明确 profile/context/discard reset 或 Retry 可先 reset；对应路径均有行为测试。DEBUG 菜单增加本地化动作，直接调用 focused panel 的 production-shared `debugSimulateWebContentProcessTermination()`，不复制状态机。
  - 验证：`./scripts/test-unit.sh test -only-testing:cmuxTests/BrowserWebContentProcessTests -only-testing:cmuxTests/BrowserDiscardRestoreHealPredicateTests`，预期 Retry、reactivation、discard restore、pending navigation 与 predicate tests 全部通过；`Resources/Localizable.xcstrings` 可解析且 keys 有 en/ja。

## 3. 集成验收

- [x] 3.1 验证连续 termination 有界且人工恢复可用
  - Allowed Files: `openspec/changes/circuit-break-webcontent-crashes/tasks.md`, `openspec/changes/circuit-break-webcontent-crashes/evidence.md`
  - Blockers: 2.1
  - 验收：tagged app 中打开非空 browser panel，使用 task 2.1 的 Debug 菜单动作对同一 focused panel 连续触发两次 production-shared termination；第一次自动 replacement，第二次后 instance 不再替换、WebContent 子进程数停止增长、error overlay 可见；再次触发为 no-op；Retry 后新实例成功提交，terminal 创建仍可用。
  - 验证：`./scripts/reload.sh --tag dev --launch`，通过 `agent-cu` 操作 Debug → Simulate Focused Browser WebContent Termination，并在每次动作前后记录 `ps`/unified log 的 WebContent PID 与 panel debug identity；预期第二次熔断、第三次不 replacement、Retry 成功。

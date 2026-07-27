# Evidence：circuit-break-webcontent-crashes

## Final Verification

- 11 个 targeted `BrowserWebContentProcessTests` 此前通过，覆盖 first replacement、second circuit-open、stale/empty/circuit-open no-op、commit reset、reactivation/discard invariants 与 Retry。
- 修复 manual Retry 未清零预算的 review finding；`reloadRecoversTerminatedWebView` 验证 Retry 后第一次 pre-commit termination 自动恢复、第二次才重新熔断。三项 review findings 复审 clean。
- Fresh app focused test attempt was blocked while compiling unrelated `TabManagerUnitTests` stale group APIs (`childWorkspaceIds` / `groupId`); production `./scripts/reload.sh --tag dev` succeeded. Per the user's archive-now decision, two-termination UI dogfood was not pursued further.
- `agent-cu` confirmed the live tagged window and focused-browser termination DEBUG action. All browser error/Retry keys parse and contain English/Japanese translations.

## Decisions

- 用户确认 circuit 为 per-panel；连续两次 failure 后停止自动重建，由人工 Retry 恢复，成功 main-frame commit 重置预算。
- “两次失败后”按第二次 termination 即熔断解释：只允许第一次自动 replacement，不采用第三次才熔断的 Markdown 既有 off-by-one 语义。

## Failures / Rollbacks

- 无。

## Deferred Coverage

- Final reviewer found no P0/P1 production defect. P2 coverage still missing: negative commit-reset tests for `about:blank` and stale replaced-WebView commits. Per the user's archive-now decision, these were recorded rather than pursued.


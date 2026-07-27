# Spec：circuit-break-webcontent-crashes

## 意图

阻止单个 browser panel 的 WebContent 进程在持续启动失败（包括 sandbox/entitlement error 159）时无限创建 `WKWebView`/WebContent 子进程。短暂崩溃仍自动恢复；连续失败达到预算后必须 fail-fast，停止挂载 WebKit，并给用户明确、可重试的错误状态。

## 方案摘要

在 `BrowserPanel` 现有唯一 WebContent termination 入口加入 per-panel 连续失败计数器和 open/closed circuit 状态。第一次 termination 自动替换并恢复；在尚未成功 main-frame commit 前再次 termination 时打开 circuit，不再创建 `WKWebView`。成功 commit 清零预算；用户点击 Retry 时显式关闭 circuit、创建一个新 `WKWebView` 并导航到保留 URL。

## 范围 / 非目标

### 范围内

- 为主 browser panel 增加连续 WebContent termination 预算、熔断状态和状态转换。
- 首次失败自动恢复；连续第二次失败停止 WebKit 创建和挂载。
- 成功的非 `about:blank` main-frame commit 重置连续失败计数。
- 熔断时显示本地化错误、诊断信息和 Retry；toolbar reload 走同一恢复 action。
- workspace context reset、profile switch、discard/restore 清理 circuit 状态。

### 范围外

- 不改变 popup browser 的“WebContent 终止即关闭 popup”行为。
- 不把 automation timeout、普通 navigation error 或 Markdown renderer 纳入该预算。
- 不尝试修复缺失 entitlement；本 change 只保证确定失败时有界退避。
- 不持久化 circuit 状态到 session snapshot。

## 可观察行为

1. 可恢复页面第一次 WebContent termination 后自动创建一次新 `WKWebView` 并导航，不显示错误 overlay。
2. 若新实例在成功 main-frame commit 前再次 termination，panel 打开 circuit：不再创建新 `WKWebView`，`shouldRenderWebView == false`，显示错误和 Retry。
3. circuit 打开后重复 termination callback 为 no-op，不增加进程或替换次数。
4. 任一恢复实例完成非空 main-frame commit 后，连续失败计数归零；之后的 termination 又获得一次自动恢复机会。
5. 用户点击 Retry 或 toolbar reload 时，计数归零、circuit 关闭、创建一个全新实例并恢复最后有效 URL。
6. 空白新 tab 的 termination 不触发自动创建或 circuit。
7. profile/context/discard restore 切换不继承旧 panel 的 circuit 状态。

## Bug 复现证据

- 运行日志中多个 WebContent PID 重复 spawn，随后以 sandbox restriction/error 159 失败；当前 `webViewWebContentProcessDidTerminate` 每次都直接进入 `replaceWebViewAfterContentProcessTermination`。
- 当前实现没有连续失败预算；每次 callback 都能构造新的 `WKWebView`，因此缺少 fail-fast 边界。
- `cmuxTests/BrowserWebContentProcessTests.swift` 当前只覆盖单次替换和手工 Reload，尚未约束连续失败次数。

## First-Principles Snapshot

- 真实目标：一个确定不可用的 WebKit 环境不能制造无限子进程风暴，browser panel 失败也不能拖垮 terminal 核心功能。
- 最小机制：每 panel 一个整数计数、一个 circuit flag、一个成功 commit reset 和一个人工 Retry action。
- 边界 / 非目标：不探测具体 entitlement，不做全 app circuit，不改变 popup/Markdown。
- 当前事实：termination callback、实例替换、保留 URL 和 recovery overlay 已有单一路径，可原位扩展。
- 关键未知：无；用户已确认 per-panel、连续两次失败后熔断、成功 main-frame commit 重置。
- 证据门槛：确定性 state-machine tests 证明第二次连续 failure 不替换实例，commit reset 与 Retry 生效；tagged app 验证 overlay。
- 推荐选择：第一次失败自动恢复，第二次连续失败直接熔断；比“允许两次替换、第三次才熔断”更符合“连续 2 次失败后熔断”的用户决定。

## 受影响文件 / 模块

| 路径 / 模块 | 预期动作 | 作用 / 链路 |
|---|---|---|
| `Sources/Panels/BrowserPanel.swift` | modify | termination budget、commit reset、Retry 与 context reset 的唯一状态机 |
| `Sources/Panels/BrowserPanelView.swift` | modify | circuit-open 错误 overlay 与共享 Retry action |
| `Sources/Panels/BrowserDiscardRestoreHeal.swift` | modify | circuit/recovery pending 时禁止 blank-shell 自动 heal |
| `Sources/cmuxApp.swift` | modify | DEBUG 菜单对 focused panel 调用 production-shared termination chokepoint |
| `Resources/Localizable.xcstrings` | modify | English/Japanese title、message、diagnostics、Retry |
| `cmuxTests/BrowserWebContentProcessTests.swift` | modify | 连续失败、commit reset、Retry、empty-tab 行为 |
| `cmuxTests/BrowserDiscardRestoreHealPredicateTests.swift` | modify | pending/circuit predicate 行为 |
| `cmuxTests/BrowserConfigTests.swift` | modify if needed | 既有单次 termination identity assertions 对齐新语义 |

## 设计 / 决策

### 关键决策

- 状态只属于 `BrowserPanel`，automation timeout 替换不消耗 termination budget；budget 的唯一入口是 production delegate 与 test/debug seam 共同调用的 `replaceWebViewAfterContentProcessTermination`，不能只放在 delegate closure。
- budget 为 2 次连续 termination：第 1 次 increment 后走无 overlay 的自动替换与导航；第 2 次 increment 后只保存 restore URL、立即 open circuit，不构造新实例。
- reset signal 使用现有 navigation delegate 的 main-frame `didCommit`，且沿用 current-instance 与非 `about:blank` guard。
- circuit 打开时保留 restore URL，但令 `shouldRenderWebView = false`，从 SwiftUI 树移除 dead `WKWebView`；所有普通/pending navigation、reactivation、discard restore 与 blank-shell heal 的 mount 路径都必须遵守该 gate，不能自行写回 true。
- Retry 与 toolbar reload 调用同一 action：先原子式清理 circuit/attempts，再经现有统一 replacement path 创建和导航；明确的 profile/context/discard reset 也必须先重置状态，失败后仍由同一 termination budget 保护。
- 新文案与 DEBUG 菜单使用独立 localized keys，不复用语义不同的 `browser.error.reload`。

### 不采用的方案

- 全 app circuit：一个站点或 profile 的故障会误伤其他健康 panel。
- 固定 sleep/backoff 后无限重试：仍会无限孵化，只是速度更慢。
- 通过错误码 159 字符串识别 entitlement：WebKit termination callback 不提供稳定错误分类，且会漏掉同类确定失败。
- 第二次仍自动替换、第三次才熔断：与用户确认的“两次失败后”不一致。

## 验证计划

- `./scripts/test-unit.sh test -only-testing:cmuxTests/BrowserWebContentProcessTests -only-testing:cmuxTests/BrowserDiscardRestoreHealPredicateTests`，预期：首次自动恢复、第二次熔断、commit reset、Retry，以及普通/pending navigation、reactivation、discard restore、blank-shell heal gate 全通过。
- `./scripts/reload.sh --tag dev --launch`，从 Debug 菜单对同一 focused panel 连续调用 production-shared termination seam 三次；预期第一次自动替换、第二次熔断、第三次 no-op，显示 error + Retry，Retry 后恢复。
- 本地化审计：解析 `Resources/Localizable.xcstrings` 并核对新增 `browser.error.webcontent.*` 与 debug key 同时含 `en`/`ja`；触及 Swift 文件无新增 bare user-facing English。

## 风险 / 回退

错误的 reset 时机会把真实 crash loop 当作健康。测试必须区分 stale/`about:blank` commit 与 current main-frame commit。若 UI overlay 回归，可回退呈现层但保留 circuit 状态机和 `shouldRenderWebView` gate；不得恢复无限 replacement。

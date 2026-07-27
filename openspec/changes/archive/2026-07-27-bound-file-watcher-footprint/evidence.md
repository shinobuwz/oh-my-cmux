# Evidence：bound-file-watcher-footprint

## Final Verification

- Fresh package verification passed 20 selected `CmuxSidebarGit` tests across registry sharing/lifecycle and probe-cache behavior; fresh `CmuxFoundation` selection passed 26 tests including atomic counter and real watcher balance/churn.
- Review found and fixed two lifecycle races: retired pump不得 finish successor entry；service 在 MainActor apply 前销毁时直接 await release orphan subscription。复审 clean。
- Production `./scripts/reload.sh --tag dev` succeeded. The unrelated shared app-test compilation blocker is recorded in the sibling browser/Git evidence; per the user's archive-now decision, the three-window runtime metrics dogfood was not pursued further.
- `agent-cu` snapshot confirmed the production registry metrics DEBUG action; active-stream counter 与 registry snapshot 均为 instance-scoped/async ownership path，不使用 singleton。新增 debug key 已审计，English/Japanese 均有翻译。

## Decisions

- 原“840 个 DIR fd 疑似泄漏”前提未被源码证明：底层 stop/deinit 路径存在。change 改为先建立 active-stream ownership 证据，再修复已证明的跨 window exact-set 重复。
- 拒绝 ancestor coalescing 和 FileExplorer/Sidebar watcher 合并；两者 lifecycle 与 consumer 语义不同。
- linked-worktree partial overlap 本轮不合并；只复用现有 normalized full watched-path set，保持 submodule correctness。

## Failures / Rollbacks

- 回滚“按祖先目录合并 watcher”的初始方向：它不能解决 linked worktree overlap，且会把不同 visibility lifecycle 错误耦合。

## Deferred Coverage

- Final reviewer found no P0/P1 production defect. P2 coverage still missing: installed-listener release through service `stopAll`/deinit and recorded three-window watcher metrics. Per the user's archive-now decision, these were recorded rather than pursued.

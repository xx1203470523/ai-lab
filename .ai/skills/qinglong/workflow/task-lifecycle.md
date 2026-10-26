# 任务生命周期

## 新建任务

1. 先查重：`task.list` 或者 `state.diff`，确认平台上没有同名同调度的任务。青龙的唯一索引在 `name + command + schedule`，撞了会 HTTP 500。
2. 写期望态 `tasks/<key>.json`。`key` 必须与文件名一致；`schedule` 必须是 6 段。
3. 跑 `task.create -Key <key>` → `exit 2`，拿到 `planDigest`。
4. 把 `planned` 讲给用户：任务名、脚本、调度、启用状态。等明确同意。
5. `task.create -Key <key> -ConfirmPlan <digest>` → `exit 0` 且 `verified=true` 才算完成。
6. 报给用户：平台 id、最终名字、启停状态。

## 改任务

改 `tasks/<key>.json` 里要变的字段，然后 `task.update -Key <key>`：

- 若当前状态与期望一致 → 直接 `action=no-op` 返回，不需要确认。
- 有差异 → `exit 2` 出计划，`planned.diff` 是逐字段的「现状 → 期望」。念给用户听，确认后带 `-ConfirmPlan` 重跑。
- `task.update` 会一并处理启停（期望态里的 `enabled`）和 `qls.*` 标签。

调度变化、脚本变化、启停变化都走这一条路，不要分别调 `task.enable` / `task.disable` 去凑。

## 单独启停

只想改启停、不动其他字段时用 `task.enable` / `task.disable`。已经是目标状态时返回 `action=no-op`，不会重复调用平台。

## 立即执行

`task.run` 是 level 2，永远需要确认，且**与部署完全解耦**：

- 用户说「部署到青龙」→ 只建/改任务，**不执行**。
- 用户说「现在跑一下」→ 才 `task.run`。
- 跑完返回 `verified=false`，因为触发是异步的。**必须**接着用 `log.list` / `log.tail` 查证实际结果，再向用户报告。不要把「已提交」说成「已成功」。

## 删除

1. `task.delete -Key <key>` → `exit 2` 出计划（含任务 id、名字、命令、调度）。
2. 把计划念给用户确认。
3. 带 `-ConfirmPlan` 重跑 → 回读确认平台上已不存在。

约束：

- 只支持单个 key，**不提供批量删除**。
- 未标记 `qls.managed-by=ai` 的任务默认拒绝删除。用户明确要求时才加 `-Force`，并在报告里说明这是非纳管对象。
- 删除脚本用 `script.delete`。若还有任务引用该脚本，默认拒绝；要删得先改掉引用方的 `command`。

## 批量收敛

`state.reconcile` 把 `tasks/` 下所有期望态一次对齐，**只做 create / update，绝不删除**。

- 无差异时 `action=no-op` 直接返回。
- 有差异时出计划（逐条的 key 与 actualDigest），确认后执行。
- 执行时逐条比对 `actualDigest`：计划后被别人改过的条目**跳过并告警**，不做整体回滚。报告里必须列出被跳过的条目。

## 失败处理

- 回读校验失败（`errors` 含「回读校验失败」）：说明平台没按期望落地。停下来把现状读给用户看，不要反复重试。
- `exit 4`：计划后状态变了。重新出计划，让用户重新确认。
- 部分跳过：逐条报告成了哪些、跳了哪些，不得静默重试掩盖。

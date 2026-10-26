---
name: qinglong
description: 青龙面板 QingLong 任务与脚本编排。管理定时任务 cron 的创建、编辑、启停、删除、立即执行，部署脚本，对照期望态与平台实际状态并诊断调度异常。触发词：青龙、qinglong、定时任务、调度、cron、计划任务、任务部署、脚本推送、任务诊断。
---

# QingLong

@rules/qinglong.rules.md
@rules/schedule.rules.md

## Trigger

当提词涉及青龙面板上的定时任务运维时调用：

- 「建个定时任务」「把这个任务部署到青龙」「改一下这个任务的执行时间」
- 「停掉某个任务」「删掉这个任务」「现在跑一下这个任务」
- 「推一个脚本上去」「更新线上脚本」
- 「任务为什么没跑」「调度有没有问题」「盘点一下青龙上的任务」

以下提词**不**走本技能：WMS 业务数据查询走 `dbsql`；代码分支与提交走 `git`。

## 意图映射

业务动词在 `scripts/ql.ps1` 里，不要拼青龙原始 API 路径。

| 用户意图 | 动词 | 级别 |
|---|---|---|
| 看有哪些任务 / 某个任务详情 | `task.list`、`task.get` | 0 |
| 看脚本树 / 脚本内容 | `script.list`、`script.get` | 0 |
| 看任务日志 | `log.list`、`log.tail` | 0 |
| 期望态与平台差异 / 孤儿 / 全面体检 | `state.diff`、`state.orphans`、`diagnose` | 0 |
| 新建任务 / 改任务 / 启用 / 停用 | `task.create`、`task.update`、`task.enable`、`task.disable` | 1 |
| 纳管平台上已有的任务（「接管」「纳入管理」） | `task.adopt` | 1 |
| 新建脚本 / 覆盖脚本 | `script.new`、`script.put` | 1 |
| 现在跑一下 | `task.run` | 2 |
| 删除任务 / 删除脚本 / 批量收敛 | `task.delete`、`script.delete`、`state.reconcile` | 2 |

其他动作直接读 `rules/`、`workflow/`、`reference/` 下的对应文件。

## 脚本入口

```powershell
$ql = "$env:USERPROFILE\.claude\skills\qinglong\scripts\ql.ps1"
& powershell -NoProfile -ExecutionPolicy Bypass -File $ql -Verb <动词> [-Key <k>] [-Id <n>] [-ConfirmPlan <digest>] [-Force]
```

所有动词输出**同一个 JSON 信封**：`verb / level / ok / status / planned / actual / diff / result / verified / warnings / errors`。只解析这个结构，不要靠正则抓人读文本。

**向 `tasks/<key>.json` 声明期望态，再让脚本对齐平台**——不要直接调平台写接口。期望态文件字段：`key`（必须与文件名一致）、`name`、`command`、`schedule`、`enabled`、可选 `labels`、`taskBefore`、`taskAfter`。

平台上已经存在、但没打过 `qls.*` 标签的任务，`task.update` 认不出它（只按 `qls.key` 找），直接 `task.create` 又会因 `name+command+schedule` 唯一索引而撞车或留下重复任务。这种情况先写 `tasks/<key>.json`（`name`、`command` 与平台现有值逐字一致），再 `task.adopt -Key <k> -Id <n>` 把它收编——纳管与对齐到位是同一步。

## 确认与退出码

读操作直接执行。写操作先出计划、拿用户确认、再执行：

1. 直接跑动词 → `exit 2`，`status=awaiting-confirmation`，`planned` 是计划，`planDigest` 是摘要。
2. **把 `planned` 用中文讲给用户听**，等用户明确同意。
3. 带 `-ConfirmPlan <planDigest>` 重跑 → 才真正落地。

| exit | status | 含义 |
|---|---|---|
| 0 | `ok` | 完成 |
| 1 | `failed` | 硬失败，读 `errors` |
| 2 | `awaiting-confirmation` | 计划已出，等确认 |
| 4 | `plan-drift` | 摘要不符或计划后状态变了，**重新出计划**，不要硬试 |

「部署任务」只建任务、不运行。**只有用户明确说「现在跑一下」才调 `task.run`。**

## 写后验证

写动词返回 `verified=true` 才算成功——脚本会回读平台、逐字段比对，不符就报 `failed`。不要只看 `exit 0`：平台对某些操作（如删除脚本）对不存在的对象也回 200，回读是唯一的证据。

## 何时停止并报告

- `exit 4` 连续两次：说明有人同时在改，停下来问用户。
- `errors` 里出现「已跳过」：部分成功，逐条报告哪些成了哪些没成，不要重试掩盖。
- 需要**批量**删除或停用：本技能不提供，停下来让用户逐条确认。
- 需要动 `state.reconcile` 之外的平台对象（应用、环境变量、通知渠道）：不在本技能范围，报告并停止。

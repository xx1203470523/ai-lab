# QingLong 规则

## 入口

- 禁止直接拼青龙原始 API 路径，一律走 `scripts/ql.ps1` 的业务动词。
- 禁止用 `Invoke-RestMethod`、`curl` 等绕过技能脚本直接写平台。
- 必须把期望态写在 `tasks/<key>.json`，由脚本对齐平台。

## 确认

- 禁止在用户未明确同意时执行 level 1 / level 2 动词。
- 禁止猜测、复用或跨计划传递 `-ConfirmPlan` 的摘要值。
- 必须把 `exit 2` 的 `planned` 用中文讲给用户后再等确认。
- `exit 4` 必须重新出计划，不得重试同一摘要。
- 「部署任务」禁止顺带执行任务。
- 只有用户明确要求才可调用 `task.run`。

## 写与验证

- 必须用回读后的 `verified=true` 判定写成功，不得只看响应码或 `exit 0`。
- 禁止在 `verified=false` 时向用户报告「已完成」。
- 出现「已跳过」时必须逐条报告未完成项，不得静默重试。
- 禁止执行批量删除或批量停用。
- 禁止删除未标记 `qls.managed-by=ai` 的任务，除非用户明确要求并加 `-Force`。
- 禁止对未纳管任务执行 `task.update`。
- 纳管（`task.adopt`）必须先写 `tasks/<key>.json`，且声明的 `name`、`command` 必须与平台任务逐字一致；禁止为了凑 id 改动声明。
- 禁止对已被纳管的任务执行 `task.adopt`，也禁止纳管带非 `qls.*` 标签的任务。

## 凭据

- 禁止在输出、日志、命令行参数、异常消息中打印 `QL_CLIENT_SECRET`。
- 禁止把凭据写到 `.env` 之外的位置。
- 禁止在 `state/` 之外缓存 token。

## 范围

- 禁止改动青龙的应用、环境变量、通知渠道、订阅。
- 禁止改动 `tasks/` 与 `selftest/` 之外的文件来影响期望态。

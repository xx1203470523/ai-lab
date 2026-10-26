---
name: ai-observer-view
description: "查看与分析 ~/.claude/ai-observer 采集的技能调用记录：调用次数、窗口耗时、技能版本前后对比、改动文件与执行命令。触发关键词：观察器、observer、ai-observer、技能使用情况、技能调用统计、技能对比、技能调整前后、observer 报告、/ai-observer-view。仅在用户要查看或分析观察器记录时使用；不用于修改观察器本身。"
---

# AI Observer 查看器

数据由 `~/.claude/ai-observer` 的 hooks 采集，本技能只读聚合，不写任何文件。

## 核心规则

- 禁止手写 PowerShell 去逐个解析 `logs/skills/*/*.jsonl`；必须走 `./scripts/report.ps1`。
- 禁止修改 `~/.claude/ai-observer/` 下的任何文件；要改采集行为时，改为编辑 `config.json` 的 `capture` 开关并说明影响。
- 报告任何耗时结论前必须确认该记录 `complete != false`，`complete=false` 的窗口时长不可信。
- 报告结论前必须检查样本量；同一版本少于 3 次调用时必须声明样本不足，不得据此断言技能变好或变差。
- 输出命令内容时提醒用户命令正文可能含敏感字符串。

## 路由

统一入口，全部参数可组合：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/skills/ai-observer-view/scripts/report.ps1 -Mode <模式> [-Skill <名>] [-Since <日期>] [-Until <日期>] [-Project <名>] [-Top <N>]
```

| 用户意图 | Mode | 说明 |
|---|---|---|
| 技能用了多少次 / 多久 / 稳定吗 | `summary`（默认） | 每技能：调用数、用户/模型占比、闭合数、均值/中位/P95 窗口、改文件、命令、掉线数 |
| 改了技能之后有没有变好 | `versions` | 按 `skillHash` 分组，并输出同一技能相邻两版的对比 |
| 看某几次具体调用 | `detail` | 按结束时间倒序的调用明细 |
| 都改了哪些文件 / 跑了哪些命令 | `content` | 文件路径频次、命令前缀与完整命令频次 |

## 语义（报告数字容易被误读的地方）

- **窗口时长 ≠ 技能独占耗时**。口径是"技能被调用到本回合结束"，口径为 `end = min(下一个技能调用, 下一条真实用户输入, 回合结束)`。
- **`skillHash` 自 2026-09-17 起写入**，是技能目录（含 rules/workflow/reference）的内容摘要，前 12 位。此前记录归入 `(未记录版本)`，因此版本对比对旧数据不可用。
- **`FilePaths` / `Commands` 自 2026-09-17 起采集**（由 `config.json` 的 `capture.storeFilePaths` / `capture.storeCommandText` 控制）。此前的记录里没有内容字段，`content` 模式会明确提示而不是显示空表。
- **`skill_end_revised`** 是对同一窗口的补正，指标以补正为准，`durationMs` 取原始记录。它不产生新调用；关联不上的会作为"孤立补正"单独报出。
- **掉线（`complete=false`）** 指会话中断导致窗口未正常收尾，这类时长不得参与结论。
- **手敲 `/skill` 与模型自主调用**都记录，槽位在 `invocation`（`user`/`model`）。手敲路径没有工具调用，`toolUseId` 为空。
- 用户中断（Esc）不触发 `Stop`，窗口会由下次提示词或下次会话启动收尾。

## 观察器本身没在记录时

表现为"完全没有新记录"。先跑幂等修复：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/ai-observer/install.ps1
```

`~/.claude/settings.json` 会被外部写入方整体重写并丢掉顶层 `hooks` 键；`install.ps1` 只替换 `hooks` 的值区间，写前必备份。新会话才生效。

## 改了 report.ps1 之后

改动 `scripts/report.ps1` 后必须跑回归，否则不要下结论：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/skills/ai-observer-view/tests/run-view-tests.ps1
```

覆盖两类最容易骗人的降级：无 `skillHash` / 无内容字段的旧记录必须显式说明而不是打印空表，以及关联不上的补正不得虚增调用数。当前 31 项。

## 未匹配请求

若用户要的不是以上四种视图（例如要改观察器脚本、要加新字段、要接入别的数据源），直接用通用知识处理并说明该技能只负责查看，不要加载 `scripts/report.ps1` 之外的东西，也不要改观察器文件。

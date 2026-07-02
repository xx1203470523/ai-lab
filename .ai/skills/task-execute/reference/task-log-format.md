# 任务日志格式

计划文件的 `## 任务日志` 段落使用 Markdown 表格追踪每个包的执行状态。

## 表格结构

```markdown
| 包 | 状态 | Agent | 开始时间 | 完成时间 | 备注 |
|----|------|-------|----------|----------|------|
| pkg-01 | running | abc123 | 2026-07-03 14:35 | - | Entity 定义中 |
| pkg-02 | pending | - | - | - | - |
| pkg-03 | done | def456 | 2026-07-03 14:40 | 2026-07-03 14:52 | 3 files, Controller API |
```

## 字段说明

| 字段 | 说明 | 示例 |
|------|------|------|
| 包 | 包的 id | `pkg-01` |
| 状态 | `pending` / `running` / `verifying` / `done` / `blocked` | `done` |
| Agent | Agent ID（运行中/完成时填写） | `abc123` |
| 开始时间 | Agent 启动时间 `YYYY-MM-DD HH:MM` | `2026-07-03 14:35` |
| 完成时间 | Agent 完成时间（done/blocked 时填写） | `2026-07-03 14:52` |
| 备注 | 简要说明（文件数、阻塞原因等） | `3 files, Controller API` |

## 状态流转

```
pending ──→ running ──→ verifying ──→ done
                       ↘ blocked
```

- `pending → running`：Agent 启动时，填写 Agent ID 和开始时间
- `running → verifying`：Agent 输出完成报告后，进入验证
- `verifying → done`：验证通过，填写完成时间和备注
- `verifying → blocked`：验证不通过或扩散超限，备注填写阻塞原因
- `blocked → pending`：用户手动重置后重试

## blocked 备注格式

阻塞时备注应包含足够信息供用户决策：

```
阻塞: {原因}
需确认: {具体问题}
建议: {下一步}
```

示例：

```
阻塞: 扩散检索超限
需确认: 是否需要读取 IMTC.WMS.AdminWebApi/Services/StockInService.cs
建议: 批准继续或调整 pkg-01 manifest 补充该文件
```

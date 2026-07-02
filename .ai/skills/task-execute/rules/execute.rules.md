# 执行约束

## 状态机

```
pending → running → verifying → done
                  ↘ blocked
```

- `pending`：包尚未开始执行
- `running`：Agent 正在执行
- `verifying`：Agent 完成，正在验证
- `done`：验证通过
- `blocked`：需要主会话干预（信息不足、范围扩大、用户确认）

`blocked` 状态的包可由用户手动重置为 `pending` 后重试。

## 顺序执行

- 严格按 plan.packages 数组顺序执行
- 前一个包状态变为 `done` 后才启动下一个
- 前一个包状态变为 `blocked` 时暂停整个流程，等待用户处理
- 禁止并行启动多个 Agent

## 上下文传递

- 后续包 Agent 启动时，在 prompt 中包含前序包的输出摘要
- 输出摘要包括：前序包修改的文件列表、关键变更说明
- 后续包如需要读取前序包输出文件，自动加入 manifest（不计入扩散检索次数）

## 工作目录

- 所有 Agent 在当前工作目录执行
- 不创建 git worktree
- plan 中的相对路径均相对于 `plan.project` 对应的项目根目录

## 路径解析

- plan 中 manifest、boundaries 的相对路径相对于项目根目录
- Agent 分派前，将 plan 中的相对路径转为绝对路径
- 项目根目录映射参考 CLAUDE.md 中的路径映射（如 `trade://` → `E:\My\project\trade`）

## 验证

- Agent 完成后，检查是否修改了 boundaries.forbid 路径
- 检查输出是否符合 contract.in_scope
- 不做完整代码审查（那是业务 skill 的 Verification Agent 职责）
- 验证通过 → 更新状态为 done
- 验证不通过 → 标记 blocked，记录不通过原因

## 日志更新

- 每包执行开始/完成时，立即更新 plan 文件中对应的任务日志行
- 任务日志表格字段：包 ID、状态、Agent、开始时间、完成时间、备注

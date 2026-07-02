---
name: task-execute
description: "任务执行模式：按 task-plan 生成的结构化计划文件顺序执行，每包独立 Agent，扩散检索限 3 次。触发：执行计划、task execute、/task-execute"
---

# Task Execute

## 核心安全规则

- 必须加载有效的 plan 文件，无 plan 文件或格式无效则拒绝执行
- Agent 严格顺序执行，前一个包 done 才能启动下一个，禁止并行
- 每个 Agent 初始只能读取 plan 中 manifest 指定的文件
- 扩散检索（超出 manifest 的额外文件读取）限 3 次，第 4 次必须停止并回报主会话
- Agent 发现任务范围超出 contract.out_of_scope 时立即停止并回报，禁止自行扩展
- 每包执行完成后立即更新 plan 文件中的任务日志
- 不创建 worktree，所有 Agent 在同一工作目录操作

## 路由

| 命令 | 入口 | 说明 |
|------|------|------|
| 执行计划（默认） | `./workflow/execution.md` | Step 0-3 完整执行流程 |
| 选择计划 | `./workflow/execution.md`（Step 0） | 列出 plans/ 下所有可执行计划 |
| 继续执行（续跑） | `./workflow/execution.md`（Step 0 续跑分支） | 从中断处继续 running 状态的计划 |
| 查看执行状态 | 直接读取 plan 文件任务日志 | 不启 Agent，仅查看状态 |
| 执行约束 | `./rules/execute.rules.md` | 状态机、顺序控制、路径解析 |
| 扩散检索与升级 | `./rules/escalation.rules.md` | 3 次限制、升级格式、配额管理 |
| Agent 模板 | `./reference/task-packet-template.md` | 分派 Agent 的标准 prompt |
| 任务日志格式 | `./reference/task-log-format.md` | 日志状态行规范 |

## 未匹配命令

若用户意图不在以上路由中（如仅查看执行状态、询问某包详情等），直接用通用知识处理。**不要**加载 workflow/ 和 rules/ 目录下的文件。

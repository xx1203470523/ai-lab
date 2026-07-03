# 多 Agent 编排

Complex 任务的分批、分派、执行序列。

## P0/P1/P2 分批

| 批次 | 后端范围 | Agent Domain | 策略 |
|------|----------|-------------|------|
| P0 | Entity + Repository | wms-entity, wms-repository | 数据层先行 |
| P1 | Service + DTO | wms-service | 业务居中 |
| P2 | Controller + API | wms-controller | 接口收尾 |

- 每批完成 → 验证 → 通过后启下一批
- P1 读取 P0 输出作为上下文
- P2 读取 P0 + P1 输出作为上下文
- 前端/PDA 的分批粒度由对应终端技能定义

## Context Passing (避免 Agent 重复读取)

主会话协调器已将规则读入上下文。向 Agent 传递规则时按以下策略：

- **短规则（≤50 行）**：在 Agent prompt 中内联关键约束摘要，Agent 不需要再读文件
- **长规则（>50 行）**：在 Agent prompt 中提供绝对路径 + 关键摘要（3-5 行），Agent 只读指定文件
- **禁止行为**：Agent 不得自行扫描 rules/ 目录、不得读取未在 prompt 中列出的 Pack、不得为了"了解上下文"而扩大读取范围

## Agent Task Packet 模板

分派 Agent 时，prompt 必须包含：

```markdown
## Agent Task Packet

- 任务目标：[一句话]
- 终端 Skill：wms-backend-dev / wms-frontend-dev / wms-pda-dev
- Domain Context：[entity / repository / service / controller]
- 当前工作目录：[项目根目录，已在用户 worktree 中，不创建额外隔离]
- 禁止使用 Agent 工具创建子 Agent——你已经是分派出来的实现 Agent，不需要再向下委托
- 禁止使用 isolation: "worktree"——用户已为你准备好工作环境，所有文件修改直接在当前目录进行

### Prerequisite Context（由协调器提供，不重复读取）
- 已加载的 Base Rules 摘要：[3-5 行关键约束]
- 已命中的 Pack 摘要：[3-5 行关键约束]

### 规则（绝对路径）
- Base Rules：E:\My\project\ai-lab\project\wms\skills\wms-backend-dev\rules\[domain].rules.md
- 命中 Packs（仅这些，不要读其他）：
  E:\My\project\ai-lab\project\wms\skills\wms-backend-dev\rules\packs\[pack].rules.md

### 边界
- 允许读取：[路径]
- 允许修改：[路径]
- 禁止读取/修改：IMTC.WMS.AdminUI/、IMTC.WMS.PDA/

### Task Contract
- 批次：P0 / P1 / P2
- In Scope：[明确范围]
- Out of Scope：[明确排除]
- 预计文件数：[N]
- 停止条件：[触发回报的条件]

### 启动指令
1. 先 Read Base Rules 和命中 Packs，再开始实现
2. 未命中的 packs 不要读取
3. 发现任务范围扩大时先回报，不要自行扩展
```

## 执行序列

```
Coordinator: 评估 → Complex → P0/P1/P2 计划 → 用户确认
    │
    ├─► [P0 Agent] → [P0 Verification Agent]
    │       P0 通过?
    │
    ├─► [P1 Agent]（读 P0 输出）→ [P1 Verification Agent]
    │       P1 通过?
    │
    ├─► [P2 Agent]（读 P0+P1 输出）→ [P2 Verification Agent]
    │       P2 通过?
    │
    └─► Coordinator 汇总 → Done / Blocked
```

## 冲突避免

- 所有 Agent 严格顺序执行，不并行
- 每批仅修改分配的路径
- 后批次 Agent 发现前批次文件需修改 → 回报协调器，由协调器决定是修正还是重派
- Verification Agent 只读不改

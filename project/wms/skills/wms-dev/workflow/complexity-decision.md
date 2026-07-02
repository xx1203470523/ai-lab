# 复杂度评估

收到开发任务后，按以下决策树判断 Simple vs Complex。

## Phase 1: 快速筛查

| 维度 | Simple 信号 | Complex 信号 |
|------|------------|-------------|
| 文件数 | ≤ 2 文件 | > 2 文件 |
| 层级数 | 单层（仅 Entity / 仅 Service / ...） | 跨层（2+ 层联动） |
| 契约影响 | 无 API/DTO/Web/PDA/打印/导出/外部系统变化 | 任何契约变化 |
| 跨端影响 | 不影响其他端 | 影响 Web / PDA / 外部系统 |
| 风险标志 | 无事务/状态流/库存/标签/T100/立库 | 涉及任一风险标志 |

## Phase 2: 确认复查

即便 Phase 1 全部命中 Simple，还需确认：

- [ ] 能否一次 Read 目标文件 + Base Rules 就完成？
- [ ] 能否一次 Verification 就覆盖？
- [ ] 改动会不会连锁影响其他层？

任一为 "否" → 升级为 Complex。

## Phase 3: 最终判定

```
if 全部 Simple 信号 AND 全部复查通过:
    → Simple Mode（协调器直接处理，不启 Agent）

else:
    → Complex Mode（读 multi-agent-planning.md，P0/P1/P2 分批 + Agent 编排）
```

## 边界情况

- 用户说"快速改一下""小改动"：仍然走完 Phase 1 筛查，不跳过
- 用户要求 Full Mode：直接 Complex，不看筛查结果
- Simple 执行中发现范围扩大：停止 → 升级到 Complex → 重新评估

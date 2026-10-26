# Task Spec Template

> 这是供 Planner、Implementer、Reviewer 共用的最小契约。L1 不必生成文件；L2 可删减标为“可选”的章节；L3/L4 不删事实、推断、决策、范围和验收。

```markdown
---
spec_id: task-spec-YYYYMMDD-HHMM-slug
revision: 1
status: DRAFT
complexity: L2 | L3 | L4
created: YYYY-MM-DDTHH:MM:SS
updated: YYYY-MM-DDTHH:MM:SS
base_commit: <git commit or working-tree marker>
title: "<短标题>"
request_original: "<用户原话>"
supersedes: null
approved_revision: null
approved_at: null
approved_by: null
---

# <短标题>

## 1. Gate Summary

- Status: `DRAFT`
- Complexity: `L2/L3/L4`
- Approval blocker: `<无 / Decision ID 列表>`
- Handoff: `<不可实施 / 用户批准后交给 task-implementer>`

## 2. Requirement Contract

### Explicit Requirements

- [R-01] `<用户明确要求>`

### Explicit Constraints

- [C-01] `<用户明确要求保持或禁止的行为>`

### Non-goals

- `<明确不在本任务中的内容>`

## 3. Evidence Ledger

### Facts

| ID | Evidence | Observation | Confidence |
|----|----------|-------------|------------|
| F-01 | `path/to/file:line` / `symbol` | `<代码可验证事实>` | high |

### Inferences

| ID | Based on | Inference | Confidence | Falsifier |
|----|----------|-----------|------------|-----------|
| I-01 | F-01, F-02 | `<实现推断，不是业务决定>` | medium | `<什么新证据会推翻>` |

### Unknowns

| ID | Unknown | Resolution | Owner |
|----|---------|------------|-------|
| U-01 | `<缺失信息>` | `auto-resolve` / `user-required` | Planner/User |

## 4. Current Behavior

| Dimension | Current evidence-backed behavior |
|-----------|----------------------------------|
| Actor/trigger | `<谁、何时、入口>` |
| Flow | `<调用顺序和关键分支>` |
| State/data | `<状态、读写字段、数据流>` |
| Failure/retry | `<校验、异常、重复请求>` |
| Consistency/auth | `<事务、锁、权限、兼容性>` |

## 5. Target Behavior

| Dimension | Target behavior | Source |
|-----------|-----------------|--------|
| User/system flow | `<变化或保持不变的具体步骤>` | `R/C/D` |
| State/data | `<状态转移和数据语义>` | `R/D` |
| Failure/retry | `<错误、重试、幂等结果>` | `R/D` |
| Consistency/auth | `<事务、权限、兼容性>` | `R/D` |

## 6. Business Rules And Decisions

### Confirmed Rules

- [B-01] `<已由用户、代码约定或明确规范确认的规则>`

### Decisions Required

| ID | Decision | Options | Planner recommendation | User decision | Re-approval impact |
|----|----------|---------|------------------------|---------------|--------------------|
| D-01 | `<高影响选择>` | `A / B` | `<可空；不是默认批准>` | `PENDING` | `<影响哪些章节>` |

## 7. Scope And Impact

### In Scope

- `<行为/契约/模块>`

### Out Of Scope

- `<不修改的模块、端、历史数据或兼容层>`

### Affected Areas

| Area | Evidence | Planned change | Write boundary |
|------|----------|----------------|-----------------|
| `<backend/web/PDA/data/external>` | `path:line` | `<变化>` | `<允许写入路径>` |

### Execution Boundaries

- allow_read: `<paths/globs>`
- allow_write: `<paths/globs>`
- forbid: `<paths/globs>`
- stop_condition: `<越界、契约冲突、证据不足时停止>`

## 8. Technical Approach

1. `<先稳定的契约或数据边界>`
2. `<业务编排、状态和事务处理>`
3. `<接口及各消费者适配>`
4. `<兼容、迁移、回滚或切换>`（如适用）

- Alternatives considered: `<无 / 方案及未选原因>`
- Dependencies: `<前置任务、配置、外部系统>`
- Files/symbols expected: `<path:symbol 列表；不是任意扩散许可>`

## 9. Risks And Mitigations

| ID | Trigger | Consequence | Mitigation/verification | Decision needed |
|----|---------|-------------|-------------------------|-----------------|
| K-01 | `<触发条件>` | `<后果>` | `<预防或验证>` | `yes/no` |

## 10. Acceptance Criteria

- [ ] AC-01 Given `<前置状态>`, when `<动作>`, then `<可观察结果>`。
- [ ] AC-02 Given `<重复/失败/边界>`, when `<动作>`, then `<幂等/错误/不变结果>`。
- [ ] AC-03 `<权限、兼容、迁移或跨端条件>`。

每条验收必须能映射到代码、测试、接口响应、数据库状态或用户可观察行为；避免“功能正常”“性能良好”等不可验证措辞。

## 11. Verification Plan

- Static/read-only checks: `<命令或检查>`
- Tests/build/smoke: `<需用户授权的命令>`
- Data reconciliation: `<如适用>`
- Not run: `<原因>`

## 12. Handoff And History

- Implementer input: `<Spec path + revision + boundaries + AC>`
- Conflict protocol: `<保持 APPROVED，报告 PLAN_CONFLICT，不静默扩大>`
- Change history:
  - `r01 DRAFT <time>` — `<创建原因>`
```

## 字段判定

- `Facts` 不能只写文件名，必须有路径、行号或符号。
- `Inferences` 必须有依据和可推翻条件。
- `Decisions` 只保留改变行为、数据、风险或验收的选择。
- `Acceptance Criteria` 至少覆盖一个成功路径和一个失败/重复/边界路径；L4 还要覆盖迁移、回滚或补偿。

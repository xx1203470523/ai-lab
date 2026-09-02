# Task Spec 模板

本模板用于 L2-L4，固定保留以下 12 节及顺序。L2 可以精简内容，但不得删除标题。

```markdown
---
spec_id: task-spec-YYYYMMDD-HHMM-slug
revision: 1
status: DRAFT
complexity: L2 | L3 | L4
style_contract: PROJECT + PERSONAL | PROJECT | PERSONAL | MINIMAL-CHANGE
created_at: YYYY-MM-DDTHH:mm:ss
updated_at: YYYY-MM-DDTHH:mm:ss
project_root: "<当前项目根目录>"
project_id: "<Git remote+repository / absolute root when no remote>"
evidence_baseline: "<Git HEAD + relevant dirty paths / non-Git investigation timestamp>"
request_original: "<用户原始需求>"
supersedes: null
package_path: "$HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\rNN\"
package_status: READY_FOR_APPROVAL
approved_at: null
approved_revision: null
approval_statement: null
---

# <简短标题>

## 1. Summary

- Goal: `<目标结果>`
- Problem: `<当前问题或机会>`
- Value: `<为什么值得做>`
- Complexity: `L2/L3/L4` — `<基于证据的原因>`
- Status: `DRAFT`

## 2. Current State

### Facts

| ID | Evidence | Confirmed observation |
|---|---|---|
| F-01 | `path/to/file:line` / `Symbol` | `<当前项目证据直接确认的行为>` |

### Known Gaps

- `<Not found after bounded search / 低风险缺口>`

## 3. Target State

### Explicit Requirements

- [R-01] `<用户明确要求的行为>`

### Inferences

| ID | Based on | Inference | Confidence | Falsifier |
|---|---|---|---|---|
| I-01 | F-01 | `<推导结论，不是已确认规则>` | medium | `<会推翻结论的证据>` |

## 4. Behavior

| Scenario | Trigger / Preconditions | System behavior | Observable result |
|---|---|---|---|
| Normal | `<...>` | `<...>` | `<...>` |
| Failure | `<...>` | `<...>` | `<...>` |
| Duplicate / Retry | `<...>` | `<...>` | `<...>` |
| Boundary | `<...>` | `<...>` | `<...>` |

只在相关时补充状态、数据流、幂等、一致性、事务、权限、迁移和兼容性。

## 5. Business Rules

- [B-01] `<已确认规则>` — Source: `<用户 / F-xx / 当前项目明确契约>`
- [C-01] `<必须保持的约束>`

不得把 Inference 当作已确认规则。

## 6. Scope / Out of Scope

### In Scope

- `<行为、契约、模块边界或数据范围>`

### Out of Scope

- `<明确不修改的行为、接口、端、历史数据、迁移或模块>`

## 7. Risks / Edge Cases

| ID | Trigger | Impact | Mitigation / Verification | Decision needed |
|---|---|---|---|---|
| K-01 | `<触发条件>` | `<行为或数据后果>` | `<预防或验证>` | `yes/no` |

L4 必须补充迁移、回滚/补偿、对账、并发和发布切换条件。

## 8. Technical Direction

- Contract boundary: `<API/数据/事件归属和兼容方向>`
- State/data direction: `<模型、状态、事务或一致性方向>`
- Dependency order: `<高层依赖顺序>`
- Candidate code anchors: `<当前项目 path:symbol；用于上下文，不是写入清单>`
- Style Contract: `<所选模式及适用项目/个人规范>`

不得写方法级步骤、伪代码或完整代码实施 Plan。

## 9. Reference Code Assessment

| Reference | Similarity | Reusable | Do not reuse | Quality / Legacy | Architecture fit | Style fit |
|---|---|---|---|---|---|---|
| `path:line` | `<相似原因>` | `<可复用部分>` | `<不应复用部分>` | `<评估>` | `<评估>` | `<评估>` |

`Existing Pattern != Recommended Standard`。

## 10. Open Decisions

| ID | Decision | Options | Recommendation | User decision | Blocking |
|---|---|---|---|---|---|
| D-01 | `<会改变行为/数据/风险/验收的选择>` | `A / B` | `<可选，不代表批准>` | `PENDING` | `yes/no` |

没有真正需要用户决定的问题时写“无”，不得制造问题。

## 11. Acceptance Criteria

- [ ] AC-01 — Given `<前置状态>`，when `<动作>`，then `<最终可观察行为>`；追溯到 `R-01/B-01`。
- [ ] AC-02 — Given `<失败、重复、重试或边界条件>`，when `<动作>`，then `<可观察错误/幂等/不变结果>`；追溯到 `<ID>`。
- [ ] AC-03 — `<权限、兼容性、迁移、跨端或对账结果（如适用）>`；追溯到 `<ID>`。

每条 AC 必须可由 Review Agent 直接使用，并能通过用户行为、API 响应、状态/数据证据或获准测试验证。

## Plan Package 交接

- `package_path`: `$HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\rNN\`
- 必需文件：`plan.md`、`plan-package.json`、`approval.html`、`approval.json`。
- Decision 字段：`resolution: auto-resolved | user-required`；只有 `user-required` 且 `blocking: true` 的项阻塞批准。
- 审批页面由脚本生成，页面导出 `approval-input.json`；脚本校验后写入 `approval.json`。
- `task-execute` 只能读取与 `approval.json` 精确匹配的 `APPROVED` revision。

## 12. Implementation Boundary

- Requirement source of truth: `<批准后的当前项目 Spec 路径 + revision>`
- Project / evidence baseline: `<project_id + evidence_baseline；变化时先重验>`
- Allowed Plan Mode responsibility: `HOW / FILES / METHODS / IMPLEMENTATION STEPS`
- Prohibited redefinition: `<已批准行为、规则、范围、约束、兼容性、AC>`
- Read boundary: `<当前项目内任务相关 paths/globs>`
- Expected write boundary: `<当前项目模块/区域，不允许无限制写入>`
- Stop conditions: `<范围扩大、证据冲突、未决 Decision、前置条件缺失>`
- Verification boundary: `<必需检查及需要额外授权的检查>`

DRAFT 不可执行。批准结果只写入当前 revision 的 `approval.json`，并由目录级 `approved.json` 指向批准 revision；不得修改已批准 package。实质变化必须创建新的 DRAFT revision，并以 `supersedes` 关联前一 revision。
```

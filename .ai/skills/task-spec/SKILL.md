---
name: task-spec
description: "把当前项目中的复杂开发需求整理为基于真实代码证据、可人工审批的结构化 Plan Package，作为 task-execute 的唯一需求边界；仅负责需求分析、行为、范围、决策、风险和验收，不负责代码实现。触发：需求规格、需求设计、Task Spec、task spec、/task-spec。"
argument-hint: "<自然语言需求或需求描述文件路径>"
---

# Task Spec

把开发需求整理为当前项目绑定的需求边界，并由脚本生成可审阅、可追踪、可交接的 Plan Package。非必要输出使用中文。

## 核心边界

- 负责 WHAT、WHY、BEHAVIOR、RULES、SCOPE、CONSTRAINTS、ACCEPTANCE，以及 Facts/Inferences/Decisions 分离。
- 不实现业务代码，不替代 Plan Mode；技术方案可收敛实现方向，但不把技术选择伪装成业务 Decision。允许 AI 代表用户执行本 Skill 的确定性 PowerShell 脚本（生成 Plan Package、渲染审批页、导入审批结果、校验批准 revision），但不得替用户伪造人工审批。
- 只有无法通过代码、项目规范、既有行为、需求上下文或合理推断确定，且会改变最终实现结果的问题，才标记为 `user-required`；其他 Decision 由 Planner 自行收敛并记录依据。
- L2-L4 的完整输出必须生成 Plan Package：`plan.md`、`plan-package.json`、`approval.html`、`approval.json`。脚本负责 JSON、HTML、revision、hash 和审批门禁，模型负责语义内容。
- `DRAFT`、`READY_FOR_APPROVAL`、`CHANGES_REQUESTED`、`REJECTED` 均不可执行；只有匹配的 `APPROVED` revision 可交给 task-execute。
- 已批准 revision 不可覆盖；实质变化创建新 revision 并通过 `supersedes` 关联。

## AI 执行入口

用户可以只提供需求描述文件路径，例如：

```text
/task-spec .\docs\需求说明.md
```

AI 必须先读取该文件，再调查当前项目并生成 proposal；不要要求用户手工拼接 JSON。生成 proposal 后，AI 调用 `scripts/create-plan-package.ps1`，并使用 `Start-Process` 打开 `approval.html`。用户在页面完成审批后，AI 读取用户提供的 `approval-input.json` 路径，调用 `scripts/approve-plan-package.ps1` 写入 `approval.json`。用户明确批准后，AI 调用 `scripts/read-approved-plan.ps1` 验证，再调用 `/task-execute` 或执行其 workflow。审批页面只收集意见；AI 可以执行脚本，但不能替用户选择 APPROVED、填写审批人或捏造批准内容。

## 当前项目绑定与证据纪律

1. Git 项目使用所属仓库根；非 Git 项目使用当前工作目录。
2. 读取项目入口、就近规则、架构/编码规范和相关任务历史；不存在时记录缺口，不猜测替代规则。
3. Facts 必须引用相对 `path:line` 和符号；Inference 关联 Fact ID、置信度和可推翻条件；Decision 标明 `auto-resolved` 或 `user-required`。
4. 记录 project/evidence baseline。进入审批或执行前若基线变化，先重验受影响事实、范围和 AC。
5. 每条 AC 必须描述可由用户、API、状态/数据证据或获准测试观察到的结果。

## 复杂度门禁

| 等级 | 信号 | 处理 |
|---|---|---|
| L1 | 局部、确定性、无业务行为变化 | 输出轻量判断和 AC，不生成 Package |
| L2 | 少量文件或单层，业务变化简单 | 生成精简 12 节 Package |
| L3 | 跨模块/层、规则、状态、数据模型或契约变化 | 完整 Package，必须批准 |
| L4 | 迁移、并发、一致性、事务、权限或不可逆变化 | 完整 Package + 风险/回滚/验证，必须批准 |

高风险信号不能因文件少而降级；未知项若可能改变行为至少按 L3 处理。

## 路由

| 场景 | 按需读取 | 动作 / 输出 |
|---|---|---|
| 新需求、修改 revision | `workflows/spec-lifecycle.md`、`reference/spec-template.md` | 调查并编译语义 proposal，调用 `scripts/create-plan-package.ps1` |
| 生成/重生成审批页面 | `reference/approval-contract.md` | 调用 `scripts/render-approval.ps1`，不手写 HTML |
| 导入批准、驳回或修改意见 | `reference/approval-contract.md` | 调用 `scripts/approve-plan-package.ps1` |
| Plan Mode / task-execute 交接 | `reference/approval-contract.md` | 调用 `scripts/read-approved-plan.ps1`，只交接 APPROVED revision |

不匹配开发需求规格与审批场景时，不加载 Supporting Files，转交通用流程或更合适的 Skill。

## 固定输出

L2-L4 保留 12 节：Summary → Current State → Target State → Behavior → Business Rules → Scope / Out of Scope → Risks / Edge Cases → Technical Direction → Reference Code Assessment → Open Decisions → Acceptance Criteria → Implementation Boundary。

Plan Package 默认保存到Skill 目录 `$HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\rNN\`；`request_slug` 为小写 kebab-case（最多 80 字符），日期按创建时间 UTC 生成。审批页面支持批准、驳回、提交修改意见；修改意见必须关联稳定 item ID。页面导出 `approval-input.json`，由脚本校验后写入 `approval.json`，因为 file:// 页面不能可靠直接写任意本地文件。

最终回复只提供 Package 目录、`plan.md`、`approval.html`、revision/status 和极简摘要，不重复打印完整计划。
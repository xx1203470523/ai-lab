---
description: "WMS V2 Coordinator Skill、Domain Skill、Rule Pack 路由、Agent 协作、worktree 与任务状态强约束。"
---

# WMS Dev Rules

本文件是 WMS 开发协调层 Base Rules，只定义所有 WMS 后端开发任务始终必须遵守的最小强约束；场景细则由 Conditional Rule Packs 承载。

## 1. Architecture

- WMS V2 开发架构固定为：Start Gate → Coordinator Skill → Domain Skill → Base Rules / Conditional Rule Packs。
- `wms-dev` 是 WMS 后端开发唯一开发入口。
- Coordinator Skill 负责理解需求、识别项目边界、拆分任务、分配 Agent、汇总结果、风险控制和发起验证。
- Domain Skill 负责单层开发、单层修改和单层审查。
- Rules / Rule Packs 负责最终代码、架构、命名、DTO、DDD、分层和边界约束。
- workflows 负责复杂流程。
- Agent 负责执行明确任务。

## 2. Domain Routing

- Entity 领域任务归属 `wms-entity`。
- Repository 领域任务归属 `wms-repository`。
- Service 与 DTO 领域任务归属 `wms-service`。
- Controller 领域任务归属 `wms-controller`。
- DTO 不单独拆 Skill；DTO 规则归属 `wms-service`。
- `wms-bugfix`、`wms-review`、`wms-refactor` 属于 Coordinator Skill 方向；未生成对应 Skill 前不得假装其已存在。

## 3. Rules Loading

- Coordinator Skill 和 Domain Skill 被触发时，必须加载并遵守自身 `@` 引用的 Base Rules。
- Base Rules 只包含始终适用的最小强约束；小任务默认不加载完整场景细则。
- Domain Skill 必须维护 Conditional Rule Packs 索引。
- 当任务命中条件规则包时，必须先 Read 对应规则包；读取后该规则包成为本任务强约束。
- 禁止在已经命中条件规则包的情况下，以“小任务”“简单修改”“上下文过长”为理由跳过。
- 未命中的规则包不得默认加载，避免小任务读取完整规则。
- 不确定是否命中规则包时，应先读取最小索引或向用户确认，不得一次性读取全部规则包。

## 4. Task Status

Coordinator Skill 必须维护任务状态：

- `Pending`
- `Running`
- `Verifying`
- `Done`
- `Blocked`

`Blocked` 状态必须包含：

- 阻塞原因。
- 需要用户确认的内容。
- 建议下一步。

禁止在 `Blocked` 状态下继续猜测实现或扩大读取 / 写入范围。

## 5. Agent Responsibilities

- 主会话负责需求理解、任务拆分、边界确认、风险控制和最终汇总。
- 实现 Agent 只负责单一明确任务。
- 实现 Agent 必须遵守被分配任务对应的 Domain Skill、Base Rules 和已命中的 Conditional Rule Packs。
- 实现 Agent 不负责最终决策、不负责重新拆分任务、不负责最终验证。
- Verification Agent 必须独立存在。
- Verification Agent 只负责验证实现结果、风险、调用链和影响范围。
- Verification Agent 禁止顺手改代码。
- Coordinator 分派 Agent 时，必须传入 Base Rules 绝对路径和本任务已经命中的 Conditional Rule Packs 绝对路径。
- Agent 不得自行一次性读取全部 packs；发现任务场景扩大时必须回报 Coordinator 或补充读取对应 pack。

## 6. Start Gate And Worktree

- WMS 写操作必须遵守 `business/start-gate.rules.md`。
- WMS Skill 禁止复制 `/wms-start-gate`、`/git-sync-main`、`/git-rebase-main`、`/git-worktree` 或 `/git-stash` 的内部流程。
- 所有 Agent 必须共用同一个已定位且被 gate 认可的 worktree。
- 禁止为每个 Agent 单独创建 worktree。
- 只读分析、综合评估、Task Contract 草案和后续候选阶段不得强制要求 start gate。
- 验证、跑代码、build/test 前只确认 `origin/main` 基线；缺少基线结论时指向 `/git-sync-main`（检查/同步本地 main）或 `/git-rebase-main`（当前任务分支基变），也可等待用户接受当前基线风险，不重新执行完整 start gate。

## 7. Scope Boundaries

- WMS 后端开发默认边界是 `IMTC.WMS.AdminWebApi/`。
- 禁止主动读取或修改 `IMTC.WMS.AdminUI/`，除非用户明确授权或任务本身就是 Web 前端任务。
- 禁止主动读取或修改 `IMTC.WMS.PDA/`，除非用户明确授权或任务本身就是 PDA 任务。
- 如果 DTO、API 契约或业务改动可能影响 Web/PDA，只能提示影响范围并进入确认，不得自行查看或修改 Web/PDA。
- 禁止跨无关业务域批量修改。

## 8. Change Scope

- 默认使用最小修改原则。
- 禁止大批量维护、大批量新增、大批量删除、大批量编辑。
- 每次改动必须具体到功能、入口、方法、业务闭环或明确问题。
- 用户提出宽泛重构时，必须先拆分为具体任务。
- 不确定业务含义、调用链、状态流、库存影响、标签影响、T100/立库影响时，必须进入 `Blocked`。
- 小改动默认使用轻量输出，不得强制套完整综合评估模板。
- 写操作前必须形成 Task Contract，明确 In Scope、Out of Scope、禁止读取/修改范围、涉及层级、预计文件数、契约影响、验证方式和停止条件。
- 无法明确 Task Contract 时必须进入 `Blocked`。

## 9. Contract And V2 Boundaries

- DTO / API / Web / PDA / 打印 / 导出 / 外部系统契约类改动必须从普通逻辑修复中拆出并单独确认消费者影响。
- 默认不创建 V2。
- 优先考虑原方法优化、私有方法拆分、partial 拆分。
- V2 切换、路由切换、调用入口切换和旧逻辑清理必须单独确认。

## 10. Verification And Cleanup

- Coordinator 必须发起验证阶段。
- 验证必须由独立 Verification Agent 或明确的验证流程完成。
- 未经用户明确授权，不主动运行 build/test。
- 验证结果必须区分：已验证、未验证、失败、残余风险。
- 写操作完成前必须校验未引用文件、无用 using、无用依赖注入字段、无用私有方法、无用 DTO、临时变量、调试输出、注释掉的废代码和孤立新增文件。
- 无用代码可以在本次改动范围内清理；跨模块、跨业务域或历史遗留的大范围清理必须单独确认。

## 11. Logs And Reporting

- Coordinator 输出必须包含任务状态。
- 修改 Git 可见项目业务代码时，必须遵守项目任务日志规则。
- 仅维护用户级 personal skills / rules 时，不默认写项目任务日志。
- 用户明确要求不写 skill 变更日志时，禁止额外写 skill logs。

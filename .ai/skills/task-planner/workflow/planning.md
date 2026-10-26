# Planning Workflow

## 0. 接收与边界

- 把用户原话保存为 `request_original`，不替用户改写成既定结论。
- 识别当前项目根目录、入口文档、适用 Skill/Rules 和相关历史；读取前先做针对性任务日志检索。
- 检查工作树是否有他人未提交改动；不覆盖、不清理、不把脏改动当作本任务结果。
- 如果用户只是问一个确定事实、修改一处文字或明显 L1 小修复，不启动完整 Planner。

## 1. 复杂度 Triage

按以下维度分别标记 `yes/no/unknown`：

- 领域或业务规则是否变化
- 是否跨 Entity/Repository、Service/Domain、Controller/API、Web、PDA、外部系统
- 是否改变状态机、库存/金额、事务、一致性或幂等
- 是否改变 DTO、路由、枚举、权限、导出/打印或兼容性
- 是否需要迁移、回填、删除、批量修复或不可逆操作
- 用户目标、范围或验收是否存在高影响歧义

映射到 SKILL.md 的 L1-L4。`unknown` 不得当作 `no`；如果它可能改变业务行为，升为 L3 并列出 Decision。

输出 triage 摘要，不在这里假装完成代码分析。

## 2. 证据检索

建立一个短的 `Evidence Ledger`，每条包含：`id`、`kind`、`path:line`、`symbol`、`observation`、`confidence`。

建议顺序：

1. 项目入口和配置：README/CLAUDE/项目 profile/模块清单。
2. 用户可触发入口：Controller、route、page、PDA action、job、消息消费者。
3. 调用链：DTO/参数校验 → Service/Domain → Repository/Entity/事务。
4. 消费者：Web/PDA、导出/打印、外部接口、权限定义、测试或类似实现。
5. 历史：命中同一模块的任务日志、最近修复和兼容性约定。

停止条件：至少能回答“谁触发、改了什么、写到哪里、状态如何变化、谁消费、失败如何处理、如何验证”。缺口只能是明确的 Open Decision 或低风险待查项。

检索限制：

- 不为“看起来完整”而扫描全仓库。
- 每次扩散检索都说明目的；重复读取同一文件不计为新证据。
- 找不到代码事实时写 `Not found after bounded search`，不要用经验填空。
- 用户明确要求方案但未授权实施时，所有操作保持只读，除非生成 DRAFT Spec 本身。

## 3. 行为建模

用表格表达现状和目标，避免只写技术文件清单：

| 维度 | Current（事实） | Target（明确要求/待决策） |
|------|------------------|----------------------------|
| Actor/Trigger | 谁在何时触发 | 触发方式是否改变 |
| System flow | 调用顺序与分支 | 哪些步骤新增/删除/保持 |
| State | 状态、转移、终态 | 新旧状态及非法转移 |
| Data | 读写实体、字段、数量 | 数据语义、来源、落点 |
| Failure | 校验、异常、部分失败 | 用户可见结果、重试语义 |
| Idempotency | 重复请求当前结果 | 重复请求目标结果 |
| Consistency | 事务、锁、事件边界 | 需要保持或改变的边界 |
| Auth/Compatibility | 权限、旧 API/端行为 | 保持、弃用或迁移 |

把“保持 PDA 操作流程不变”拆成可验证的用户动作、页面/扫描步骤、接口调用和可见结果，不接受口号式描述。

## 4. 事实/推断/决策分离

- `Facts`：代码、规则、历史中直接可验证的陈述，附证据。
- `Inferences`：由 Facts 推出的实现判断，附依据、置信度和可证伪条件。
- `Decisions`：不同选择会造成不同产品或数据结果，必须由用户选择；可附 Planner 推荐，但推荐不是批准。
- `Unknowns`：没有足够证据的事项，标注 `auto-resolve` 或 `user-required`。

不要把“当前代码这样做”写成“业务应该这样做”，也不要把“建议方案”写成用户已经同意。

## 5. 范围、方案与风险

- `In Scope` 写行为和受影响边界，不只写目录。
- `Out of Scope` 写明确不修改的端、接口、历史数据、状态或兼容层。
- 技术方案按依赖顺序描述契约、数据模型、业务编排、接口和消费者；写候选方案与选型理由，仅在确有分歧时保留备选。
- 每个风险包含：触发条件、后果、预防/验证、是否需要用户决策。
- L4 必须补充迁移前置、回滚/补偿、数据校验和发布切换策略；无法定义时保持 DRAFT。

## 6. 编译与审批

1. 读取 `../reference/spec-template.md`，按复杂度删减可选章节，不删 `Facts/Inferences/Decisions/Acceptance Criteria`。
2. 先在对话中展示：复杂度、关键事实、关键推断、阻塞 Decisions、范围摘要和拟写入路径。
3. 用户要求生成后写入 `status: DRAFT`，记录 `base_commit`、`revision`、证据来源和变更历史；如果项目 `plans/` 属于 Git-visible 范围，按项目 task-log 规则补充任务日志和 `logs/_entries/` 片段。
4. 用户提出修改时只更新受影响章节；任何批准后重大修改必须生成新 revision，旧版本保留。
5. 只有用户明确使用“批准/同意按此 Spec 实施”等语义，且无 `user-required` Decision，才可把该 revision 交给 Implementer。不要把“生成”“看起来可以”“继续分析”当作批准。
6. 首版生成的 Spec 默认只作为 `task-planner` 的规范化产物；若要被现有 `task-execute` 消费，必须由适配层将 `DRAFT/APPROVED` 映射为其既有 `pending` 执行状态，并保留 `spec_id/revision`。在适配层完成前，不声称与 `task-plan`/`task-execute` 已自动兼容。

## 7. 实施交接与冲突

交给 Implementer 的最小包：Spec 路径、`spec_id/revision`、状态、允许读写范围、契约、停止条件、Acceptance Criteria、验证命令和残余风险。

Implementer 必须在开始前验证：

- `status == APPROVED`
- revision 与交接消息一致
- 没有未决的 `user-required` Decision
- 目标路径在 `allow_write` 内，且没有触碰 `Out of Scope`

发现冲突时只报告：

```text
[PLAN_CONFLICT]
Spec: <spec_id> revision <n>
Conflict: <批准方案与真实代码的差异>
Impact: <为什么不能按原方案实施>
Evidence: <path:line>
Options: <可选修改>
Needs re-approval: <yes/no + 具体 Decision>
```

不要直接修改 APPROVED Spec、扩大写入范围或以技术困难替用户选择业务方案。用户批准新 revision 后，才恢复实施。

## 8. 完成与验证

- Implementer 只能提出 `IMPLEMENTED`，并附修改文件、未改文件、验证结果和偏差。
- Reviewer/Verification Agent 按 Acceptance Criteria 逐条记录 `pass/fail/not-run`，满足条件后才提出 `VERIFIED`。
- 测试或构建未获授权时写 `not-run: not authorized`，不得写成通过。
- Spec 状态变化必须保留 actor、时间、revision 和证据，不覆盖历史判断。

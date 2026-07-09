# Report Optimize Workflow

本 workflow 用于 WMS 后端报表新增、优化、重构前评估和受控落地。流程只负责步骤与状态，不承载最终强约束；强约束以 `rules/packs/service-report.rules.md` 为准，实践参考见 `report-development.md` 第二节"核心优化模式"。

## 1. Trigger

命中以下任一场景时读取本 workflow：

- 新增报表、优化报表、重构报表。
- 处理分页慢、导出慢、大批量导出内存高、用户反复刷新阻塞业务。
- 调整报表 QueryDto / PagedQueryDto / ExportDto。
- 调整报表主查询、分页查询、列表查询、导出查询或字段填充逻辑。
- 需要结合 `/dbsql` 做报表性能分析。

## 2. Load Rules

按实际命中场景读取：

1. `rules/service.rules.md`。
2. 报表场景读取 `rules/packs/service-report.rules.md`。
3. 涉及 DTO、查询条件、导出 DTO、API 返回字段时读取 `rules/packs/service-dto.rules.md`。
4. 涉及 Repository 查询、Where、分页、IN 条件、原生 SQL 或数据范围时读取 `rules/packs/repository-query.rules.md`。
5. 涉及 Controller 入参、路由或 API 契约时读取 Controller 相关规则包。
6. 涉及 V2、入口切换、调用链变化、旧逻辑清理或较大重构时读取 `rules/packs/service-v2.rules.md`。

未命中的规则包不得默认读取。

## 3. Read Scope

最小读取顺序：

1. 目标报表 Service 实现。
2. 目标报表 Interface。
3. 目标报表 DTO 文件。
4. 目标 Controller 或 API 入口；只有契约判断必要时读取。
5. 直接相关 Repository / Entity；只在确认字段、索引、表关系或数据范围时读取。
6. 参考报表最多读取 2-3 个，不做全报表扫描。

禁止主动读取 `IMTC.WMS.AdminUI/` 或 `IMTC.WMS.PDA/`；可能影响前端/PDA 时只提示影响并等待确认。

## 4. Current Report Assessment

对目标报表输出以下结论：

- 报表入口：分页、列表、导出、Controller 路由。
- 查询主体：主表、明细表、标签表、维表、字典表、用户表。
- DTO 结构：QueryDto、PagedQueryDto、Dto、ExportDto 是否分离。
- 查询条件：是否允许默认无条件查询，是否有弱条件，是否有时间范围。
- **默认时间兜底**：无时间条件时是否有默认范围，是否有最大跨度限制。
- 字符串匹配：是否存在全模糊或不适合索引的条件。
- Id 预查：是否存在先查 Id 再 Contains，命中表是否适合小结果集策略。
- **预查 ID + IN**：是否存在大结果集 `CollectIds → Contains(ids)` 模式，是否可改为 EXISTS。
- 分页形态：是否直接 `ToPageAsync`，是否有 count 上限，是否加了不必要的 OrderBy。
- **分页/导出分离**：分页和导出是否使用独立查询构建器，分页是否最小 JOIN。
- 导出形态：是否先 count，是否全量 `ToListAsync`，是否后置判断上限，是否 MiniExcel。
- **导出 COUNT**：COUNT 是否在核心表执行还是对全量 JOIN 执行。
- 字段填充：是否只按当前页 / 当前批次补充，是否存在全量补充风险。
- 并发限制：是否有用户级导出锁或查询防刷。

## 5. Optional Database Analysis

只有用户授权数据库查询或明确使用 `/dbsql` 时执行。

允许：

- 表结构、索引、字段类型。
- 目标条件下的 count。
- 带 limit 的分页样本查询。
- 执行计划或小范围 explain。

禁止：

- 无条件全量 select。
- 无 limit 大范围查询。
- 全量导出或压力测试。
- 会长时间锁表或影响业务的验证。

数据库分析结果必须说明 SQL 条件、limit、结果数量和风险；没有执行数据库分析时写明"未做数据库验证"。

## 6. Design Options

根据评估输出 1-3 个方案：

### 保守方案

- 保持 API 和 DTO 契约不变。
- 增加默认时间范围兜底、查询条件保护、导出 count 限制、导出锁或局部查询优化。
- 适合快速降低风险。

### 中等改造方案

- 拆分分页查询和导出查询为独立构建器（`BuildPagedQuery` / `BuildExportQuery`）。
- 分页用最小 JOIN + EXISTS 子查询；导出用完整 JOIN 让 DB 优化。
- 分离 QueryDto / PagedQueryDto / ExportDto，但不改变对外字段含义。
- 导出 COUNT 改为核心表查询。

### 高风险重构方案

- 涉及字段语义调整、冗余字段、索引建议、V2 并行或入口切换。
- 必须单独确认消费者、Web/PDA/API 影响和回退方案。

## 7. Task Contract Before Write

进入写操作前必须形成 Task Contract：

- In Scope：本次只改哪个报表、哪些入口、哪些方法。
- Out of Scope：不改哪些报表、字段、Controller、Web/PDA、数据库结构。
- 禁止读取/修改范围。
- 涉及层级：Service / DTO / Repository Query / Controller。
- 预计文件数。
- 契约影响：是否影响 API、Web、PDA、导出列。
- 验证方式：只读检查、build/test 是否需要用户授权、数据库验证是否授权。
- 停止条件：字段语义不明、数据量不明、消费者影响不明、查询结果可能改变。

Task Contract 不明确时进入 Blocked。

## 8. Implementation Order

推荐顺序：

1. 提取或整理基础查询方法。
2. 分离分页查询构建器与导出查询构建器（`BuildPagedQuery` / `BuildExportQuery`）。
3. 增加查询条件校验（含默认时间范围兜底）。
4. 增加 count / 上限保护。
5. 将预查 ID + IN 改为 EXISTS 子查询（参考 `report-development.md` 2.3 节）。
6. 导出 COUNT 改为核心表查询（参考 `report-development.md` 2.4 节）。
7. 调整导出入口，使用 MiniExcel 和 ExportDto。
8. 增加导出锁或查询防刷。
9. 只在确认后调整字段语义、导出列或 API 契约。

禁止把字段语义修正、DTO 契约变化、入口切换和性能优化混在一个未确认批次里。

## 9. Verification Handoff

完成后输出：

- 已验证：命令、只读检查、数据库小样本检查或手工审查结果。
- 未验证：未运行 build/test、未做数据库查询、未覆盖并发等原因。
- 失败：失败命令和错误摘要。
- 残余风险：字段语义、数据量、索引、消费者、导出上限、查询锁。
- 后续候选：需要单独确认的索引、冗余字段、V2、前端条件限制或异步导出。

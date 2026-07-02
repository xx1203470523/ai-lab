# Service Base Rules

本文件是 `wms-service` 的 Base Rules，只包含 Service / DTO 任务始终适用的最小强约束；DTO、事务、V2 等细则按场景读取 `rules/business/packs/`。

## 1. Scope

- `wms-service` 负责 Service、DTO、Service 重构和 DTO 重构。
- DTO 不单独拆 Skill；DTO 是 Service 契约的一部分，规则归属 `wms-service`。
- Service 规则适用于 `IMTC.WMS.AdminWebApi/Services/**/*.cs` 下的服务层代码。
- Service 规则不替代 Entity、Repository、Controller 的专项 Rules。
- 涉及 Entity 字段、SqlSugar 特性、索引、可空性时，必须同时遵守实体 Base Rules 与命中的 Entity Rule Packs。
- 涉及 Repository 查询、原生 SQL、持久化访问时，必须同时遵守 Repository Base Rules 与命中的 Repository Rule Packs。

## 2. Conditional Rule Packs

| 场景 | 规则包 |
|---|---|
| DTO 命名、字段、输入/输出/查询结构、API 返回结构 | `rules/business/packs/service-dto.rules.md` |
| 事务边界、状态流、远程调用、库存/标签/T100/立库风险 | `rules/business/packs/service-transaction.rules.md` |
| V2 Service / V2 DTO / 调用切换 / 旧逻辑清理 | `rules/business/packs/service-v2.rules.md` |

## 3. Service Responsibility

- Service 负责业务编排、事务边界、领域协调、调用链闭环、异常闭环和接口返回组装。
- Repository 负责持久化访问；禁止把复杂持久化细节堆入 Service。
- Controller 负责接口入口；禁止把复杂业务逻辑堆入 Controller。
- DTO 负责明确表达 Service 输入、输出、查询、创建、更新、删除和过程结果。
- Service 禁止依赖 Web 或 PDA 页面结构。
- Service 禁止用前端展示状态替代业务状态。

## 4. Namespace And Class Shape

- WMS 服务层默认使用类库级 namespace，例如 `namespace Services.Warehouse;`。
- Service 类命名使用 `<BusinessName>Service`。
- 接口命名使用 `I<BusinessName>Service`。
- 可注入服务类默认实现 `ITransient` 或项目既有等价生命周期。
- 大型 Service 可使用 `partial class` 按职责拆分文件。
- 主 Service 文件应优先承载类 summary、接口实现、依赖字段和构造函数。
- 公共方法必须有 XML `<summary>`。
- 异步方法名统一以 `Async` 结尾；同步方法不要加 `Async`。

## 5. No Broad Maintenance

- 禁止大批量维护、大批量新增、大批量删除、大批量编辑。
- 每次 Service 改动必须绑定具体功能、具体入口、具体方法、具体 bug 或明确业务闭环。
- 禁止跨多个无关 Service 同时重构。
- 禁止以“统一整理”“全部优化”“批量清理”为目标直接修改服务层代码。
- 发现多处类似问题时，只能列为建议清单，未经确认不得批量落地。

## 6. Context Closure

- 修改 Service 逻辑前必须确认调用链上下文。
- 禁止只看单个方法就修改业务逻辑。
- 必须明确输入来源、输出消费者、数据来源、事务边界、异常分支、状态流和后续影响。
- 不确定业务含义、状态流、库存影响、标签影响、T100/立库影响、远程调用影响时，禁止动手并进入 `Blocked`。
- 禁止根据方法名、字段名或历史代码猜测业务逻辑。
- 禁止为了“看起来合理”补不存在的状态、枚举、库存动作或远程调用。

## 7. Original Logic Protection

- 默认保护原业务逻辑。
- 小范围 bug 修复或局部优化允许在确认范围内最小修改原方法。
- 异常逻辑、状态流、库存流、标签流、T100/立库回调逻辑必须先确认或读取命中的事务/状态相关 Rule Pack。
- 发现问题时必须先区分：bug、优化、风险、闭环、可抽象。
- 未经确认，禁止把建议直接落地为业务逻辑改动。
- 禁止删除历史兼容逻辑、兜底逻辑、旧字段、旧 DTO 或旧接口返回结构，除非用户明确要求。

## 8. Split And Boundary

- 一个 Service 方法只处理一个明确业务动作。
- 一个 partial 文件只承载一个职责方向。
- 可按职责使用 partial 文件，例如查询、创建、更新、删除、扫描、校验、打印、导出、回调、同步、反审。
- 禁止把查询、校验、事务写入、远程调用、DTO 拼装全部堆在一个不可维护的大方法中。
- 禁止为了形式拆分；拆分必须提升可读性、可验证性、复用性或性能边界。
- Service 可调用 Repository，但不得把 Repository 变成业务编排中心。
- Service 可调用其他 Service，但必须避免循环依赖和职责漂移。
- Service 禁止直接拼接复杂 SQL；复杂查询应优先下沉到 Repository。

## 9. Contract Protection

- DTO 字段删除、重命名、改类型、改可空性必须先确认影响范围，并读取 `service-dto.rules.md`。
- DTO 修改如果涉及 Web、PDA、API、打印、导出或外部系统契约，必须先确认。
- 未经用户明确授权，禁止主动读取或修改 `IMTC.WMS.AdminUI/`。
- 未经用户明确授权，禁止主动读取或修改 `IMTC.WMS.PDA/`。
- 可能影响 Web/PDA 时，只能提示影响范围并等待确认。

## 10. Exception And Validation

- 业务异常必须使用项目既有异常机制，例如 `CustomException` 或项目等价方式。
- 异常消息必须面向业务语义，禁止只输出空泛技术错误。
- 异常分支不得吞掉关键错误或让业务进入未知状态。
- Service 改动必须有验证环节。
- 验证必须覆盖调用链、DTO 契约、事务边界、异常分支、状态闭环和受影响范围。
- 未经用户明确授权，不主动运行 build/test。
- 改动后必须排查无用 using、无用字段、无用私有方法、无用 DTO、临时变量、调试输出和注释掉的废代码。
- 禁止留下未使用代码或临时注释。

## 11. Formatting

- 代码注释使用简体中文。
- 代码标识符使用英文并遵循项目既有命名。
- C# 缩进使用 4 个空格。
- 方法之间保留一行空行。
- 禁止无关排序、无关格式化、无关重排。

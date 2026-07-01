---
description: "Service DTO Conditional Rule Pack：DTO 命名、数据形态、契约保护和消费者影响约束。"
paths:
  - "IMTC.WMS.AdminWebApi/Services/**/*.cs"
---

# Service DTO Rule Pack

命中条件：任务涉及 DTO 入参、出参、查询条件、输出结构、API 返回字段、打印、导出、Web/PDA 消费结构或 V2 DTO。

## 1. DTO Naming

DTO 命名优先级：

- `XxxDto`
- `XxxQueryDto`
- `XxxOutputDto`

允许扩展命名：

- `XxxCreateDto`
- `XxxUpdateDto`
- `XxxDeleteDto`
- `XxxInputDto`
- `XxxResultDto`
- `XxxContextDto`
- `XxxProcessDto`
- `XxxPrintDto`
- `XxxExportDto`

V2 DTO 命名：

- `XxxV2Dto`
- `XxxV2QueryDto`
- `XxxV2OutputDto`

DTO 名称必须表达用途，禁止使用含义模糊的 `DataDto`、`InfoDto`、`TempDto` 作为新增业务 DTO。

## 2. DTO Data Shape

- 禁止使用 `object` 承载业务字段。
- 禁止使用 `dynamic` 承载业务字段。
- 禁止使用 `Dictionary<string, object>` 承载业务字段。
- 禁止使用 `object[]` 承载业务字段。
- 禁止使用裸数组或魔法下标表达业务结构。
- 禁止使用 tuple / ValueTuple 承载复杂业务结果。
- 跨方法、跨层、跨服务传递的业务数据必须使用明确 DTO。
- 复杂流程上下文必须使用明确的 `XxxContextDto`、`XxxProcessDto` 或 `XxxResultDto`。
- 集合类型必须明确元素类型。

## 3. Contract Protection

- DTO 字段删除、重命名、改类型、改可空性必须先确认影响范围。
- DTO 新增字段必须说明消费者和业务含义。
- DTO 修改如果涉及 Web、PDA 或 API 契约，必须先确认。
- 未经用户明确授权，禁止主动读取或修改 `IMTC.WMS.AdminUI/`。
- 未经用户明确授权，禁止主动读取或修改 `IMTC.WMS.PDA/`。
- 可能影响 Web/PDA 时，只能提示影响范围并等待确认。
- 打印、导出、PDA 扫描、Web 表格、API 返回结构涉及 DTO 变化时必须保持契约风险可见。

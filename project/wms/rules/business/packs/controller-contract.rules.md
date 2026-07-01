---
description: "Controller Contract Conditional Rule Pack：API 参数绑定、返回结构、DTO 契约和消费者影响约束。"
paths:
  - "IMTC.WMS.AdminWebApi/Application/**/*.cs"
  - "IMTC.WMS.AdminWebApi/Presentation/**/*.cs"
---

# Controller Contract Rule Pack

命中条件：任务涉及 Action 入参、返回结构、DTO、API 包装、字段命名、字段类型、可空性、Web/PDA/打印/导出/外部系统消费者。

## API Contract

- Action 入参必须使用明确 DTO、Query DTO、简单路由参数或项目既有参数绑定方式。
- 禁止使用 `object`、`dynamic`、裸 `Dictionary<string, object>` 或魔法下标承载业务入参或返回结构。
- API 返回结构必须保持项目既有返回约定；禁止擅自改变包装结构、字段命名、字段类型或可空性。
- 新增或修改返回字段必须说明消费者和契约风险。
- 影响 Web、PDA、打印、导出或外部系统契约时，必须先确认。
- 涉及 DTO 输入输出结构时，必须同时读取 `rules/business/packs/service-dto.rules.md`。

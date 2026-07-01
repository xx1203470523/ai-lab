---
description: "Service V2 Conditional Rule Pack：V2 Service、V2 DTO、入口切换、旧逻辑清理和回退约束。"
paths:
  - "IMTC.WMS.AdminWebApi/Services/**/*.cs"
---

# Service V2 Rule Pack

命中条件：用户明确要求重构，或任务涉及 Service 职责变化、DTO 结构变化、调用链变化、风险较高、改动范围较大、V2 并行实现、入口切换或旧逻辑清理。

## 1. V2 Strategy

- 默认使用最小修改原则。
- 优先使用原方法优化、私有方法拆分、partial 拆分。
- 以下情况才考虑创建 V2：用户明确要求重构、Service 职责变化、DTO 结构变化、调用链变化、风险较高、改动范围较大。
- 禁止为了小范围修复无理由创建 V2。

## 2. Naming

- V2 Service 命名使用 `XxxV2Service` 或项目已存在的等价 V2 命名。
- V2 DTO 命名使用 `XxxV2Dto`、`XxxV2QueryDto`、`XxxV2OutputDto`。
- V2 命名必须表达与原逻辑的差异边界，禁止仅为试验新增模糊 V2 类。

## 3. Compatibility And Switching

- V2 与原逻辑并行时必须保留原入口和回退可能。
- V2 创建后默认不直接替换原入口。
- 路由切换、Controller 切换、内部调用切换、旧逻辑清理必须单独确认。
- 旧逻辑清理必须在 V2 验证无风险后单独确认。
- 回切命名、删除旧 DTO、删除旧方法或移除兼容字段必须单独确认。

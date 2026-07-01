---
description: "Service Transaction Conditional Rule Pack：事务边界、远程调用、状态流、库存标签和异常闭环约束。"
paths:
  - "IMTC.WMS.AdminWebApi/Services/**/*.cs"
---

# Service Transaction Rule Pack

命中条件：任务涉及事务、状态切换、库存、标签、质检、调拨、T100、立库、远程调用、多 Repository 写入、异常恢复或回调失败处理。

## 1. Transaction Boundary

- Service 是业务事务边界的默认承载层。
- 可预先完成的查询应在事务外完成。
- 事务内只放必须原子化的新增、更新、软删除、状态切换和记录写入。
- 禁止在事务中放入可提前完成的大查询、远程调用、打印、导出或复杂计算。
- T100、立库、外部 HTTP 调用默认不放在数据库事务中。
- 事务失败、远程失败、回调失败必须有明确状态闭环或风险说明。

## 2. Remote / Repository Boundary

- Service 可调用 Repository，但不得把 Repository 变成业务编排中心。
- Service 可调用其他 Service，但必须避免循环依赖和职责漂移。
- Service 修改实体字段语义时必须确认实体规则和数据库影响。
- Service 调用远程系统必须明确失败处理、状态记录和重试或人工处理边界。

## 3. Exception And Status Flow

- 业务异常必须使用项目既有异常机制，例如 `CustomException` 或项目等价方式。
- 异常消息必须面向业务语义，禁止只输出空泛技术错误。
- 状态变更必须有明确前置状态、目标状态和失败分支。
- 库存、标签、质检、调拨、T100、立库等高风险状态流不得靠猜测补逻辑。
- 异常分支不得吞掉关键错误或让业务进入未知状态。

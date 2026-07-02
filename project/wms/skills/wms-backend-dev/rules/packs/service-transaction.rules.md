# Service Transaction Rule Pack

命中条件：任务涉及事务边界、多 Repository 写入、异常恢复或回调失败处理。

## Transaction Boundary

- Service 是业务事务边界的默认承载层。
- 可预先完成的查询应在事务外完成。
- 事务内只放必须原子化的新增、更新、软删除、状态切换和记录写入。
- 禁止在事务中放入可提前完成的大查询、打印、导出或复杂计算。
- 事务失败、回调失败必须有明确状态闭环或风险说明。

## Multi-Repository Writes

- Service 可调用 Repository，但不得把 Repository 变成业务编排中心。
- Service 可调用其他 Service，但必须避免循环依赖和职责漂移。

## Exception Recovery

- 业务异常必须使用项目既有异常机制，例如 `CustomException` 或项目等价方式。
- 异常消息必须面向业务语义，禁止只输出空泛技术错误。
- 异常分支不得吞掉关键错误或让业务进入未知状态。

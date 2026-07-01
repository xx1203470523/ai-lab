---
description: "Controller Route Conditional Rule Pack：路由、HTTP 动作、路由冲突和路径语义约束。"
paths:
  - "IMTC.WMS.AdminWebApi/Application/**/*.cs"
  - "IMTC.WMS.AdminWebApi/Presentation/**/*.cs"
---

# Controller Route Rule Pack

命中条件：任务涉及新增/修改 Controller 路由、HTTP 动作、Action 名称、路由前缀、路由冲突或删除旧路由。

## Route Shape

- Controller 路由必须统一、稳定、可读，避免同一模块内出现多套不一致前缀。
- 新增路由必须表达业务资源或业务动作，禁止使用含义模糊的 `test`、`temp`、`do`、`handle` 等路径片段。
- HTTP 动作必须与语义匹配：查询使用 GET 或项目既有查询约定，创建使用 POST，更新使用 PUT/POST 按项目既有约定，删除使用 DELETE/POST 按项目既有约定。
- 路由变更、路由重命名、删除旧路由或改变 HTTP 动词属于 API 契约变化，必须先确认影响范围。
- 禁止为同一业务动作新增重复路由；必须避免路由冲突、大小写差异冲突和参数模板冲突。

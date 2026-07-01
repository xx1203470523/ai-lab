---
description: "IMTC.WMS 后端 Controller Base Rules：职责边界、入口结构、依赖边界、清理和格式约束。"
paths:
  - "IMTC.WMS.AdminWebApi/Application/**/*.cs"
  - "IMTC.WMS.AdminWebApi/Presentation/**/*.cs"
---

# Controller Base Rules

本文件是 `wms-controller` 的 Base Rules，只包含 Controller 任务始终适用的最小强约束；路由、鉴权、契约细则按场景读取 `rules/business/packs/`。

## 1. Scope And Packs

- `wms-controller` 负责 Controller、API 路由入口、HTTP 动作、接口摘要、鉴权提示、参数绑定和返回契约入口。
- Controller 规则不替代 Entity、Repository、Service 或 DTO 的专项 Rules。
- 涉及 DTO 输入输出结构时，必须同时遵守 Service Base Rules 与命中的 Service DTO Rule Pack。
- 涉及业务编排、事务、库存、标签、T100、立库或远程调用时，必须下沉到 Service，不得堆入 Controller。

| 场景 | 规则包 |
|---|---|
| 路由、HTTP 动作、路由冲突 | `rules/business/packs/controller-route.rules.md` |
| 鉴权、权限码、匿名访问、菜单权限 | `rules/business/packs/controller-auth.rules.md` |
| 参数绑定、返回结构、API/Web/PDA/外部系统契约 | `rules/business/packs/controller-contract.rules.md` |

## 2. Single Responsibility

- 一个 Controller Action 只负责一个明确 API 入口。
- Controller 只负责参数接收、基础入口校验、调用 Service、包装或返回结果。
- Controller 禁止承载复杂业务编排、事务边界、Repository 查询、原生 SQL、远程系统调用、库存或标签状态流。
- Controller 禁止直接依赖 Web PC 或 PDA 页面结构。
- Controller 禁止为了前端展示方便硬编码业务状态、展示文案或页面流程。

## 3. Documentation And Naming

- 新增 Controller 和新增公共 Action 必须有 XML `<summary>` 或项目既有等价接口说明。
- Action 名称必须表达业务动作，禁止新增含义模糊的 `GetData`、`DoPost`、`Handle`、`Test` 等名称。
- Controller 类名必须表达资源或业务模块，禁止把多个无关业务入口塞入一个 Controller。
- 代码注释使用简体中文。
- 代码标识符使用英文并遵循项目既有命名。

## 4. Dependency Boundary

- Controller 依赖优先指向 Service 或项目既有应用服务，不直接依赖 Repository。
- 新增依赖注入字段必须被当前 Controller 使用；禁止留下未使用注入字段。
- Controller 禁止直接开启业务事务。
- Controller 禁止直接拼接 SQL 或调用数据库上下文完成复杂查询。

## 5. Validation And Cleanup

- 新增或修改 Controller 后必须检查路由冲突、HTTP 动词、参数绑定、返回契约和鉴权风险。
- 必须清理未使用 using、未使用依赖注入字段、未使用私有方法、临时变量、调试输出、注释掉的废代码和孤立新增文件。
- 禁止留下临时接口、测试接口、调试路由或仅为本地验证存在的 Controller 代码。
- 跨模块历史 Controller 的大范围清理必须单独确认，不得混入当前需求。

## 6. Formatting

- C# 缩进使用 4 个空格。
- 方法之间保留一行空行。
- 禁止无关排序、无关格式化、无关重排。
- 禁止因规范化重命名历史 Controller、历史 Action 或历史路由，除非用户明确要求。

# Controller Base Rules

本文件定义 WMS Controller 层始终适用的最小开发约束。
具体路由、鉴权、契约等场景规则由 Rule Pack 提供。

---

## 1. Responsibility

Controller 只负责：

- API 入口定义
- 参数接收与基础校验
- 调用 Service
- 返回接口结果

Controller 禁止：

- 编写业务流程
- 处理事务
- 编写数据库查询
- 调用 Repository
- 调用外部系统
- 处理库存、标签、状态流等业务逻辑

---

## 2. Dependency Boundary

- Controller 默认依赖 Service。
- 禁止直接依赖 Repository。
- 禁止直接操作数据库。
- 禁止依赖 Web/PDA 页面逻辑。

新增依赖必须：

- 当前 Controller 实际使用。
- 符合项目已有依赖模式。

---

## 3. API Contract

涉及以下修改时必须确认影响范围：

- 路由
- HTTP 方法
- 请求参数
- 返回 DTO
- 返回字段
- 接口行为

禁止：

- 未确认删除接口字段。
- 未确认修改返回结构。
- 为单一前端展示需求污染业务接口。

---

## 4. Naming And Documentation

新增 Controller / Action：

- 名称必须表达业务含义。
- 必须符合项目已有命名方式。
- 公共接口需要 XML Summary。

禁止新增：

- GetData
- DoPost
- Handle
- Test

等无明确业务含义名称。

---

## 5. Action Design

一个 Action：

- 对应一个明确 API 入口。
- 保持参数、调用、返回流程清晰。

禁止：

- 一个接口承载多个无关业务动作。
- 在 Action 中堆积复杂判断。
- 在 Controller 中组装复杂业务对象。

---

## 6. Compatibility Protection

默认保护：

- 历史接口
- 历史参数
- 历史返回结构

禁止：

- 因代码优化删除接口。
- 因规范化修改历史路由。
- 因重构破坏已有调用方。

---

## 7. Cleanup

修改 Controller 后检查：

- 未使用 using
- 未使用依赖注入字段
- 临时接口
- 调试代码
- 注释废代码

禁止保留：

- 测试 Action
- 临时路由
- 本地调试代码

---

## 8. Formatting

- C# 使用 4 空格缩进。
- 保持项目已有格式。
- 禁止无关格式化。
- 禁止无关代码移动。

---

## Rule Packs

以下内容不属于 Base Rules：

- 路由详细规范
- HTTP 动作选择
- 权限码规则
- 参数绑定规则
- API 契约兼容规则

根据任务场景读取对应 Rule Pack。

---
description: "Controller Auth Conditional Rule Pack：鉴权、权限码、匿名访问、菜单权限和数据权限风险约束。"
paths:
  - "IMTC.WMS.AdminWebApi/Application/**/*.cs"
  - "IMTC.WMS.AdminWebApi/Presentation/**/*.cs"
---

# Controller Auth Rule Pack

命中条件：任务涉及鉴权特性、权限码、匿名访问、菜单权限、数据权限、认证绕过、接口暴露范围或审查鉴权风险。

## Authorization And Permission

- 鉴权、权限、匿名访问、数据权限等特性默认保持项目当前写法；新增接口优先沿用同模块或同 Controller 的现有方式。
- 发现鉴权缺失、过宽、过窄或与相邻接口不一致时，只能警告并说明风险，不得擅自批量修改鉴权模型。
- 变更鉴权特性、权限码、匿名访问策略、菜单权限或数据权限属于高风险行为，必须先确认。
- 禁止为了让接口临时可调而新增匿名访问、绕过权限或移除鉴权。

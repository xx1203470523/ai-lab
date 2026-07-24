---
name: wms-pda-dev
description: "WMS PDA 手持端（uni-app）开发技能。当前为骨架版本，规则待后续补充。由 wms-dev 协调器路由触发，或直接 /wms-pda-dev。仅在涉及 IMTC.WMS.PDA 时加载。"
shell: powershell
version: 0.1.0
---

# WMS PDA Dev — PDA 终端 Skill

> **状态：骨架（v0.1.0）**。规则目录已预留，待后续补充 PDA 开发规范。

## Trigger

- wms-dev 协调器路由 PDA 任务到本 skill
- 用户直接指定：`/wms-pda-dev`
- 涉及 `IMTC.WMS.PDA/` 的代码变更

## Scope

- 项目：uni-app 手持端应用
- 路径：`IMTC.WMS.PDA/`
- 技术栈：uni-app（Vue） + 混合开发

## Completion Verification

- 每次代码修改完成后，必须执行 `IMTC.WMS.PDA/` build
- build 输出默认忽略 warning，只保留 error/fail/失败摘要
- error 必须清零；未执行 build 不得报告完成

## Routing（预留）

| 场景 | 入口 | 状态 |
|------|------|------|
| 页面开发 | `./rules/` (待建) | 预留 |
| 扫码/设备 | `./rules/` (待建) | 预留 |
| API 对接 | `./rules/` (待建) | 预留 |
| 发布打包 | `./rules/` (待建) | 预留 |

## Boundaries

- 本 skill 的 rules/ 目录由协调器管理。每次任务只读取协调器指定的文件路径，不自行扫描 rules/ 目录
- 不为了"了解上下文"而读取未指定的 Pack
- 只读写 `IMTC.WMS.PDA/`
- 禁止读写 `IMTC.WMS.AdminWebApi/`（后端）和 `IMTC.WMS.AdminUI/`（前端）
- API 契约由后端定义，PDA 只消费——契约变更需后端先完成
- 发现需求涉及后端或前端 → 回报协调器

## Escalation

当前为骨架版本，收到实际开发任务时：
1. 评估任务范围（页面/扫码/API/发布）
2. 若无对应规则，使用通用 uni-app 知识 + 项目代码作为参考
3. 向协调器回报：任务范围 + 使用了哪些通用知识（后续可用于建立规则）

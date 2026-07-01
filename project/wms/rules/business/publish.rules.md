---
description: "WMS 前后端发布与 Bandizip 打包的安全约束。"
paths:
  - "IMTC.WMS.AdminUI/**"
  - "IMTC.WMS.AdminWebApi/**"
---

# WMS Publish Rules

## Confirmation And Branch Gate

- 发布执行前必须识别当前 Git 分支。
- 默认执行只允许做预检；预检不得执行前端构建、后端 publish 或压缩打包。
- 任何真实发布执行都必须先获得用户明确确认，并在脚本中体现为显式确认参数。
- 默认允许直接发布的分支仅限 `main`、`production`、`stag`，但仍必须具备真实发布确认参数。
- 当前分支不在允许列表时，预检只报告阻塞原因；真实发布必须停止并提示用户确认，确认后才允许同时带真实发布确认参数和非发布分支确认参数继续。
- 禁止在未确认的分支或未确认的正式发布意图下静默执行前后端构建、后端 publish 或压缩打包。

## Publish Scope

- 发布目标固定为当前 WMS workspace 的 Web 管理前端与 Admin WebApi 后端。
- 默认仓库根目录必须从当前执行目录所在 Git root 推导；只有用户显式传参时才允许覆盖。
- 前端发布产物来源固定为当前仓库根目录下的 `IMTC.WMS.AdminUI/dist/*`。
- 后端发布目标目录固定为当前仓库根目录下的 `IMTC.WMS.AdminWebApi\Presentation\Admin.WebApi\bin\Release\net8.0\publish`。
- 后端发布配置固定为 `Release`，目标框架固定为 `net8.0`。
- 后端目标运行时使用 .NET RID `linux-x64`；不要写成无效 RID `linux-64`。
- 后端 publish 前允许清空目标发布目录以等价于“删除现有文件 true”。

## Script Execution

- 优先使用 skill 自带脚本做预检；预检只允许完成分支检查、工作区检查、路径检查、工具检查和执行计划输出。
- 只有用户明确确认真实发布后，才允许使用 skill 自带脚本执行前端构建、后端发布、产物暂存和 Bandizip 打包。
- 脚本执行前不得自动切换分支、stash、reset、merge、rebase、commit 或 push。
- 工作区存在未提交变更时，预检只报告阻塞原因；如确需基于脏工作区真实发布，必须显式确认。
- Bandizip 是指定压缩工具；未找到 Bandizip CLI 时必须停止并提示安装或传入路径，不得静默改用其他压缩工具。
- 产物输出根目录固定为当前用户桌面 `publish` 目录，除非用户显式传参覆盖。

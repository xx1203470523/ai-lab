# wms-dev scripts

本目录存放 `wms-dev` 的可选辅助脚本，例如只读检查、规则引用检查或 Agent packet 辅助生成。

约束：

- 不默认自动执行。
- 运行前必须遵守用户授权、Start Gate、Git 安全和当前任务边界。
- 不修改业务代码，不执行 destructive Git 操作。

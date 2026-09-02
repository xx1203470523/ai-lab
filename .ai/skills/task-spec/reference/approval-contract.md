# Plan Package 审批契约

## AI 操作约定

AI 可以代用户运行本文件中的创建、渲染、导入和读取脚本，也可以使用 `Start-Process` 打开审批页；AI 不得代替用户产生 APPROVED 决策、审批人身份或业务意见。用户只需提供需求描述文件路径，并在页面完成审批；之后把 `approval-input.json` 路径交给 AI 即可。

- 每个 Plan Package revision 目录固定保存 `plan.md`、`plan-package.json`、`approval.html`、`approval.json`；目录名使用 `<YYYYMMDD>-<request-slug>/rNN/`，不覆盖已封存 revision。
- `approval.html` 是本地审批工具：展示分层计划并生成 `approval-input.json`，不直接写 `approval.json`。
- 使用 `approve-plan-package.ps1` 导入审批输入；脚本校验 spec、revision、package hash、Decision 和意见项 ID 后才落盘。
- 状态：`READY_FOR_APPROVAL` → `APPROVED`、`REJECTED` 或 `CHANGES_REQUESTED`。修改意见必须创建新 revision；`APPROVED` 版本不可覆盖。
- `approval.json` 是审批真源；`read-approved-plan.ps1` 是 task-execute 的唯一读取入口，只接受与 `plan-package.json` 的 revision、package hash、spec 身份完全匹配的 `APPROVED` 记录，缺少批准或不一致时以非零码拒绝。
- 执行日志写入独立 execution 文件，不修改批准 package 的 hash。

典型流程：

```powershell
$skill = '$HOME\.claude\skills\task-spec'
& "$skill\scripts\create-plan-package.ps1" -ProposalPath .\proposal.json -SpecPath .\draft.md
# 默认目录为 $skill\<YYYYMMDD>-<request-slug>\rNN\；显式 -OutputRoot 可用于测试或归档
# 打开 revision 目录中的 approval.html，导出 approval-input.json
& "$skill\scripts\approve-plan-package.ps1" -PackagePath "$skill\<YYYYMMDD>-<request-slug>\r01" -Decision CHANGES_REQUESTED -ApprovalInputPath .\approval-input.json
# 根据修改后的 proposal 生成新 revision 后批准
& "$skill\scripts\create-plan-package.ps1" -ProposalPath .\proposal-r02.json
& "$skill\scripts\approve-plan-package.ps1" -PackagePath "$skill\<YYYYMMDD>-<request-slug>\r02" -Decision APPROVED -ApprovalInputPath .\approval-input.json
& "$skill\scripts\read-approved-plan.ps1" -PackagePath "$skill\<YYYYMMDD>-<request-slug>\r02" -AsJson
```

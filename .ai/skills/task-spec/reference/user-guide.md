# Plan Package 操作指南

> 用户只需提供需求描述文件，AI 负责读取文件、生成计划包、运行脚本、打开审批页面、导入审批结果并在明确批准后启动执行。AI 可以代执行脚本，但不能代替用户做最终批准决定。

## 1. 生成计划包

在项目根目录调用 `/task-spec <需求>`。完成代码调查和 12 节需求分析后，task-spec 生成 proposal，并调用脚本创建候选包。也可以手动调用：

```powershell
$skill = "$HOME\.claude\skills\task-spec"
& "$skill\scripts\create-plan-package.ps1" `
  -ProposalPath .\proposal.json `
  -SpecPath $HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\draft-r01.md `
  # 默认输出到 Skill 目录；仅测试或高级归档时显式传 -OutputRoot
```

生成目录类似：

```text
$HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\r01/
├── plan.md
├── plan-package.json
├── approval.html
└── approval.json
```

初始状态是 `READY_FOR_APPROVAL`。这时不能执行。

## 2. 打开审批页面

PowerShell：

```powershell
Start-Process $HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\r01\approval.html
```

或在资源管理器中双击 `approval.html`。页面支持 `file://` 直接打开，不需要启动 Web 服务，也不需要安装依赖。

页面按区块展示：需求摘要、当前行为、目标行为、Facts/Inferences、技术方案、执行包、风险、Acceptance Criteria、必须人工决策和当前 revision/status。点击区块标题可以折叠/展开。

## 3. 提交审批

1. 填写审批人。
2. 如有意见，在“意见关联项”中选择 `D-*`、`K-*`、`AC-*` 或 `pkg-*`。
3. 输入具体意见。
4. 点击“批准”“驳回”或“提交修改意见”。
5. 页面会下载 `approval-input.json`；如果浏览器阻止下载，从页面底部文本框复制 JSON，手动保存为该文件。

页面不会直接修改 `approval.json`。这是正常设计：浏览器的 `file://` 页面没有可靠的任意本地文件写权限。

把下载文件导入审批脚本：

```powershell
$skill = "$HOME\.claude\skills\task-spec"
& "$skill\scripts\approve-plan-package.ps1" `
  -PackagePath $HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\r01 `
  -Decision APPROVED `
  -ApprovalInputPath .\approval-input.json
```

脚本会校验 package ID、Spec ID、revision、SHA-256、阻塞 Decision、`item_decisions`/兼容的 `item_feedback` 和意见项 ID；审批结果真源始终是 revision 目录内的 `approval.json`。

审批必须由人工通过页面导出 `approval-input.json` 驱动。不要根据聊天中的“继续”“可以”或“没有问题”推断批准；AI 不得自行填写审批人、statement 或调用快捷批准路径。仅在人工审批者亲自执行命令时，才可不经过页面：

```powershell
& "$skill\scripts\approve-plan-package.ps1" `
  -PackagePath $HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\r01 `
  -Decision APPROVED `
  -Actor "审批人" `
  -Statement "批准该 revision 用于实施"
```

### 提交修改意见

```powershell
& "$skill\scripts\approve-plan-package.ps1" `
  -PackagePath $HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\r01 `
  -Decision CHANGES_REQUESTED `
  -ApprovalInputPath .\approval-input.json
```

`CHANGES_REQUESTED` 和 `REJECTED` 会封存当前 revision，不能在原 revision 上改完后重新批准。修改 proposal 后重新创建新 revision：

```powershell
& "$skill\scripts\create-plan-package.ps1" `
  -ProposalPath .\proposal-r02.json `
  -SpecPath $HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\draft-r02.md `
  # 默认输出到 Skill 目录；仅测试或高级归档时显式传 -OutputRoot
```

脚本会生成 `r02`，保留 `r01`。

## 4. 检查是否已批准

```powershell
& "$HOME\.claude\skills\task-spec\scripts\read-approved-plan.ps1" `
  -PackagePath $HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\r01 `
  -AsJson
```

只有输出成功且包含 `status: APPROVED` 才可执行。以下情况会失败并拒绝交接：缺少 approval、状态不是 APPROVED、revision 不匹配、package 被修改或 SHA-256 不匹配。

## 5. 执行批准计划

在项目根目录调用：

```text
/task-execute $HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\r01
```

或：

```text
执行已批准计划 $HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\r01
```

`task-execute` 必须先等价调用 `read-approved-plan.ps1`，然后按 `packages` 数组顺序执行。它不会把 Markdown 当作批准依据，也不能执行 DRAFT、CHANGES_REQUESTED 或 REJECTED 版本。

Plan Package 执行状态写在独立的 run 文件，不修改批准的 package：

```text
$HOME\.claude\skills\task-spec\<YYYYMMDD>-<request-slug>\r01/runs/<run-id>/execution.json
```

不会修改批准用的 `plan-package.json`、`plan.md` 或 `approval.json`。

## 6. 常见状态

| 状态 | 含义 | 能否执行 |
|---|---|---|
| `READY_FOR_APPROVAL` | 计划包已生成，等待审批 | 否 |
| `CHANGES_REQUESTED` | 已提交修改意见，需创建新 revision | 否 |
| `REJECTED` | 该 revision 被驳回并封存 | 否 |
| `APPROVED` | 审批记录与 package hash/revision 匹配 | 是 |
| `SUPERSEDED` | 已被更新的批准 revision 替代 | 默认否 |

`APPROVED` 不是聊天中的“看起来可以”或“继续”，必须由审批脚本写入结构化 `approval.json`。

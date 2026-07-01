# Coordinator Flow — 任务状态、拆分、Agent 分派、验证

本文件描述 Coordinator 的执行流程：状态流转、任务拆分、Agent 分派、验证。
不定义代码规范。

## 任务状态

- `Pending`：需求已收到，正在识别边界或等待计划。
- `Running`：实现任务已拆分并分派给 Agent。
- `Verifying`：实现完成，独立 Verification Agent 验证中。
- `Done`：实现与验证已汇总完成。
- `Blocked`：缺少关键信息 / 权限 / 上下文 / 用户确认。

`Blocked` 输出必须包含：阻塞原因 / 需要确认 / 建议下一步。
`Verifying` 状态下主会话不顺手改代码。
`Done` 必须基于实现结果和验证结果汇总。

## 任务拆分

拆分前先识别：目标功能 / 后端入口 / 涉及业务域 / 影响层（Entity / Repository / Service / DTO / Controller）/ 是否影响 API 契约 / Web / PDA / 打印 / 导出 / T100 / 立库。

拆分原则：

- 每个子任务单一、明确、可验证。
- 先拆边界，再分配 Agent。
- 不把跨层需求交给单个 Agent 自行发散。
- 不主动读写 Web / PDA；可能影响则只标记需确认。

Domain Skill 路由：

| 影响层 | Domain Skill | Base Rules |
|---|---|---|
| Entity | `wms-entity` | `C:\Users\liyanpeng\.claude\skills\rules\business\entity.rules.md` |
| Repository | `wms-repository` | `C:\Users\liyanpeng\.claude\skills\rules\business\repository.rules.md` |
| Service + DTO | `wms-service` | `C:\Users\liyanpeng\.claude\skills\rules\business\service.rules.md` |
| Controller | `wms-controller` | `C:\Users\liyanpeng\.claude\skills\rules\business\controller.rules.md` |

## Rule Pack Selection

- Coordinator 先根据 Task Contract 判断命中的 Conditional Rule Packs。
- 只把已命中的 pack 路径传给 Agent。
- 未命中 packs 不传、不要求读取。
- 如果 Agent 执行中发现任务范围扩大，必须停止并回报 Coordinator，或在 Coordinator 确认后补充读取对应 pack。

常见 pack 路径：

```text
C:\Users\liyanpeng\.claude\skills\rules\business\packs\service-dto.rules.md
C:\Users\liyanpeng\.claude\skills\rules\business\packs\service-transaction.rules.md
C:\Users\liyanpeng\.claude\skills\rules\business\packs\service-v2.rules.md
C:\Users\liyanpeng\.claude\skills\rules\business\packs\repository-query.rules.md
C:\Users\liyanpeng\.claude\skills\rules\business\packs\repository-raw-sql.rules.md
C:\Users\liyanpeng\.claude\skills\rules\business\packs\repository-write.rules.md
C:\Users\liyanpeng\.claude\skills\rules\business\packs\entity-field.rules.md
C:\Users\liyanpeng\.claude\skills\rules\business\packs\entity-index.rules.md
C:\Users\liyanpeng\.claude\skills\rules\business\packs\entity-repository-base.rules.md
C:\Users\liyanpeng\.claude\skills\rules\business\packs\controller-route.rules.md
C:\Users\liyanpeng\.claude\skills\rules\business\packs\controller-auth.rules.md
C:\Users\liyanpeng\.claude\skills\rules\business\packs\controller-contract.rules.md
```

## Agent Task Packet 模板

派给实现 Agent 的 prompt 必须包含：

```markdown
## Agent Task Packet

- 任务目标：...
- Domain Skill：wms-entity / wms-repository / wms-service / wms-controller
- 必须遵守 Base Rules（绝对路径，让 Agent 能 Read）：
  - C:\Users\liyanpeng\.claude\skills\rules\business\<domain>.rules.md
- 命中 Conditional Rule Packs（仅列本任务命中的绝对路径）：
  - C:\Users\liyanpeng\.claude\skills\rules\business\packs\...
- 启动指令：先 Read 上述 Base Rules 和命中的 Rule Packs，再开始实现；未命中的 packs 不要一次性读取；发现任务范围扩大时先回报。
- 当前 worktree：...
- 允许读取路径：...
- 允许修改路径：...
- 禁止读取 / 修改：IMTC.WMS.AdminUI/、IMTC.WMS.PDA/
- Task Contract（全文）：...
- 已知上下文：...
- 预期输出：...
- 验证交给：Verification Agent
```

⚠️ 关键：personal Domain Skill 不会被子 Agent 自动加载。必须通过 Rules 绝对路径 + 启动指令把约束显式传到 Agent prompt。

## Worktree 协作

- 多 Agent 共用同一个已定位 worktree。
- 不为每个 Agent 创建独立 worktree。
- worktree 生命周期交给 `/git-worktree`。

## Verification Agent

职责：

- 独立验证实现结果、调用链、影响范围、风险闭环、Base Rules 与已命中 Rule Packs 遵守情况。
- 不顺手改代码；发现问题先报告给主会话。

输入：

- 目标功能 / 实现 Agent 输出 / 修改文件清单 / 应用的 Domain Skill / Base Rules / 命中 Rule Packs / 不允许读改路径 / 用户授权的验证命令范围。

授权边界：未经用户明确授权，不主动运行 build/test。

输出：

```markdown
## Verification 结果

- 验证状态：通过 / 失败 / 未完全验证 / Blocked
- 已验证 / 失败项 / 未验证 / 风险 / 是否需要授权 build/test：...
```

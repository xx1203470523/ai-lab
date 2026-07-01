---
description: "WMS 开发 Start Gate 触发时机、职责边界、阻塞语义和验证基线检查约束。"
---

# Start Gate Rules

本文件只定义 WMS Start Gate 的最终行为约束，不定义 Git 同步、worktree 创建、stash、rebase、提交或验证执行流程。

## 1. Trigger Timing

- 只读分析、需求理解、综合改动范围评估、Task Contract 草案、推荐执行批次和后续候选阶段不得强制触发 `/wms-start-gate`。
- `/wms-start-gate` 只在准备进入写操作前触发。
- 写操作包括新增、修改、重构、生成代码、删除代码、提交前修正、对 Git 可见文件执行 Write/Edit/MultiEdit 等动作。
- 用户明确只要求继续分析、评估、审查或拆分任务时，必须保持只读模式，不得因为未通过 gate 而阻断只读输出。

## 2. Responsibility

- `/wms-start-gate` 只负责确认环境是否已满足写操作前置条件。
- `/wms-start-gate` 只做检查、判断、阻塞和下一步指向；满足条件时仅表示“不阻塞”。
- `/wms-start-gate` 不负责准备环境，不执行同步 main、创建 worktree、切换目录、stash、rebase、merge、commit、push 或清理操作。
- 需要确认远端主线基线时，必须指向 `/git-sync-main`；需要把当前任务分支更新到最新主线时，必须指向 `/git-rebase-main`。
- 需要创建、进入、定位或清理 worktree 时，必须指向 `/git-worktree`。
- 需要处理主工作区临时改动时，必须指向 `/git-stash` 或要求用户明确确认。

## 3. Write Gate Conditions

- 写操作前必须能明确当前 repository / worktree。
- 写操作前必须能明确目标 worktree；不允许在 main 或主工作区直接开始 WMS 业务代码写操作。
- 写操作前必须已有可信的 `origin/main` 基线结论；不得用本地 `main` 替代远端 `origin/main`。
- 写操作前必须说明 dirty 状态；dirty 改动无法确认属于本任务时必须阻塞。
- `/wms-start-gate` 返回 `Blocked` 时，WMS Skill 不得继续写业务代码、分派实现 Agent 或扩大写入范围。

## 4. Verification Baseline Check

- 验证、跑代码、build、test、type check、smoke check 前不重新强制完整 `/wms-start-gate`。
- 验证前只要求确认当前分支或 worktree 是否已有可信的最新 `origin/main` 基线结论。
- 缺少最新 `origin/main` 基线结论时，必须提示先运行 `/git-sync-main`（检查/同步本地 main）或 `/git-rebase-main`（当前任务分支基变），也可让用户明确接受当前基线风险。
- 验证基线检查不得自动执行 `git fetch`、rebase、merge、stash、worktree 创建或切换。

## 5. Reporting

- 只读评估阶段输出必须标记只读模式或说明尚未进入写操作。
- 进入写操作前 gate 未通过时，输出必须包含阻塞原因和下一步建议。
- gate 通过后，下游 WMS Skill 和 Agent 必须使用 gate 认可的同一个目标 worktree。

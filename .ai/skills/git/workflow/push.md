# Git Push 工作流

本工作流只负责**编排**。判定与执行由 `scripts/` 下的脚本完成，
接口与阻断码见 `../reference/scripts/script-contract.md`。

## 1. 前置检查

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\prepush.ps1 `
    -Action check -Target <目标分支> [-AllowFetch]
```

1. 一次拿到分支守卫、目标分支解析、与远端的分叉、本地 `main` 合并提交隐患、工作树状态。
   不要再用零散命令自己拼这些结论。
2. `-Target` 拿不准就先不带，让脚本走推断；报 `target-branch-unresolved` 时
   **停下问用户**要并入 `main` 还是 `production`。后续 fetch、rebase、MR 查重必须用同一个目标分支。
3. 报 `protected-branch` 说明当前就在受保护分支上。此时应引导用户开特性分支，不要原地推送。
4. 读 `data.localTargetMergeCommits`：大于 0 表示本地集成分支有远端没有的合并提交，
   变基基准只能是 `refs/remotes/origin/<target>`，不能用本地分支。
5. 按需读取 `../reference/commit/custom.md`、`../reference/merge-request/custom.md`。
   保持无关 dirty 文件不变。

## 2. 变基

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\prepush.ps1 `
    -Action rebase -Target <目标分支> [-AllowFetch]
```

1. 冲突时脚本会**自动 `rebase --abort` 还原**并返回 `rebase-conflict` 与冲突文件清单。
   把清单报给用户并停下：不自行解决冲突，也不改用 merge 绕过。
2. 成功后看 `behindTargetAfterRebase`（应为 0）确认真的追平了；
   `behindTarget` 是变基前的值，别拿它当结果。
3. 报 `dirty-tree` 时先处理未提交改动（提交或移交），不要 `--force` 或 stash 后硬来。

## 3. 提交

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\commit.ps1 `
    -Action plan -Path <文件1,文件2> -MessageFile <消息文件>
# 确认无误后
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\commit.ps1 `
    -Action commit -Path <文件1,文件2> -MessageFile <消息文件>
```

1. 先 `plan` 再 `commit`：把将暂存的路径与标题展示出来，确认是本次任务范围。
2. **只传本次任务涉及的文件**。脚本会拒绝 `-A`/`.`/`*`/`-u`、通配符、仓库外路径，
   也会拒绝「列了但没有改动」的路径——这几种情况都要回去重新圈定范围，不要绕过。
3. 提交信息写成 UTF-8 文件后传 `-MessageFile`。格式 `<type>(<scope>): <中文简述>`；
   scope 用项目子目录名，type 与 scope 用英文，简述用中文。
4. 消息末尾**不得**有 `Co-Authored-By:` 或 `🤖 Generated with` 行，脚本会硬拦截。
   本仓库历史里有他人留下的署名行，属于他们自己的提交，不要照抄。
5. 标题确实要例外时（比如纯回滚提交），明确说明理由后用 `-AllowNonConventional`。

## 4. 推送

```powershell
git push -u origin <source-branch>
```

- 禁止 `--force`、`--no-verify`、`--no-gpg-sign`。
- 任何一步失败都不要「先推上去再说」；推送是外部可见动作，没把握就停下问用户。
- 被 non-fast-forward 拒绝时，先确认源分支是否有人协作，优先 rebase 而不是 merge，
  且必须用第 2 步的脚本，不要手工 `git pull`。
- 推送成功后报告源分支、提交 hash、推送结果，以及下一步的 MR 结论。

## 5. MR 查重与建议内容

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\mr.ps1 `
    -Action link -Source <source-branch> -Target <target-branch> [-AllowFetch]
```

1. 用**第 1 步解析出的同一个目标分支**，不要换一个。
2. `hasOpenMr` 为真时报告已有 MR 的 Web URL，明确说不要重复创建。
3. 没有既有 MR 时，用 `data.createUrl`、`data.commits`、`data.diffStat`、
   `data.suggestedTitle` 组织建议内容，正文遵循 `../reference/merge-request/custom.md`。
   只写用户需求、commit log、diff 摘要和实际执行过的检查所能证明的事实。
4. `not-gitlab` 或 `mr-lookup-degraded` 时：说明推送已完成、MR 查询被降级或跳过，
   **不得编造 URL**，也不要换成 `gh` 去猜。
5. **本工作流到此结束**。不得调用 `glab mr create`、更新 MR、分配 reviewer、
   加 label 或改 milestone——包括用户只是说「顺便把 MR 也建了」时：
   那是另一个需要用户显式请求并确认的动作，不在本工作流范围内。

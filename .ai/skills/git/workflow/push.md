# Git Push

## 1. 前置检查

### 仓库与分支

1. 确认当前目录位于 Git 仓库中。
2. 检查 `git status`，识别已修改和未跟踪文件。
3. 确认 `origin` 可访问。
4. 当前分支为 `main`、`master`、`production` 或 `staging` 时拒绝操作。
5. 在变基前解析唯一的目标/基准分支，优先级如下：
   - 用户明确指定的目标分支；
   - 仓库文档中的 MR 或分支规范；
   - Git 或托管工具报告的远端默认分支。
6. 如果无法无猜测地确定目标分支，停止并询问用户。fetch、rebase、MR 查重和创建链接必须使用同一个目标分支。

### 提交范围与本地规范

- 推送前读取 `../reference/push/push.md`。
- 仓库存在自定义提交规范时，读取 `../reference/commit/custom.md`。
- 准备 MR 标题或正文时，读取 `../reference/merge-request/custom.md`。
- 保持无关 dirty 文件不变，不将其纳入提交。

## 2. 变基检查

提交前，基于已解析的远端目标分支执行 fetch 和 rebase：

```text
git fetch origin <target-branch>
git rebase origin/<target-branch>
```

如果发生冲突，执行 `git rebase --abort`，报告冲突文件并停止。不要强行解决，也不要用 merge 作为捷径。

## 3. 提交

### 范围控制

只提交当前任务相关变更。必须逐文件暂存，禁止使用 `git add -A` 或 `git add .`。

### 提交信息

遵循已加载的仓库/项目提交规范。提交信息末尾不得包含 `Co-Authored-By:` 或 `🤖 Generated with` 行。

## 4. 推送

```text
git push -u origin <source-branch>
```

推送成功后报告源分支、提交 hash、推送结果以及 MR 查重/链接结果。

## 5. MR 查重与建议内容

1. 将当前分支作为 `source-branch`，并使用之前解析出的唯一目标分支。
2. 同时按 source branch 和 target branch 查找已有 MR：

```text
glab mr list --source-branch <source-branch> --target-branch <target-branch> --output json
```

3. 如果存在匹配 MR，报告已有 Web URL，不创建或更新 MR。
4. 如果不存在匹配 MR，通过 `glab repo view --output json` 获取仓库 `web_url`，构建创建链接时对两个分支名进行 URI 编码：

```text
https://<host>/<project>/-/merge_requests/new?merge_request[source_branch]=<encoded-source>&merge_request[target_branch]=<encoded-target>
```

5. 准备但不提交 MR 建议：
   - 标题优先使用当前任务的 commit subject；
   - 正文遵循 `../reference/merge-request/custom.md` 及更严格的仓库/项目格式；
   - 只包含用户需求、任务日志、目标到源分支 commit log、diff 摘要和实际执行检查能够证明的事实；
   - 不附加 Claude 署名行。

6. 普通 Push workflow 在报告已有 MR 或创建链接及建议内容后结束。不得调用 `glab mr create`、更新 MR、分配 reviewer、添加 label 或修改 milestone。

## 6. 异常处理

- 必需操作失败时立即停止，并报告具体原因。
- push 因 non-fast-forward 被拒时，检查源分支是否有人协作，优先 rebase 而非 merge。
- GitLab CLI 不可用或远端不是 GitLab 时，报告推送已完成但 MR 查重/链接准备被跳过或降级；不得编造 URL。

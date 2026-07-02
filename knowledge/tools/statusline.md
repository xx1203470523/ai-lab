# StatusLine Hook

> 最后更新: 2026-07-02

## 配置位置

- 脚本：`~/.claude/statusline.ps1`
- Hook：`~/.claude/settings.json` → `statusLine`
- 项目模板：`ai-lab/.ai/tools/statusline/`

## 显示格式

```
<Git仓库名[/相对路径]> [<模型名>] <分支名>
```

## PowerShell 注意事项

- Claude Code 传 JSON 到 stdin，用 `$input | Out-String | ConvertFrom-Json` 解析
- `$inputJson.workspace.current_dir` 获取当前工作目录
- `$inputJson.model.display_name` 获取模型名
- `git -C $cwd` 在指定目录执行 git 命令

## 不消耗 Token

statusLine hook 是终端本地渲染，不走 API，不计 token。

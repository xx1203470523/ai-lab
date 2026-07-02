# StatusLine Hook 配置

在状态栏显示当前目录、模型和 Git 分支。

## Hook 配置（settings.json）

```json
"statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -File C:/Users/liyanpeng/.claude/statusline.ps1",
    "refreshInterval": 5
}
```

## 部署

1. 将 `statusline.ps1` 复制到 `~/.claude/` 目录
2. 在 `~/.claude/settings.json` 中添加上述 hook 配置
3. `command` 路径按实际存放位置调整

## 效果

状态栏显示格式：`<目录名> [<模型名>] <分支名>`

例如：`ai-lab [deepseek-v4-pro] chore/prompt-engineering-convergence`

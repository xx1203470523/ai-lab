# Git Commit 规范

**执行方式**：走 `../scripts/commit.ps1` 的 `plan` 与 `commit` 两个动作。
阻断条件与错误码见 `../reference/scripts/script-contract.md`。

## 提交信息格式 （默认）

```
<type>(<scope>): <中文简述>

- <子项目>: 改动项
- 改动项（无归属不加前缀）
```

- scope = 项目子目录名
- type + scope: 英文；简述: 中文

## 项目特定提交样式 （优先）

WMS 项目按 `../reference/commit/custom.md`。

## 提交尾部禁止事项

- 禁止在提交信息末尾追加 `Co-Authored-By:` 行
- 禁止追加 `🤖 Generated with` 之类的生成器署名行
- 禁止用 here-string 向原生命令传多行提交信息（PowerShell 5.1 下会被拆断），
  一律写成 UTF-8 消息文件用 `-MessageFile` 传入

## 提交内容

- 只提交本次任务范围内的文件，逐文件显式列出
- 提交范围外的 `*.cs`、`*.vue` 等代码文件需先确认；日志类（`*.md`、`*.sql`）不用

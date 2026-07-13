# PowerShell 脚本范式

> 最后更新: 2026-07-02

## 编码

- Windows PowerShell 5.1 默认 UTF-16 LE with BOM
- 中文内容用 UTF-8 with BOM 或通过 scriptblock 执行避免乱码
- 统一启动脚本模式：读入 UTF-8 脚本 → scriptblock 执行

## 路径

- 配置中使用正斜杠 `/` 或双反斜杠 `\\`
- 个人配置中避免硬编码用户目录，使用 `~/` 泛化路径

## 注意事项

- `$input` 是 PowerShell 自动变量，管道传入
- `ConvertFrom-Json` 返回 PSCustomObject，非 hashtable
- `2>$null` 抑制 stderr

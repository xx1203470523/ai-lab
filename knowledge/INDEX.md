# 知识库索引

> 个人提示词工程知识沉淀。Skill 触发后先读本索引，命中则按路径加载，miss 则跳过。

## tools/ — 工具操作知识

| 文件 | 覆盖内容 |
|------|----------|
| [git.md](tools/git.md) | 本机 Git 环境、GitLab/glab、个人分支命名偏好 |
| [statusline.md](tools/statusline.md) | Claude Code statusline hook 配置、PowerShell 踩坑 |
| [hooks.md](tools/hooks.md) | Claude Code hook 类型、事件、常用 pattern |
| [scripts.md](tools/scripts.md) | PowerShell 脚本范式、编码问题、路径处理 |

## patterns/ — 方法论

| 文件 | 覆盖内容 |
|------|----------|
| [skill-design.md](patterns/skill-design.md) | 渐进式披露、按需加载、触发词设计 |
| [prompt-eng.md](patterns/prompt-eng.md) | 提示词技巧、token 优化策略 |
| [troubleshooting.md](patterns/troubleshooting.md) | Claude Code 常见问题与解法 |

## domains/ — 业务上下文

| 文件 | 覆盖内容 |
|------|----------|
| [trade.md](domains/trade.md) | 炒股项目：Python 环境、数据源、飞书通知 |
| [wms.md](domains/wms.md) | WMS 项目：后端架构、发布流程、环境配置 |

## 使用约定

- Skill 中写：`遇到 X 类问题，先 Grep knowledge/ 检索关键词，命中则加载对应文件`
- 每个知识文件顶部标 `> 最后更新: YYYY-MM-DD`
- 新增文件后更新本索引

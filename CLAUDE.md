# AI-Lab 提示词工程实验室

> 这是 Claude Code 提示词工程资产的管理仓库，**不是软件项目**。本仓库只维护 Skill、Tool、Knowledge 等提示词工程产物。

## 目录结构

```
ai-lab/
├── .ai/                    # 通用个人资产（跨项目复用）
│   ├── skills/             #   通用技能（git、skill-gen 等）
│   ├── tools/              #   通用工具（statusline 等）
│   ├── bootstrap/          #   部署配置（同步到 ~/.claude/）
│   ├── adapters/           #   适配器（预留）
│   ├── agents/             #   自定义 Agent 定义（预留）
│   ├── hook/               #   Hook 脚本（预留）
│   ├── rules/              #   通用规则（预留）
│   ├── template/           #   模板（预留）
│   └── workflows/          #   通用工作流（预留）
│
├── project/                # 项目特定资产
│   ├── wms/skills/         #   WMS 项目技能
│   ├── wms/rules/          #   WMS 项目规则
│   ├── trade/              #   炒股项目（待建设）
│   └── voxcpm/             #   VoxCPM 项目（待建设）
│
├── knowledge/              # 共享知识库（skill 按需检索）
│   ├── INDEX.md            #   索引入口
│   ├── tools/              #   工具操作知识
│   ├── patterns/           #   方法论
│   └── domains/            #   业务上下文
│
├── learn/                  # 学习日志与规划
├── registry/               # 注册中心（预留）
└── .claude/                # 本项目 Claude Code 配置
    └── settings.local.json
```

## 核心约定

- **不写 AI 知道的内容**：Skill 只写项目特定约束和个人偏好，不写通用教程
- **渐进式披露**：SKILL.md → workflow/rules → reference，用到才加载
- **路径引用**：skill 中使用相对路径引用同目录资源；引用 knowledge/ 使用 `ai-lab://knowledge/...`
- **部署**：通过 bootstrap 将 `.ai/skills/` 和 `project/*/skills/` 同步到 `~/.claude/skills/`

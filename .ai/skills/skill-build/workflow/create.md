# 新建 Skill 流程

### 1.需求理解

提取：

- 输入是什么
- 输出是什么
- 核心操作步骤是什么

### 2.流程设计

将需求拆解为可执行步骤：

要求：

- 每一步必须可执行
- 不允许抽象描述
- 不允许业务推理

### 3.生成方案（1-2 个即可）

每个方案必须包含：

- 执行流程
- 优缺点
- 推荐方案（必须标注一个）

### 4.确认后生成文件

生成：

**SKILL.md**（必须）：

- name
- description
- execution flow（核心）
- input / output
- constraints

要求：极简、结构化、不写解释。

**examples.md**（必须）：
至少 3 个使用例子：

- 正常情况
- 边界情况
- 错误/异常情况

### 5.验证

```bash
find .ai/core/skills/<name> -type f
```

```powershell
.ai/core/skills/sync.ps1 install   # 创建 junction 到 ~/.claude/skills/
```

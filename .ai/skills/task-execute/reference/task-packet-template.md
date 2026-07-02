# Agent Task Packet 模板

分派 Agent 时使用的标准 prompt。将 `{{}}` 占位符替换为 plan 中的实际值。

```markdown
## Agent Task Packet

- 任务目标：{{package.name}}
- 当前包 ID：{{package.id}}
- 终端技能：{{#if package.skill}}{{package.skill}}{{else}}无（通用任务）{{/if}}
- 所属项目：{{plan.project}}
- 当前工作目录：{{project_root}}（不创建 worktree）

### 启动方式

{{#if package.skill}}
执行前，先通过 Skill 工具调用终端技能加载其规则和约定：

```
Skill({skill: "{{package.skill}}"})
```

这会加载该技能的 SKILL.md 及其 Base Rules。之后按本 Task Packet 中的 manifest 补充加载命中 Packs。
{{else}}
此包无指定终端技能，直接按 Task Packet 中的 manifest 加载规则和知识文件建立上下文。
{{/if}}

### 规则与知识（绝对路径，仅读取以下文件）

- 知识文件：
{{#each manifest.knowledge}}
  - {{absolute_path}}
{{/each}}

- Base Rules：
{{#each manifest.rules}}
  - {{absolute_path}}
{{/each}}

- 命中 Packs（仅这些，不要读其他）：
{{#each manifest.packs}}
  - {{absolute_path}}
{{/each}}

- 模式参考（如有）：
{{#each manifest.patterns}}
  - {{absolute_path}}
{{/each}}

### 前序包输出（如有依赖）

{{#if depends_on_outputs}}
{{depends_on_outputs}}
{{else}}
无依赖，此为第一个包。
{{/if}}

### 边界

- 允许读取：
{{#each boundaries.allow_read}}
  - {{this}}
{{/each}}

- 允许修改：
{{#each boundaries.allow_write}}
  - {{this}}
{{/each}}

- 禁止读取/修改：
{{#each boundaries.forbid}}
  - {{this}}
{{/each}}

### Task Contract

- In Scope：{{contract.in_scope}}
- Out of Scope：{{contract.out_of_scope}}
- 预计文件数：{{contract.expected_files}}
- 停止条件：{{contract.stop_condition}}

### 启动指令

1. 先 Read manifest 中的所有文件（知识、Base Rules、命中 Packs），建立完整的上下文
2. 严格按 Base Rules 和命中 Packs 约束实现，不要偏离规范
3. 信息不足时先尝试在允许范围内扩散检索（限 3 次，同一文件只计 1 次）
4. 第 4 次扩散检索 → 立即停止，输出：
   ```
   [ESCALATE] 扩散检索已达 3 次上限
   已检索文件：
     - <文件路径>：<检索原因>
   缺失信息：<描述>
   建议：<是否需要继续>
   状态：等待主会话确认
   ```
5. 发现任务范围扩大到 Out of Scope → 立即停止，输出：
   ```
   [ESCALATE] 任务范围扩大
   原始范围：{{contract.in_scope}}
   发现扩大：<具体描述>
   建议：<是否应修正计划>
   状态：等待主会话确认
   ```
6. 未命中的 packs/knowledge 文件不要读取——它们不适用于本包
7. 完成实现后输出：
   ```
   ## 完成报告
   - 包 ID：{{package.id}}
   - 修改文件：
     - <文件路径>：<变更说明>
   - 未修改但需关注：
     - <文件路径>：<原因>
   - 残余风险：（如有）
   ```
```

---
name: skill-gen
description: "设计和演进 Claude Code Skill。触发：新建技能、创建技能、写一个技能、设计技能、修改技能、优化技能、重构技能、生成skill、skill设计、梳理skill设计、skill误触发排查、create skill、design skill、refactor skill、/skill-gen。先用 DESIGN.md 理清目标、场景和设计并与用户确认，再生成或修改技能文件。"
---

# Skill Gen — 技能设计与演进

生成只是最后一公里。默认顺序：理解问题 → 形成设计 → 验证设计 → 实现 → 复盘。目标是让模糊想法变成可执行、可验证、可迭代的技能，而不是产出一份漂亮的 SKILL.md。

## 硬性约束

1. 需求没理清前，不创建或修改实现文件（SKILL.md、rules/、workflow/、reference/、scripts/、templates/）。DESIGN.md 是设计工作记录，可以在发现阶段创建或更新。
2. 用户没有明确确认设计前，不覆盖已有实现文件。
3. 新建、重构或行为变更必须有 `<skill>/DESIGN.md`；纯文案或 description 微调不强制新建，但有设计记录就同步更新。
4. 设计记录用四种标记区分内容来源：`[已确认]`、`[建议]`、`[待确认]`、`[推断]`。未确认内容不得写成结论。
5. 没有实际运行过的验证写"未实测/待验证"，不得标 Stable。
6. 简单低风险技能可以走快速模式，但不能跳过 DESIGN.md 和未确认标记。

## 五阶段

| 阶段 | 目标 | 产出 | 详情 |
| --- | --- | --- | --- |
| 1 Discovery | 弄清要改善的工作、场景和边界，判断是否值得建 | DESIGN.md Part 1 | `./workflow/discovery.md` |
| 2 Design | 把想法变成结构化设计 | Part 2 | `./workflow/design.md` |
| 3 Design Validation | 用典型场景检验设计，暴露遗漏 | Part 3.2 场景 | `./workflow/design.md` |
| 4 Implementation | 设计确认后生成或改造技能 | 技能文件 + Part 3.1 | `./workflow/implement-review.md` |
| 5 Review & Iteration | 对照设计复盘实际行为，修正设计或实现 | Part 3 更新 | `./workflow/implement-review.md` |

阶段可精简：减少问题、场景和章节数量，但不能跳过产出和门禁。只有快速模式允许合并阶段 1-4。阶段 2 和 3 可以反复迭代。

## 入口分流

| 用户情况 | 起点 | 先做什么 |
| --- | --- | --- |
| 只有模糊想法或目标 | 1 | 不写实现文件；一次问 1-3 个最关键的问题；可在阶段 1 末尾建 DESIGN.md |
| 设计已经比较明确 | 2 | 快速补齐 Part 1，直接进入 Part 2 |
| 优化已有技能 | 诊断 → 2 → 3 → 4 | 先确认目标技能并读实现；没有 DESIGN.md 就反推基线，全部标 `[推断]`；区分实现问题与设计问题，见 `./workflow/implement-review.md` |
| 用户要求重大变更 | 2 | 先做影响分析，再改设计，设计确认后才改文件 |
| 简单低风险技能 | 快速模式 | 直接出初稿 + DESIGN.md，未确认项标 `[待确认]`；业务型、重构、涉及脚本或外部系统不适用 |

优化已有技能不从阶段 5 开始：阶段 5 只用于实现后的效果复盘。

## 设计记录

- 每个技能一份：`<skill-name>/DESIGN.md`，模板 `./templates/DESIGN.md.tmpl`。
- 讨论过程留在对话里，结论写进 DESIGN.md；不要把设计推导塞进 SKILL.md。
- 状态流转：Draft → Reviewing → Approved → Implementing → Validating → Stable；停用为 Deprecated。重大变更可从任意状态回到 Reviewing。
- Approved 只表示用户同意设计，不表示已验证。单次成功测试不足以标 Stable。
- 若本目录不是 Git 仓库，重要版本变化必须写入 Part 3 的 Iteration History。

## 技能分类

| 类型 | 特征 | 命名 |
| --- | --- | --- |
| 工具型 | 确定性操作、跨项目复用、无业务规则 | `<name>` |
| 业务型 | 领域知识、业务规则、协调多个技能 | `<business>-<module>` |

不要求严格二选一。按需补充属性：是否多步骤、是否需要脚本自动化、是否依赖业务知识、是否协调其他 Skill。命名见 `./reference/naming.md`。

## 生成底线

创建和优化时读 `./workflow/implement-review.md`。四条底线：

1. 只保留能影响 AI 行为的内容：通用教程不写；工作流步骤、项目约束、业务规则、输出格式、执行边界、决策标准要写。
2. 渐进式披露：SKILL.md 放核心规则、路由和兜底；细节按需拆到 workflow/rules/reference。
3. 拆分按职责判断：被复用、需独立加载、有独立维护周期或版本管理才拆，不按行数机械拆分。
4. 不制造空文件或空目录；目录按实际复杂度创建。

## 未匹配意图

用户请求不属于上述场景时，直接用通用知识处理，不要套用设计流程。

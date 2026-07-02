# Skill Rules

## 定位

- 本文件是 Skill 体系的最小默认规则，只保留所有场景都必须知道的底线。
- 模式、类型、文件边界、加载、污染、知识边界等细则放在 `rules/packs/skill-*.rules.md`，按命中场景读取。
- `SKILL.md` 可用 `@../rules/skill.rules.md` 默认加载本文件；workflows、packs、references、EXAMPLES、scripts 不得用 `@` 默认加载。

## 生命周期底线

- Create / Refactor / Review 前必须先判断目标是否可由现有 Skill 承载。
- 扩展优先级：扩展现有 Skill > 新增 workflow > 新增 rule pack > 新增 script > 新增 reference > 新建 Skill。
- 仅当职责边界、生命周期、触发场景均独立，且预计持续扩展时，才创建新 Skill。
- 禁止为了单一功能、一次性任务、单个示例、单个脚本或单个参考资料创建独立 Skill。
- Skill 数量控制优先级：合并 > 模块化 > 新建。

## 反过度抽象

- 禁止为了未来可能存在的需求进行抽象。
- 禁止为了统一而统一，禁止为了复用而复用。
- 只有已出现重复、维护成本或职责冲突时，才允许新增层级、拆分或抽象。
- 新增 Skill / workflow / rule pack / script / reference 前，必须说明它解决的已发生问题。

## Skill 类型

- Business Skill：依赖业务知识、项目规范或项目私有流程。
- Tool Skill：围绕跨项目工具流程、参数收集、命令编排或脚本化操作。
- Governance Skill：治理 Skill / Rules / workflows / references / scripts / EXAMPLES 的结构、生命周期和审查边界。
- 类型判断必须先于目录结构设计和文件生成。

## 最小职责分层

| 载体 | 职责 |
|---|---|
| `SKILL.md` | 入口、触发、职责、路由、按需加载索引 |
| Base Rules | 所有场景默认需要的稳定强约束 |
| Conditional Rule Packs | 特定模式、类型或边界命中后的强约束 |
| workflows | 流程、状态流转、任务拆分、验证顺序 |
| `EXAMPLES.md` | 示例输入、示例输出、边界案例 |
| references | 背景、历史决策、迁移资料 |
| scripts | 固定、可参数化、可重复执行且经授权的自动化逻辑 |

## 引用与加载底线

- Skill → Base Rules：可用 `@../rules/*.rules.md`。
- Skill → workflows / packs / references / EXAMPLES / scripts：只用普通相对路径列出，不用 `@`。
- Conditional Rule Packs 命中后读取，未命中不得默认加载。
- workflows 按任务模式或决策分支读取。
- references / EXAMPLES / scripts 不默认读取。
- scripts 只有用户明确授权后才可执行。
- 禁止引用不存在的文件。

## 生成安全底线

- 默认写用户级 personal skill。
- 修改前必须明确目标路径和归属 Skill。
- 禁止生成业务代码，除非具体业务 Skill 明确授权且用户确认。
- 禁止未确认删除已有内容。
- README 只做索引，不承载规则正文。

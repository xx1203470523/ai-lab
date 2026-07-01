---
description: "Skill 体系知识记录边界与通用知识过滤规则。"
---

# Skill Knowledge Boundary Rules

## 触发

- 任务涉及写入 rules、references、EXAMPLES 或业务规范。
- 需要判断内容是通用知识、项目私有知识还是辅助资料。

## 禁止记录

- 教程、概念解释、百科内容。
- AI 已知的通用知识。
- Git 基础知识。
- 通用开发知识，例如设计模式、SOLID、DDD 概念。
- .NET / Vue / SQL / uni-app 等基础知识。

## 优先保留

- 项目规范。
- 团队约定。
- 私有流程。
- 特殊约束。
- AI 无法从代码、配置、README 或 git 历史自动推导的信息。

## 写入前判断

1. AI 是否已经知道这个知识？是则不写。
2. 是否可以从项目代码直接推导？是则不写。
3. 是否可以从 README 或配置文件直接读取？是则不写。
4. 是否属于本项目或用户个人流程特有的约定或约束？是则可以写。

## 位置选择

- 强约束进入 Rules / Packs。
- 历史背景和辅助资料进入 references。
- 示例进入 `EXAMPLES.md`。
- 通用知识不进入 Skill 体系。

---
description: "Business Skill 的业务绑定、项目私有规范和领域职责边界规则。"
---

# Skill Type Business Rules

## 触发

- 生命周期判断后目标为 Business Skill。
- 目标依赖具体项目、业务域、业务流程或团队私有规范。
- 任务涉及 WMS domain skill、Entity、Repository、Service、Controller 等业务相关 Skill。

## 职责边界

- Business Skill 可以承载项目规范、团队约定、私有流程和特殊业务约束。
- Business Skill 不承载通用编程知识、框架基础教程或 AI 已知知识。
- Business Skill 应优先路由到已有领域 Skill，而不是复制领域规则。
- 治理类规则不应混入 Business Skill 的业务实现流程。

## 与项目绑定

- 与具体项目强绑定的规则应写清目标项目、路径或业务域。
- 跨项目通用工具流程不应放入 Business Skill。
- 可从代码、配置、README 或 git 历史稳定推导的信息，不应重复写入 Skill。

## 与 Domain Skill 的关系

- 已有更具体 Domain Skill 时，Business Skill 应负责路由或组合，不替代其规则正文。
- 新增业务规则前先判断是否属于现有 Domain Skill 的职责范围。
- 业务流程进入 workflow；业务强约束进入 rules / packs；业务示例进入 EXAMPLES 或 references。

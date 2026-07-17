# AI-Lab

个人 AI 工程化资产库。通过真实 WMS 业务持续验证和迭代。

---

## 目录结构

```
ai-lab/
├── .ai/                   # 跨项目通用：Skill、Rules、Scripts、Protocols
│   ├── skills/            #   git、skill-gen、task-plan、task-execute
│   ├── rules/             #   git 等通用约束
│   ├── protocols/         #   Agent Task Packet、Context 协议
│   ├── scripts/           #   search-knowledge.ps1 等
│   └── adapters/          #   工具适配（待建设）
│
├── project/               # 项目级资产（业务相关）
│   └── wms/               #   WMS 项目的 Skills、Knowledge
│       ├── skills/        #     wms-dev、wms-backend-dev、dbsql 等
│       └── knowledge/     #     领域知识（report-development 等）
│
└── registry/              # 项目注册（待建设）
```

---

## 核心概念

| 概念        | 职责                       | 示例                           |
| ----------- | -------------------------- | ------------------------------ |
| **Rules**   | 强制约束，决定"能不能做"   | 禁止全量 ToList、禁止全模糊查询 |
| **Skills**  | 行为流程，决定"怎么做"     | wms-dev → 路由 → wms-backend-dev |
| **Knowledge** | 实践经验，提供"参考方案" | report-development.md 优化模式  |
| **Workflows** | 多步骤流程，编排步骤与状态 | report-optimize.md              |

**Rules / Skills / Knowledge 三者独立，不互相替代。**

---

## 设计原则

### 1. 业务优先于工程化

WMS 功能开发优先。AI-Lab 优化来自实际痛点，不来自设计。

连续遇到 3 次同样问题 → 记录 → 抽象。

### 2. 项目资产归属项目

```
.ai/rules/git/          → 跨项目通用
project/wms/knowledge/   → WMS 领域知识
```

禁止把业务规则塞进 `.ai/` 通用层。

### 3. Context First

Agent 不是自动执行，而是隔离上下文、限制职责范围。

```
Agent = Context Profile + Write Boundary
```

### 4. 碎片化但不过度

文件按职责拆分，一次任务只读 2-3 个相关文件：

```
Service:   {Name}Service`{Purpose}.cs`       // Query, Export, Confirm, Print
DTO:       {Name}Dto`{Purpose}.cs`            // Query, Export, PagedQuery
```

### 5. 先人工执行，后自动化

执行 ≥ 5 次且步骤稳定 → 考虑抽象为 Skill / Script。

---

## 当前重点

- WMS 后端开发体系（wms-dev → wms-backend-dev + Rules + Knowledge）
- 报表优化方法论（report-development.md + report-optimize workflow）
- 知识沉淀（Knowledge Discovery → search-knowledge.ps1）
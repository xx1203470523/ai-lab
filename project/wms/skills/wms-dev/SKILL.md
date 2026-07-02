---
name: wms-dev
description: "WMS 开发唯一入口：根据任务复杂度路由到 wms-backend-dev / wms-frontend-dev / wms-pda-dev 终端技能，复杂任务按 P0/P1/P2 拆分并编排多 Agent 协作。"
shell: powershell
version: 4.0.0
---

# WMS Dev — 开发协调器

必须遵守：@./rules/dev.rules.md

## Trigger

- 新增或修改 WMS 任何端（后端/前端/PDA）功能
- 跨端联动或跨层联动
- 用户未指定终端技能，需要协调器分析并路由

## 执行流程

### Step 0: 复杂度评估

先读取 `./workflow/complexity-decision.md` 判断任务复杂度。

**Simple** — 满足全部：
- ≤ 2 文件 + 单层 + 无契约影响 + 无跨端影响 + 无风险标志

→ 协调器直接处理，调用对应终端技能 inline，不启 Agent。
→ Mini Task Contract（In Scope / Out of Scope / Verify）。
→ 加载：终端 SKILL.md + 目标 Base Rules + 命中的 Condition Pack。

**Complex** — 任一命中：
- > 2 文件 / 多层 / 契约变化 / 跨端 / 事务库存T100立库 / 新功能

→ 读 `./workflow/multi-agent-planning.md`，按 P0/P1/P2 拆批，Agent 编排。

### Step 1: Start Gate

写操作前检查：
- 当前工作目录是否为 WMS 项目根目录
- 分支是否基于最新 main
- 详见 `@../rules/start-gate.rules.md`

### Step 2: 路由到终端技能

| 影响端 | 终端 Skill | 项目路径 |
|--------|-----------|----------|
| 后端 .NET C# | `wms-backend-dev` | `IMTC.WMS.AdminWebApi/` |
| 前端 AdminUI | `wms-frontend-dev` | `IMTC.WMS.AdminUI/` |
| PDA 手持端 | `wms-pda-dev` | `IMTC.WMS.PDA/` |

- Simple 任务只路由一个终端
- Complex 跨端任务：识别涉及终端，逐个拆批

### Step 3: P0/P1/P2 分批（仅 Complex）

| 批次 | 后端 | 策略 |
|------|------|------|
| P0 | Entity + Repository | 数据结构先行 |
| P1 | Service + DTO | 业务逻辑居中 |
| P2 | Controller + API | 对外接口收尾 |

- P0 验证通过 → 启 P1 → P1 验证通过 → 启 P2
- 每批一个 Agent，不并行
- 前端/PDA 的批次粒度由对应终端技能内部定义（目前骨架，后续补充）

### Step 4: Agent 分派

见 `./workflow/multi-agent-planning.md`。Agent 必须接收：

- Task Contract（In Scope / Out of Scope / Verify）
- 终端 Skill 名
- Base Rules 绝对路径
- 命中 Condition Packs 绝对路径
- 允许/禁止读写路径
- 启动指令：先 Read Rules 再实现，未命中 Pack 不读，范围扩大先回报

**约束**：
- 不创建 worktree，所有 Agent 在同一工作目录操作
- Agent 严格顺序执行，不并行
- Verification Agent 独立运行，只读不改

## Task Status

- `Pending` → `Running` → `Verifying` → `Done`
- `Blocked`：阻塞原因 + 需确认内容 + 建议下一步

## Output Format

### Lightweight（Simple）

```markdown
## WMS Dev（Lightweight）
- 状态 / 目标 / Terminal Skill / Mini Task Contract / 验证
```

### Full（Complex）

```markdown
## WMS Dev 任务状态
- 当前状态 / 目标 / Start Gate / 当前批次

## 复杂度评估
- 文件数 / 层数 / 契约影响 / 跨端影响 / 风险 / 结论

## P0/P1/P2 分批计划
| 批次 | 终端 | Domain | 文件 | Agent |

## Task Contract
- 本次批次 / In Scope / Out of Scope / 禁止路径

## Agent 编排
| 批次 | Agent | 状态 | 结果 |

## 验证与清理
- Verification Agent / 已验证 / 残余风险

## 后续候选
- 不在本次处理的候选项

## Blocked 信息
- 阻塞原因 / 建议下一步
```

## Boundaries

- 不直接实现代码，不复制终端 Skill 内部规则正文
- 不复制 `/wms-start-gate`、`/git` 等独立技能流程
- 协调器只负责分析、路由、编排、验证——实现交给终端 Skill + Agent

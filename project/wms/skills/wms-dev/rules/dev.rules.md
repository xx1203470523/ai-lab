# WMS Dev 协调器规则

本文件是协调器自身的 Base Rules，定义所有协调场景必须遵守的最小强约束。
终端路由、复杂度评估、Agent 编排详见 SKILL.md 和 `workflow/` 目录。

## 1. Start Gate

- 写操作前确认工作目录 + 分支状态
- 详见 `../rules/start-gate.rules.md`
- 只读分析/stage 评估阶段不强求 gate

## 2. Scope Boundaries

- 后端默认边界 `IMTC.WMS.AdminWebApi/`
- 禁止主动读取或修改 `IMTC.WMS.AdminUI/`（非前端任务）
- 禁止主动读取或修改 `IMTC.WMS.PDA/`（非 PDA 任务）
- 契约变化可能影响其他端时，提示影响范围，不自行越界

## 3. Task Status & Blocked

- `Pending` → `Running` → `Verifying` → `Done`
- `Blocked`：阻塞原因 + 需确认内容 + 建议下一步
- Blocked 状态下禁止猜测实现或扩大范围
- 实现过程中范围扩大 → 立即停止 → 重新评估 → 可能升级

## 4. Verification

- 必须发起独立验证阶段
- 验证内容：规则合规、调用链闭合、未引用文件、无用代码
- 大范围清理须单独确认
- Verification Agent 只读不改

## 5. Anti-Patterns

- 禁止批量编辑：每次只修改任务明确指定的文件和行，不顺手格式化、重命名或修改无关代码
- 禁止猜测实现：不确定的业务规则、字段语义、历史兼容原因必须回报确认，禁止自行推断
- 禁止跨层越界：后端任务不碰前端/PDA 路径，反之亦然
- 禁止规则蔓延：Agent 只读协调器指定的规则文件，不自行扫描 rules/ 目录

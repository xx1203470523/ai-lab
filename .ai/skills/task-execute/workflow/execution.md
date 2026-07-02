# 执行流程

加载计划文件后，按以下步骤顺序执行所有包。

## Step 0: 选择与加载计划

### 0a. 计划选择

用户可能：
- 明确指定 plan 文件路径 → 直接加载
- 说"执行计划"但未指定 → 列出可选计划
- 说"继续执行"/"续跑" → 优先找 `running` 状态的计划

**列出可选计划时**：
1. 列出 `plans/` 下所有 `.md` 文件
2. 读取每个文件的 YAML frontmatter（仅解析 status 和 description，不读全文）
3. 按状态分组展示：

```
## 可执行计划

### 待执行 (pending)
- `task-20260703-1430-wms-inbound.md` — 实现 WMS 入库单功能（3 packages）
- `task-20260703-1600-trade-fix.md` — 修复炒股连接超时（1 package，Simple）

### 可续跑 (running)
- `task-20260702-0900-wms-stock.md` — 库存盘点功能（pkg-01 done, pkg-02 pending）

### 已完成 (done)
- `task-20260701-1000-wms-outbound.md` — 出库单查询（3/3 done）
```

4. 让用户选择要执行的计划

### 0b. 加载与验证

1. 完整读取选定的 plan 文件
2. 解析 YAML frontmatter
3. 验证结构完整性：
   - plan_id、project、packages 必须存在
   - 每个 package 必须有 id、skill、manifest、boundaries、contract
   - depends_on 引用的包 ID 必须存在
4. 验证失败 → 告知具体缺失字段，停止执行

### 0c. 续跑判断

- plan.status = `pending` → 全新执行，从第一个包开始
- plan.status = `running` → 中断续跑，跳过已完成包，从第一个 `pending` 包继续
- plan.status = `done` → 提示已完成，询问是否重新执行
- plan.status = `blocked` → 提示有阻塞，展示 blocked 原因，询问是否继续（跳过 blocked 包）或先处理阻塞

### 0d. Simple 模式判断

- plan 的 `mode` 为 `simple` 或只有 1 个包 → Simple 执行模式
- Simple 模式：不启 Agent，主会话直接按 Task Contract 执行
- Complex 模式：按 Step 2 顺序启动 Agent

## Step 1: 前置检查

1. **项目目录确认**：
   - 根据 plan.project 查找项目根目录
   - 当前工作目录应与项目根目录一致
   - 不一致时提示用户切换目录

2. **manifest 路径检查**（只检查存在性，不读取内容）：
   - 遍历所有包的 manifest 中的文件路径
   - 转为绝对路径后检查文件是否存在
   - 不存在的 knowledge 文件 → 标记警告，继续（知识文件可能有待建条目）
   - 不存在的 rules/packs 文件 → 标记警告，继续
   - 所有 rules 文件都不存在 → Blocked，需要先创建规则文件

3. 更新 plan.status 为 `running`

## Step 2: 顺序执行

按 packages 数组顺序，对每个 status 为 `pending` 的包：

### Step 2a: 启动 Agent

1. 读取 `./reference/task-packet-template.md` 获取标准 prompt 模板
2. 用当前包的字段填充模板：
   - 任务目标 ← package.name
   - **终端技能** ← package.skill（Agent 启动后先用 Skill 工具调用此技能）
   - manifest 文件列表 ← 转为绝对路径
   - 前序包输出 ← 从已完成的包收集（如果有 depends_on）
   - boundaries ← package.boundaries
   - Task Contract ← package.contract
3. 使用 `Agent` 工具启动子 Agent，subagent_type 用 `general-purpose`
4. Agent prompt 包含启动指令：
   - **如果 package.skill 有值且不是 "general-purpose"**：先 `Skill({skill: "{{package.skill}}"})` 加载终端技能的上下文和 Base Rules
   - **如果 package.skill 为空或 "general-purpose"**：跳过 Skill 调用，直接按 manifest 加载
   - 然后 Read manifest 中的所有文件（补充 Conditional Packs 和 knowledge）
   - 按 Base Rules 和命中 Packs 约束实现
   - 信息不足 → 扩散检索（限 3 次）
   - 第 4 次 → 停止，回报 [ESCALATE]
   - 范围扩大 → 立即停止回报
   - 完成 → 输出修改文件清单 + 简要说明
5. 更新包状态为 `running`，记录开始时间

### Step 2b: 监控与等待

1. Agent 在后台执行，等待完成通知
2. 收到 Agent 输出后检查：
   - 正常完成（含"完成报告"）→ 进入 Step 2c
   - 包含 `[ESCALATE]` → 暂停执行，按以下流程处理：
     a. 读取 `./rules/escalation.rules.md`
     b. 向用户展示 Agent 的 ESCALATE 报告
     c. 用户选择：
        - 批准继续 → Agent 重新获得 3 次配额，继续执行
        - 拒绝/调整 manifest → 标记 blocked，等用户补充后重试
        - 跳过当前包 → 标记 blocked，继续下一个包
     d. 用户选择后更新 plan 文件
   - Agent 异常终止 → 标记 blocked，记录错误信息，询问用户是否重试或跳过

### Step 2c: 验证

1. 检查 Agent 输出的修改文件清单
2. 确认没有修改 boundaries.forbid 中的路径
3. 确认输出与 contract.in_scope 一致
4. 不一致 → 标记 blocked，记录差异

### Step 2d: 更新日志

1. 更新 plan 文件中任务日志表格的对应行：
   - 状态 → `done`（或 `blocked`）
   - Agent ID
   - 完成时间戳
   - 备注（文件数、关键变更等）
2. 写入 plan 文件

## Step 3: 完成汇总

所有包执行完毕后：

1. 更新 plan.status：
   - 全部 done → `done`
   - 有 blocked → `blocked`
2. 输出执行摘要：

```
## 执行完成

| 包 | 状态 | 修改文件 | 备注 |
|----|------|----------|------|
| pkg-01 | done | 3 files | Entity + Repository |
| pkg-02 | done | 4 files | Service + DTO |
| pkg-03 | blocked | - | 扩散检索超限，需确认 |
```

3. 如有 blocked 包，明确列出需要用户处理的事项

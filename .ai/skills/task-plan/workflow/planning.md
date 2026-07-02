# 计划流程

收到任务描述后，先做复杂度评估，再按 Simple/Complex 分支处理。

## Step 0: 接收与识别

1. 解析用户的任务描述，提取关键词（中文 + 英文）
2. 识别目标项目：
   - 任务中明确提到 WMS → `wms`
   - 任务中明确提到 Trade/炒股 → `trade`
   - 无法识别 → `general`
3. 如果项目不是 `general`，读取 `CLAUDE.md` 中的路径映射获取项目根目录

### Step 0.5: 复杂度评估

按以下维度判断 Simple vs Complex：

| 维度 | Simple 信号 | Complex 信号 |
|------|------------|-------------|
| 知识域 | 1 个知识域 | 多个知识域或跨域联动 |
| 层级 | 单层（仅数据 / 仅业务 / 仅接口） | 跨层（2+ 层联动） |
| 跨端 | 不影响其他端 | 影响多端（Web + PDA + 外部系统） |
| 范围 | 任务描述明确，边界清晰 | 范围模糊，可能需要探索 |
| 依赖 | 无外部依赖 | 依赖其他模块/系统/接口契约 |

判定规则：
- 全部命中 Simple 信号 → **Simple Mode**（跳到 Step S）
- 任一命中 Complex 信号 → **Complex Mode**（继续 Step 1-5）

**Simple 模式不可强行使用**：如果拿不准，默认走 Complex。

---

## Simple Mode（Step S: 单包直出）

Simple 任务不需要拆包，生成单包计划：

**Step S1: 知识定位**
- 读取 `ai-lab://knowledge/INDEX.md`，匹配项目上下文
- 如果有项目知识索引则读取，没有则跳过
- 输出：命中的知识域（1 个）

**Step S2: 技能匹配**
- 根据知识域和项目确定终端技能（同 Step 2.5 逻辑）
- 无匹配技能 → 填空字符串 `""`

**Step S3: 文件清单**
- 根据任务关键词匹配 Base Rules 和 Conditional Packs（同 Step 3 逻辑）
- 所有路径使用项目相对路径

**Step S4: 生成计划**
- 生成单包计划文件，`mode: simple`
- YAML frontmatter 中 packages 数组只有 1 个元素
- 不需要包依赖图和分批信息
- 用户确认后写入 `plans/` 目录

Simple 模式下 task-execute 可以不启 Agent，主会话直接按 Task Contract 执行。

---

## Complex Mode（Step 1-5: 完整拆包）

### Step 1: 知识索引扫描

先读取 `./workflow/boundary-discovery.md` 了解发现流程。

执行：

1. 读取 `ai-lab://knowledge/INDEX.md`（共享知识库索引）
2. 如果项目不是 `general`，读取 `ai-lab://project/{project}/knowledge/INDEX.md`（项目知识库索引）
3. 列出所有索引中的关键词条目
4. 将任务关键词与索引条目逐一匹配
5. 输出：命中的知识域列表 + 每条对应的知识文件路径

若项目知识索引不存在或为空（如 `trade`），使用通用边界发现策略（见 boundary-discovery.md 的"通用项目回退"段落）。

### Step 2: 边界绘制与拆包

读取 `./rules/decomposition.rules.md` 确认拆包策略。

1. 对每个命中的知识域，判断涉及的系统层级
   - 有成熟分层 skill 的项目（如 WMS）：借鉴其 Entity/Service/Controller 分层
   - 通用项目：从任务描述推断依赖关系，被依赖的为基础层，依赖别人的为上层
2. 按"1 域 + 1 层 = 1 包"拆包
3. 检查数量是否超过 5：是 → 告知用户确认；否 → 继续
4. 建立包间依赖关系（拓扑排序）

输出：包列表（id、name、domain、layer、depends_on）

### Step 2.5: 技能分配

为每个包分配执行时要调用的终端技能：

1. **查阅项目 skills 目录**：读取 SKILL.md frontmatter 的 name 和 description，匹配覆盖范围
2. **查阅协调器路由表**：如果项目有协调器 skill，从其子技能路由表获取映射
3. **匹配条件**：技能覆盖的端/层与包的 domain+layer 匹配
4. **无匹配技能**：填写空字符串 `""`——task-execute 会跳过 Skill 调用
5. 将技能名写入每个包的 `skill` 字段

### Step 3: 文件清单生成

对每个包，生成 manifest：

1. **knowledge 文件**：从 Step 1 的命中结果获取对应知识文件路径
2. **Base Rules 文件**：根据包层级和技能匹配对应的 Base Rules
3. **Conditional Packs**：根据任务关键词二次匹配，未命中的不加入
4. **patterns 文件**：如果涉及提示词工程，检查 `knowledge/patterns/`
5. 所有路径使用项目相对路径

注意：manifest 不含技能自身通过 `@` 默认加载的 Base Rules——这些由 skill 自行加载。manifest 只补充 skill 不会默认加载的 Conditional Packs 和 knowledge 文件。

### Step 4: 契约与边界

对每个包定义：

1. **In Scope**：该包要完成的具体工作（一句话）
2. **Out of Scope**：明确排除的内容（基于层级边界和技能边界）
3. **allow_read / allow_write**：基于项目结构确定
4. **forbid**：其他端的目录或无关模块
5. **stop_condition**：何时触发范围扩大升级
6. **expected_files**：粗估修改文件数（不精确，仅参考）

### Step 5: 确认与生成

1. **先展示计划摘要给用户确认**：
   - 复杂度结论（Simple/Complex）
   - 包列表 + 每个包的 skill、domain、contract.in_scope
   - 知识索引命中情况
   - 未覆盖部分（如有）
2. 用户确认后：
   - 读取 `./reference/plan-template.md` 获取模板
   - 创建 `plans/` 目录（如不存在）
   - 生成文件名：`task-{当前日期}-{当前时间}-{任务关键词slug}.md`
   - 填入 YAML frontmatter + Markdown 正文
   - 输出：计划文件路径 + 包摘要
3. 用户要求修改 → 回到对应 Step 调整
4. 用户拒绝 → 不生成文件，记录讨论要点

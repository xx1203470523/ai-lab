# 知识边界发现

从 INDEX.md 文件中发现任务对应的知识域边界。

## 发现流程

### 1. 读取共享知识索引

读取 `ai-lab://knowledge/INDEX.md`，提取所有表格中的关键词条目。

索引结构示例：

```markdown
## domains/ — 业务上下文
| 文件 | 覆盖内容 |
| [wms.md](domains/wms.md) | WMS 项目：后端架构、发布流程、环境配置 |
| [trade.md](domains/trade.md) | 炒股项目：Python 环境、数据源、飞书通知 |
```

从"覆盖内容"列提取关键词用于匹配。

### 2. 读取项目知识索引

读取 `ai-lab://project/{project}/knowledge/INDEX.md`，提取关键词映射。

索引结构示例：

```markdown
| 关键词 | 文件 | 说明 |
| 入库,入库单,收货,WMS_StockIn | (待建) | 入库业务流程 |
| 出库,拣货,发货 | (待建) | 出库业务流程 |
```

### 3. 关键词匹配

1. 将任务描述拆分为关键词（中文词组 + 英文标识符）
2. 与索引中的关键词逐条匹配
3. 匹配方式：包含匹配（任务中包含索引关键词任一即命中）

示例：
- 任务："实现入库单查询功能"
- 关键词提取：入库、入库单、查询
- 命中索引条目：`入库,入库单,收货,WMS_StockIn`
- 知识域：入库/Inbound
- 知识文件：`project/wms/knowledge/backend/`（从索引条目映射）

### 4. 层级识别

从项目 Skill 结构推断系统层级。检查是否有类似 `wms-backend-dev` 的分层 skill：

- 如果存在，借鉴其 Entity/Repository/Service/Controller 分层：
  - Entity、Repository → data 层
  - Service、DTO → business 层
  - Controller、API → interface 层
- 如果不存在，根据知识库目录结构推断（如 `backend/`、`frontend/`、`pda/`）

对于通用项目（无项目特定 skill），按常规分层：
- 数据模型、存储 → data
- 业务逻辑、编排 → business
- API、界面 → interface

### 5. 技能映射

确定每个知识域+层级组合对应的终端技能：

1. **查阅项目 skills 目录**：读取每个 skill 的 SKILL.md frontmatter（name + description），匹配覆盖范围
2. **查阅协调器路由表**：如果项目有协调器 skill（如 `wms-dev`），从其子技能路由表直接获取映射
3. **匹配逻辑**：技能 description 中提到的端/层/模块与包的知识域+层级匹配
4. **写入 plan**：技能名写入每个包的 `skill` 字段，task-execute 执行时 Agent 调用 Skill 工具加载
5. **无匹配时**：`skill` 填空字符串 `""`——Agent 跳过 Skill 调用，直接按 manifest 工作

示例映射（WMS 项目）：
- 后端数据层 → `wms-backend-dev`
- 前端页面 → `wms-frontend-dev`
- PDA 手持端 → `wms-pda-dev`

示例映射（通用项目）：
- 项目无 skill → `""`（空）

## 未命中处理

如果任务关键词在索引中无匹配：

1. 检查共享知识索引中 domains/ 的覆盖内容是否有相关信息
2. 如果完全未命中，标记为"知识索引未覆盖"：
   - 告知用户当前知识索引无相关条目
   - 建议用户先补充知识索引或手动指定边界
   - 仍可继续生成计划，但包的 knowledge 清单为空，manifest 仅含 rules
3. 计划文件中标注"知识索引命中: 部分/无"

## 通用项目回退

当项目没有知识索引（INDEX.md 不存在或为空），或完全无法从索引匹配时，使用以下回退策略：

### 边界推断

从任务描述本身推断边界，不依赖索引：

1. **识别实体/对象**：从任务描述中提取核心名词（如"订单"、"用户"、"商品"）
2. **识别操作**：提取动词（如"创建"、"查询"、"导出"）
3. **推断层级**：
   - 涉及数据定义、存储结构 → data 层
   - 涉及业务规则、处理逻辑、编排 → business 层
   - 涉及 API、界面、对外暴露 → interface 层
4. **识别依赖**：任务中"先...后..."或"A 的结果给 B" → 包间依赖

### 知识来源标注

通用项目回退时：
- `knowledge_sources` 中标注来源为 "task-description"（从任务描述推断）
- manifest 中 knowledge 清单为空或仅含共享 `knowledge/patterns/` 下的通用方法论
- 计划文件中注明"知识索引未覆盖，边界从任务描述推断"

### 技能分配

通用项目的包 `skill` 字段填空字符串 `""`，除非用户在任务中明确指定了技能。

## 多域交叉

任务可能涉及多个知识域（如"入库单创建后通知 T100"）：

- 入库 → 一个知识域
- T100 → 另一个知识域
- 两个域独立成包，在 depends_on 中标注依赖

## 边界确认

发现完成后，向用户展示：
- 命中了哪些知识域
- 每个域的层级划分
- 未命中的部分（如有）

用户确认后进入拆包（Step 2）。

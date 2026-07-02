# 计划输出格式

## 文件位置

- 目录：项目根目录的 `plans/` 文件夹
- 若 `plans/` 不存在，先创建该目录
- 文件名格式：`task-{YYYYMMDD}-{HHMM}-{slug}.md`
- slug 为任务描述的关键词简拼，小写英文，用 `-` 连接

## YAML frontmatter 字段

### 顶层字段

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| plan_id | string | 是 | 与文件名一致，如 `task-20260703-1430-wms-inbound` |
| created | string | 是 | ISO 8601 格式，`YYYY-MM-DDTHH:MM:SS` |
| status | string | 是 | `pending` / `running` / `done` / `blocked` |
| mode | string | 是 | `simple`（单包直出）/ `complex`（多包编排） |
| project | string | 是 | 项目名，如 `wms`、`trade`，通用任务用 `general` |
| description | string | 是 | 一句话任务描述 |
| knowledge_sources | string[] | 是 | 计划所依据的知识索引文件路径。通用回退时标注 `"task-description"` |
| packages | object[] | 是 | 包列表，按执行顺序排列 |
| total_packages | number | 是 | 包总数 |

### package 字段

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| id | string | 是 | 唯一标识，如 `pkg-01`、`pkg-02` |
| name | string | 是 | 中文包名，含层级信息 |
| skill | string | 是 | 执行此包时要调用的业务技能名。通用任务填空字符串 `""` 或不填——此时 Agent 不会调用 Skill 工具 |
| domain | string | 是 | 知识域名称 |
| layer | string | 是 | 包的层级标签。常见值：`data`、`business`、`interface`。也可以是项目自定义层级如 `component`、`hook`、`config`。此字段用于排序和依赖判断，不影响执行逻辑 |
| status | string | 是 | `pending` / `running` / `verifying` / `done` / `blocked` |
| depends_on | string[] | 是 | 依赖的包 id 列表，无依赖填 `[]` |
| manifest | object | 是 | 文件清单 |
| boundaries | object | 是 | 读写边界 |
| contract | object | 是 | 任务契约 |

### manifest 字段

| 字段 | 类型 | 说明 |
|------|------|------|
| knowledge | string[] | 知识文件路径（相对项目根目录） |
| rules | string[] | Base Rules 文件路径 |
| packs | string[] | Conditional Rule Packs 路径，仅命中场景 |
| patterns | string[] | 方法论/模式文件路径，按需 |

### boundaries 字段

| 字段 | 类型 | 说明 |
|------|------|------|
| allow_read | string[] | 允许读取的目录或文件路径 |
| allow_write | string[] | 允许修改的目录或文件路径 |
| forbid | string[] | 禁止读取/修改的目录或文件路径 |

### contract 字段

| 字段 | 类型 | 说明 |
|------|------|------|
| in_scope | string | 明确在范围内的工作内容 |
| out_of_scope | string | 明确排除的工作内容 |
| expected_files | string | 预计修改的文件数范围 |
| stop_condition | string | 触发停止并回报的条件 |

## Markdown 正文

YAML frontmatter 后必须包含以下 Markdown 段落：

- 一级标题：`# Task Plan: {description}`
- 复杂度评估段落
- 知识边界来源表格
- 包依赖图（文本 ASCII）
- 任务日志表格（初始状态全部 pending）

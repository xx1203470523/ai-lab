# 拆包策略

## 粒度规则

- **基本单位**：1 个知识域 + 1 个系统层级 = 1 个包
- **合并条件**：同一知识域 + 同一层级合并为一个包
- **拆分条件**：同一知识域但不同层级（如入库的 Entity 和入库的 Service）必须拆分为不同包
- **不同知识域**：必须独立成包，不能合并（如"入库"和"出库"分属不同包）

## 层级识别

系统层级从项目已有的 skill 结构或知识库目录推断。层级标签是自由字符串，用于排序和依赖判断。

**常见层级示例**（不强制，项目可自定义）：

| 项目类型 | 常见层级标签 |
|---------|------------|
| 后端 MVC/三层 | `data`（Entity/Repository）、`business`（Service/DTO）、`interface`（Controller/API） |
| 前端组件 | `component`、`hook`、`state`、`route` |
| CLI 工具 | `command`、`parser`、`config`、`output` |
| 数据管道 | `ingest`、`transform`、`model`、`report` |

层级发现优先级：
1. 项目 skill 的 Domain Routing 表中定义的分层（如 wms-dev 的 Entity/Repository/Service/Controller）
2. 项目目录结构（如 `src/models/`、`src/services/`、`src/routes/`）
3. 任务描述中的隐含依赖关系（被依赖的先执行）
4. 以上都没有 → 不设层级，depends_on 直接描述包间顺序

## 数量上限

- 最多 5 个包
- 超过 5 个时，输出消息："建议进一步合并或分批执行，当前共 N 个包"，等待用户确认
- 用户确认后才继续生成计划文件

## 排序规则

- 按依赖关系拓扑排序
- 无依赖关系的包按 data → business → interface 排列
- 同一层级中，被依赖的包排在前面

## 边界来源

- **唯一来源**：`knowledge/INDEX.md` 和项目级 `knowledge/INDEX.md`
- 不得通过 Grep 代码、读取项目文件结构、扫描目录来确定边界
- 知识域映射：任务关键词命中索引条目 → 该条目对应的文件成为包的 knowledge 清单
- 未命中的知识域不加入任何包

## 跨域任务

- 多个知识域的任务（如"入库 + 出库联动"）：每个域独立成包
- 在 depends_on 中标注跨域依赖关系
- 如果跨域依赖不明确，标记为 "需确认"

# Repository Rules

## Purpose

定义 Repository 层开发必须遵守的稳定约束。

不包含：

- 任务流程
- Skill 路由
- Agent 编排
- 业务流程

---

## Rule Loading

当前规则为 Repository Base Rules。

命中以下场景时加载对应 Pack：

| 场景                                           | Rule Pack                           |
| ---------------------------------------------- | ----------------------------------- |
| Queryable、Where、分页、软删除、数据范围、性能 | `packs/repository-query.rules.md`   |
| 原生 SQL、参数化、IN 条件、字符串拼接          | `packs/repository-raw-sql.rules.md` |
| Insert、Update、Delete、批量写入、事务协作     | `packs/repository-write.rules.md`   |

规则：

- 命中必须读取。
- 未命中禁止读取。

---

## Namespace

规则：

- 使用领域类库 namespace。
- 禁止根据目录生成 namespace。
- 新增 using 必须实际使用。
- 禁止保留无用 using。

---

## File Location

Repository：

`IMTC.WMS.AdminWebApi/Domain/<DomainProject>/Repositories/<Module>/`

规则：

- 文件名与类名一致。
- 类名格式：

`<EntityName>Repository`

- 禁止无业务原因修改历史文件名、类名、目录。

---

## Class Structure

Repository 标准结构：

- 继承 `Repository<TEntity>, ITransient`。
- 构造函数使用 `ISqlSugarClient context`。
- 构造函数调用 `base(context)`。
- 类必须包含 XML summary。

公共方法：

- 必须包含 XML summary。
- 参数或返回值语义不明确时补充 param / returns。

---

## Responsibility

Repository 负责：

- 持久化访问。
- 查询组合。
- 批量写入入口。
- 数据投影。

禁止：

- 业务流程编排。
- 权限判断。
- 外部系统调用。
- HTTP 调用。
- 消息推送。
- UI 展示逻辑。
- 缓存流程控制。

---

## Method Design

规则：

- 方法名必须表达业务含义。
- 禁止新增模糊命名：
  - SQL1
  - GetData
  - DoUpdate

- 公共方法参数必须使用：
  - DTO
  - 查询对象
  - Entity
  - Id 集合
  - 明确条件参数

禁止：

- 传入未约束 SQL 片段。

返回：

- 影响行数使用 `int` 或 `Task<int>`。
- 返回查询构造器的方法不得内部执行查询。

业务异常：

- 优先由 Service 判断。
- Repository 默认返回数据、空值或影响行数。

---

## Boundary

Repository 任务只处理：

- 查询访问。
- 数据持久化。
- Repository 方法设计。

禁止在 Repository 修改任务中：

- 修改 Service。
- 修改 Controller。
- 修改 DTO。
- 修改 Web/PDA。
- 修改数据库脚本。

---

## Compatibility

禁止：

- 批量重写历史 SQL。
- 批量修改 SQL 命名。
- 批量清理历史兼容代码。

以下修改需要确认：

- 查询结果变化。
- 分页顺序变化。
- 过滤范围变化。
- 锁范围变化。
- 事务耗时变化。

---

## Code Style

规则：

- C# 使用 4 空格缩进。
- 方法之间保留一行空行。
- 标识符使用英文。
- 注释使用简体中文。
- 遵循已有项目命名。

禁止：

- 无关排序。
- 无关格式化。
- 无用变量。
- 死代码。
- 调试输出。
- 临时注释。

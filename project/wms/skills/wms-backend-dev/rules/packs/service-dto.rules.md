# Service DTO Rule Pack

适用场景：

- DTO 新增
- DTO 修改
- API 入参/出参调整
- 查询条件调整
- 打印/导出 DTO
- Web/PDA 消费 DTO
- V2 DTO

# 1. DTO Responsibility

DTO 用于表达明确的数据契约。

DTO 可以用于：

- API 输入
- API 输出
- 查询条件
- 服务间数据传递
- 导出结构
- 打印结构
- 流程上下文

禁止：

- 使用 DTO 替代 Entity。
- 使用 DTO 承载业务流程。
- 使用 DTO 隐藏不明确的数据结构。

# 2. DTO Naming

新增 DTO 名称必须表达用途。

推荐：

- XxxDto
- XxxQueryDto
- XxxOutputDto
- XxxCreateDto
- XxxUpdateDto
- XxxResultDto
- XxxContextDto
- XxxProcessDto
- XxxExportDto
- XxxPrintDto
- XxxInputDto

V2：

- XxxV2Dto
- XxxV2QueryDto
- XxxV2OutputDto

禁止新增：

- DataDto
- InfoDto
- TempDto

等无法表达用途的名称。

# 3. Data Shape

业务数据必须具有明确结构。

禁止：

- object 承载业务字段。
- dynamic 承载业务字段。
- Dictionary<string, object> 承载业务字段。
- object[] 表达业务结构。
- 裸数组通过下标表达业务含义。
- tuple / ValueTuple 承载复杂业务结果。

要求：

- 集合必须明确元素类型。
- 跨层传递数据必须使用明确 DTO。
- 复杂流程上下文使用 ContextDto / ProcessDto / ResultDto。

# 4. DTO Contract Protection

以下修改属于契约变化：

- 删除字段
- 修改字段名称
- 修改字段类型
- 修改可空性
- 修改枚举含义
- 修改导出字段
- 修改打印字段

契约变化必须确认：

- 调用方
- 消费端
- 数据含义

禁止：

- 未确认删除历史字段。
- 未确认改变返回结构。
- 未确认修改 Web/PDA/API 使用字段。

# 5. DTO File Separation

一个 `.cs` 文件只放一个 DTO 类，按用途独立文件。不同用途的 DTO 禁止合并到同一文件。

使用反引号分隔：

``{Name}Dto`{Purpose}.cs``

标准 `{Purpose}` 示例：`Query`、`Export`、`PagedQuery`。

禁止：

- 多个不相关 DTO 类合并到单一文件。
- `QueryDto`、`PagedQueryDto`、`ExportDto` 混在同一文件。

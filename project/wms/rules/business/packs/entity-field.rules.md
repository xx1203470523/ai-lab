---
description: "Entity Field Conditional Rule Pack：字段注释、SugarColumn、nullable、长度、精度、枚举、NoDB 字段约束。"
paths:
  - "IMTC.WMS.AdminWebApi/Domain/Domain.Warehouse/Entities/**/*.cs"
---

# Entity Field Rule Pack

命中条件：任务涉及新增或修改实体字段、XML summary、SugarColumn、nullable、字符串长度、decimal 精度、枚举/状态/标记、NoDB/Ignore 字段。

## 1. Property Comments

- 每个属性必须有 XML `<summary>`。
- 每个数据库映射属性必须有 `[SugarColumn(ColumnDescription = "...")]`。
- summary 与 `ColumnDescription` 的业务含义必须一致。
- 字段说明必须能一行解释清楚字段含义，禁止只重复字段名。
- `byte`、枚举、状态、类型、标记字段必须描述取值含义。
- bool 字段必须描述 `true/false` 语义，或明确历史 0/1 存储语义。
- 禁止在新增或修改后的字段中留下 summary、C# 类型、SqlSugar 特性互相矛盾的可空描述。

## 2. SugarColumn

- 字符串字段必须配置 `Length = FieldLengthConst.Xxx`。
- `decimal` / `decimal?` 字段必须配置 `DecimalDigits = DecimalDigitsConst.Xxx`。
- 非数据库字段必须配置 `[SugarColumn(IsIgnore = true)]`。
- 数值、日期、bool 字段禁止配置 `Length`。
- `DefaultValue = "0"` 只允许用于业务明确要求非空默认值的字段。
- `IsNullable = true` 只在新增字段、明确 nullable 字段或任务要求时维护；禁止对历史字段批量机械补充。

## 3. Nullable

- 新增字段默认允许为空：`string?`、`long?`、`decimal?`、`byte?`、`DateTime?`、`bool?`。
- 只有明确业务必填、数据库强约束、主键、基类字段或用户明确要求时，才使用非可空类型。
- 非可空引用类型必须有明确初始化、默认值或构造赋值依据。
- 禁止对历史字段批量执行 nullable 改造。
- 禁止为了规则统一而改变历史数据库语义。

## 4. String Length And Decimal Precision

- 字符串长度必须使用 `FieldLengthConst`，禁止写魔法数字。
- 单号、编码、人员编码、部门编码优先使用 `FieldLengthConst.Code`。
- 名称优先使用 `FieldLengthConst.Name`。
- 短状态、短类型、Y/N 标记优先使用 `FieldLengthConst.Flag` 或 `FieldLengthConst.LongFlag`。
- 标签号、SN、较长业务值优先使用 `FieldLengthConst.StandardValue`。
- 规格型号、长标准值优先使用 `FieldLengthConst.LongStandardValue`。
- 备注、原因、说明、内容优先使用 `FieldLengthConst.Remark`。
- `decimal` / `decimal?` 字段默认使用 `DecimalDigitsConst.DefaultLong`。
- 如同一模块已有更明确的精度常量，允许使用该常量。
- 禁止遗漏 decimal 精度配置。

## 5. Enum / Status / Flag

- 枚举命名使用 `E*`。
- 枚举基类型使用 `byte`。
- 枚举值必须带 `[Description("...")]`。
- 实体中的枚举字段必须说明枚举语义。
- byte 状态字段必须写清取值含义，例如：`0.待处理；1.处理中；2.已完成`。
- string 标记字段必须写清取值含义，例如：`Y.是；N.否`。

## 6. NoDB / Ignore Fields

- 非数据库字段必须标记 `[SugarColumn(IsIgnore = true)]`。
- 非数据库字段必须有 XML summary。
- 非数据库字段不参与表结构生成、数据库索引或迁移。
- 禁止因规范化重命名历史 NoDB 文件或历史展示字段。

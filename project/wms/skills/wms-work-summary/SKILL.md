---
name: wms-work-summary
description: "按日期快速检索 WMS 任务日志，合并需求并输出可复制到 Excel 的工作汇总表。"
shell: powershell
version: 1.3.0
---

# WMS Work Summary — 任务日志工作汇总

必须遵守：./rules/work-summary.rules.md

## Trigger

用户要求以下任一任务时触发：

- `/wms-work-summary`
- 按日期汇总工作、日报、周报、工作量统计
- 整理 `logs/liyanpeng/{日期}` 为 Excel 可分列文本
- 汇总 AI 提效、人工预计工时、实际工时

## Output Goal

输出无列头、可复制到 Excel 的明细行，默认用 ASCII 竖线 `|` 分隔。列顺序以 `./rules/work-summary.rules.md` 为准。

## Fast Workflow

### 1. 锁定日期

- 用户给日期/日期范围：只处理对应 `logs/liyanpeng/YYYY-MM-DD/`。
- 用户说“今天”：使用当前会话日期。
- 用户未给日期：先问日期；不要默认扫描全部日志。

### 2. 只读必要来源

优先读取目标日期目录下的任务日志：

```powershell
Get-ChildItem -LiteralPath "logs/liyanpeng/<date>" -Recurse -Filter "*.md"
```

仅在需要补充产出物或合并依据时读取：

- 对应 `logs/_entries/<date>_*.md`
- 日志中明确提到的分支、提交、MR、改动文件
- 当前分支同日提交：`git log --author="liyanpeng" --since=<date> --until=<date+1> --no-merges --oneline --max-count=30`

不要打开 `logs/INDEX.md`，除非目标日期目录缺失或用户要求跨日期广泛定位。

### 3. 最小解析字段

每份日志只提取生成表格必需的信息：任务目标、日期、分支/提交、预计纯人工工时、实际工时、做了什么、验证、风险/阻塞、主要改动文件。

缺失字段按规则写 `未记录`；不要为了“补完整”扩大检索范围或猜测。

### 4. 合并同一需求

按相同任务目标、业务模块、分支、主要改动文件、MR/提交链路合并。合并后只保留一行业务结果描述，工时求和，起止日期取最早/最晚，验证和风险去重。

### 5. 控制输出简洁度

- 主表只输出明细行，不输出列头。
- 需求说明写一句业务结果 + 主要改动，避免复述完整日志过程。
- 验证、风险、备注只写结论，不展开命令长输出。
- 表后最多补 1~3 条统计说明：读取日志数、合并需求数、缺失字段或未验证项。

## Optional References

- `references/README.md`：列结构、提效比控制速查。
- `scripts/README.md`：可选辅助脚本说明；脚本不默认执行。

## Boundaries

- 只汇总日志和必要提交信息，不修改业务代码、日志索引、Git 状态。
- 不生成 Excel 文件，只输出可复制文本。
- 不统计未写入任务日志的工作，除非用户明确要求从 Git 补推断，并标注“日志缺失”。
- 不把多个无关需求强行合并。

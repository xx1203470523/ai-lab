---
spec_id: task-spec-20260923-1550-prep-material-report
revision: 1
status: DRAFT
complexity: L3
style_contract: PROJECT + PERSONAL
created_at: 2026-09-23T15:50:02+08:00
updated_at: 2026-09-23T15:50:02+08:00
project_root: "D:\Project\WMS\.claude\worktree\prep-material-report"
project_id: "http://10.10.80.231:8052/hjh1126123/wms"
evidence_baseline: "worktree .claude/worktree/prep-material-report @ feature/lyp/prep-material-report HEAD 3a59b94fc08323eb4ed161b786121fec3c37482f"
request_original: "新增「仓库备料综合报表」（拣料单维度）。取数说明见 仓库备料综合报表.xlsx：大量数据要从备注中按 + 分割取第几位；这些截取内容只用于展示、不增加搜索条件，只增加一个 T100 全模糊匹配搜索条件；基础数据来源是拣料单，其他可参考出库综合报表。"
supersedes: null
package_status: READY_FOR_APPROVAL
approved_at: null
approved_revision: null
approval_statement: null
---

# 仓库备料综合报表（拣料单维度）

## 1. Summary

- **Goal**：新增「仓库备料综合报表」列表页 + Excel 导出，一行对应一个由用户确认的统计粒度，展示 A–W 中 18 个可见列；其中 7 列来自 T100 单头备注的 `+` 分段解析。
- **Problem**：需求只存在于一张 Excel 的取数说明与一张 T100 截图里：4 处段位说明自相矛盾；系统内不存在「模组名称」字段；备料/转运/领料确认/回单登记四段数据分散在 8 张以上表，且「转运」在代码里有三套并存载体。
- **Value**：让 PC 与仓管在一个页面看完备料全链路，替代当前人工把 WMS 数据与 T100 备注对回 Excel 的做法。
- **Complexity**：`L3` — 跨后端 `Services.Report` / `Application.Report`、前端 AdminUI 页面与菜单 SQL 四层，新增查询契约与导出契约，并引入一条由人工填单习惯决定的数据口径规则。若采纳「同步层物化解析记录表」方向（D-07 选项 B），则升级为 `L4`（含迁移、回填、对账与不可逆 DDL）。
- **Status**：`DRAFT`

### 列映射速览（以需求 Excel 第 6 行为准）

| 列 | 列名 | 取数说明 | 落点/状态 |
|---|---|---|---|
| A | 收到单据时间 | 取单据配送时间 | 待定表：D-09 |
| B | 负责PC | T100 单头备注第 1 个字段 | 段位冲突：D-02 |
| C | 单据编号 | T100 单号 BillNo | `OutStockPickOrder.SyncCode` |
| D | 项目名称 | T100 明细项目号 | `OutStockPickOrderDetail.ProjectNo` |
| E | 模组号 | T100 明细模组号 | `OutStockPickOrderDetail.ModuleNo` |
| F | 模组名称 | 单头备注第 X 个字段（**X 未填**） | 段位冲突：D-03 |
| G | 特殊说明 | 不要 | 不展示 |
| H | 单据备注 | T100 单据备注 | 归属待定：D-04 |
| I | 项数 | 单号/项目号/模组对应的项数统计 | 口径 D-06，粒度 D-05 |
| J | 总装/部装 | + 号后第 1 个 | 段位冲突：D-02 |
| K | 接收人 | + 号后第 2 个 | 待确认 |
| L | 接收位置 | + 号后第 3 个 | 待确认 |
| M | 批次 | + 号后第 5 个 | 段位冲突：D-01 |
| N | 开单下料时间 | + 号后第 5 个 | 段位冲突：D-01 |
| O | 修正下料时间 | 不要 | 不展示 |
| P | 是否收回 | 回单登记 | 未登记口径：D-08 |
| Q | 备料完成日期 | WMS 备料完成时间 | `OutStockPickOrder.PickOverTime` |
| R | 备料人 | WMS 备料人（多个，分号拼接） | `OutStockPickOrderDetail.PickUser` |
| S | 转运下料时间 | WMS 物料配送→配送完成时间 | 载体待定：D-09 |
| T | 转运人 | WMS 物料配送→配送人 | 载体待定：D-09 |
| U | 清点日期 | WMS 领料确认完成时间 | `OutStockReceiveDetail.ReceiveOverTime` |
| V | 清点人 | WMS 领料确认人 | `OutStockReceiveDetail.ReceiveUser` |
| W | 单据回收异常原因 | 不要 | 不展示 |

**T100 备注样例（截图原文）**：`李怡静+WA41+1.5北区+卷绕头模组-聂元克+李想+8月5号+第三批` → 按 `+` 拆 7 段：1 李怡静 / 2 WA41 / 3 1.5北区 / 4 卷绕头模组-聂元克 / 5 李想 / 6 8月5号 / 7 第三批。第 4 段内部还含一个 `-`。截图营运据点为 `苏海_锂电(LEBGJS)`。

## 2. Current State

### Facts

| ID | 证据 | 已确认观察 |
|---|---|---|
| F-01 | `Services/Services.Report/Services/Implementations/OutStockOrderReportService.cs:9` | 参考报表服务 `: IOutStockOrderReportService, ITransient`，仅注入 `ICachingService`、`IReportDbScopeProvider` |
| F-02 | 同上 `:30-49` | 分页入口：`:32` `Adapt<>()`、`:35` `BuilderMainQuery`、`:36` `ToPageAsync`、`:38` `FillOrderDataAsync` |
| F-03 | `OutStockOrderReportService.cs:136-238`；`Domain/Domain.Shared/Extensions/QueryableExtension.cs:37-48`；`Query/PagerQuery.cs:37` | 主查询**无显式 ORDER BY**，分页顺序不稳定（既有缺陷，不应复刻） |
| F-04 | `OutStockOrderReportService.cs:54-77`、`:82-96`；`Services.Report/Services/ReportQueryPolicy.cs:9`、`:21`、`:24` | 导出按用户加锁 + 行数上限校验 + 游标分批；`MaxQueryMonths=3`、`ExportMaxRows=500000`、`ExportBatchSize=100000` |
| F-05 | `Application/Application.Report/Controllers/OutStockReportController.cs:6`、`:35-40`、`:45-51` | `[Route("report/outstock")]`，`order/page` 与 `order/export`；导出返回 `Success(new { path = "/export/" + fileName, fileName })`；该目录下**无任何权限特性** |
| F-06 | `OutStockReportController.cs:6` vs `OutStockShipmentReportController.cs:6`、`:27`、`:40`、`:52` | 路由族两套并存：旧族 `report/<domain>/{subtype}/{page\|export}` 与新族 `reports/<kebab>/{query\|export\|enums}`；`ReceiptReportController.cs:41` 是第三种返回 `File` 字节流的写法 |
| F-07 | `IMTC.WMS.AdminUI/src/views/reports/outstock-order-report/index.vue:41-43`；`src/store/modules/permission.js:12`、`:74`、`:111-120` | `defineOptions({ name: 'reports/outstock-order-report/index' })` 必须与 `sys_menu.Component` 完全一致，动态路由靠 `import.meta.glob` + `loadView` 解析 |
| F-08 | 同 `index.vue:78-93` | `download(res.data.path, { name: res.data.fileName, hasBase: true, target: 'report' })` |
| F-09 | `sql/publish/v1.3.8.3/2026-09-21_add_outstock_difference_pick_report_menu.sql` 等 | 只插 1 行 `sys_menu`（`MenuType='C'`、`Perms=''`、`Icon='table'`、`IsCache='0'`、`Visible='0'`、`Status='0'`、`IsDeleted=0`）；父锚点 `MenuType='M' AND MenuName IN ('报表管理','报表')` 且 `COUNT(*)=1` 否则 NULL（失败关闭）；`OrderNum=MAX+1`；`Path==Component`；无 F 按钮行、无 `sys_role_menu` 写入 |
| F-10 | `Domain/Domain.Warehouse/Entities/OutStock/OutStockPickOrder.cs:17`、`:43`、`:58`、`:205`、`:212`、`:230` | `SyncCode`=T100 单号、`DeliveryId`=出库单 Id、`PickOverTime`=备料完成时间、`HandOverTime`=领料完成时间、`T100Remark`=T100 备注 |
| F-11 | `OutStockPickOrderDetail.cs:18`、`:46`、`:84`、`:248`、`:254`、`:269` | 明细有真字段 `SyncCode`、`ProjectNo`、`ModuleNo`（作业编码/模组号）、`BatchNo`、`PickUser`（拣料人）；`ProjectNo`/`ModuleNo` 在 `detail_piece`、`label` 上也有冗余真字段 |
| F-12 | 全仓 `Grep 模组名称\|ModuleName` → 仅命中 LowCode `GenTable.cs:52` | **系统内不存在任何业务「模组名称」字段或主数据表**，该列只能来自备注解析 |
| F-13 | `OutStockOrderReportService.cs:409`；`OutStockDifferencePickReportService.cs:462`；`OutStockDetailReportService.cs:523`；`OutStockShipmentReportService.cs:399-412` | 备料人等多值字段现网**一律用英文逗号** `string.Join(",", …Distinct())`；全仓无分号拼接备料人的先例 |
| F-14 | `OutStockPickOrderDetail.cs:269`；`OutStockReceiveDetail.cs:256`、`:263`；`OutStockOrderReportService.cs:416-421` | 备料人=明细 `PickUser`；领料确认完成时间=`outstock_receive_detail.ReceiveOverTime`，领料人=`ReceiveUser`；报表口径为 `Max(ReceiveOverTime)` + `ReceiveUser` 去重拼接 |
| F-15 | `WarehouseDelivery/OutStockWarehouseDelivery.cs:13`、`:43`、`:79`；`DeliveryHandover/OutStockDeliveryHandover.cs:15`、`:51`、`:129`；`Operations/OperationsOrderDelivery.cs:10`、`OperationsOrderDeliveryDetail.cs:69` | 「转运/物料配送」**三套并存载体**：(a) `outstock_warehouse_delivery`，键 `OutStockPickOrderId`，时间 `ConfirmOn`；(b) `outstock_delivery_handover`，键 `OutStockDeliveryId`，时间 `SubmitOn`；(c) `operations_order_delivery`，键明细 `PickOrderId`，时间 `DeliveryOn`/`ConfirmOn` |
| F-16 | `OutStockOrderReportService.cs:256-287`、`:349-377`（单据配送）、`:383-392`（`CompleDeliveryTime = warehouseDelivery?.ConfirmOn`）、`:394-400`（配送交接 `SubmitOn`） | 出库综合报表同时展示三类配送时间 → 「物料配送」一词在项目中并不唯一指向某一张表 |
| F-17 | `Services.Warehouse/…/OperationsOrderReturnRegistrationService.cs:213-214`、`:511`、`:536`、`:547`、`:473-475`；`OperationsOrderReturnRegistrationDetail.cs:11`、`:12` | 回单登记**按人建单**（`RegistrationEntityType=(EDeliveryEntityType)2` 人员、`RegistrationEntityCode`=工号）；明细 `BuildPickSnapshotAsync` 写 `PickOrderId`=拣料单 Id，有 `idx_PickOrderId`/`idx_SourceOrderCode`；确认后 `Status=BusinessCompleted`。按拣料单反查「是否已收回」**可行** |
| F-18 | `Services.Warehouse/…/OutStockDeliverySyncService.cs:581`；`…/OutStockPickOrderCreationService.cs:495-496`、`:228`；`OutStockDeliveryPostServcie.cs:186`、`:257`、`:524-525` | **T100Remark 两个写入点口径不一致**：补生成链路写 `T100Remark = delivery.Remark`；主同步链路写 `pickOrder.T100Remark = delivery.T100Remark`，而出库单的 `T100Remark` 只被过账链路写「过账结果」，新建出库单时为空 |
| F-19 | `OutStockOrderReportService.cs:408`（`item.ItemQuantity = pickOrderDetails.Count()`），同文件 `:252-254`、`:344` | 既有「项数」= 该拣料单的拣料明细行数（按 `PickOrderId` 分组计数），**非**去重物料数 |
| F-20 | 全仓 `Grep GroupBy` → 仅 `{DeliveryNo, ProjectNo}`（`MaterialPrepareListService.cs:361`）、`{MaterialCode, ProjectNo}` 等 | 不存在 `SyncCode + ProjectNo + ModuleNo` 三元组的现成分组统计实现 |
| F-21 | `仓库备料综合报表.xlsx` 第 1/6/7/8/10 行；`xl/media/image1.png` | 截图是 T100「工单成套发料维护作业(asft311)」备注页签，营运据点=苏海_锂电(LEBGJS)，备注样例 7 段，第 4 段内含 `-` |
| F-22 | 上一轮对 `prod.lebgjm` 的只读统计 | `outstock_pick_order` 344,850 行，`T100Remark` 为空 33,703 行（9.8%），含 `+` 仅 206 行（0.06%）且无一符合截图结构。**该库据点 LEBGJM ≠ 报表目标据点 LEBGJS，不能据此推断目标据点命中率** |
| F-23 | `OutStockPickOrder.cs:193`、`:199`、`:205`；`logs/_entries/2026-06-26_151615_综合报表扫描时间冗余字段.md`；`logs/_entries/2026-07-14_193000_拣料时间统一为备料时间.md` | 拣料单上已有备料阶段时间冗余列先例（`PickStartTime`/`PickEndTime`/`PickOverTime`）；「备料」列命名口径已在历史任务中统一 |
| F-24 | `OutStockOrderReportExportDto.cs:11`、`:24`、`:43`、`:109`、`:134`、`:147`、`:242`、`:249` | 导出 DTO 用 `[DisplayName]`+`[ExcelFormat]`+`[ExcelIgnore]`；展示 DTO 只用 XML `<summary>`。参考实现存在**重复 `[DisplayName]`**（`:173/:179`、`:198/:204`）导致导出表头重复的既有缺陷 |
| F-25 | `OutStockOrderReportService.cs:9-23` 及各方法内 `GetScope()` 的写法 | 必须在**每个方法内部**获取 `SqlSugarScopeProvider`；跨方法传递 provider 会破坏全局 `IDeletedFilter` |

### Known Gaps

1. 目标据点 **LEBGJS（苏海_锂电）的真实备注分布未取样**：`.env` 无 `PROD_LEBGJS_*` 路由，本地无法连接。
2. 「模组名称」无任何主数据或字段可查（F-12），只能来自备注解析。
3. 拣料单主表与明细均**无仓库字段**，库位编码/名称仅存在于 `outstock_pick_order_label`。
4. 明细无 `WarehouseKeeper` 真字段（仅遗留视图与裸 SQL 引用）。
5. 拣料单**无「同步时间」列**，只有 `SyncStatus` 标志位；T100 侧创建时间落在 `OutStockDelivery.MakeDate`。
6. 回单登记 PDA 功能对备料单据的覆盖率无数据。

## 3. Target State

### Explicit Requirements

- [R-01] 新增页面 + 导出，列 A–W 共 18 列可见，取数口径以需求 Excel 第 6 行为准。
- [R-02] A 收到单据时间 = 取单据配送时间。
- [R-03] B 负责PC = T100 单头备注第 1 个字段。
- [R-04] C 单据编号 = T100 单号（BillNo）。
- [R-05] D 项目名称 = T100 单据明细项目号（ProjectNo）。
- [R-06] E 模组号 = T100 单据明细模组号（ModuleNo）。
- [R-07] F 模组名称 = 取 T100 单头备注第 X 个字段（X 未填）。
- [R-08] G 特殊说明、O 修正下料时间、W 单据回收异常原因：不展示。
- [R-09] H 单据备注 = T100 单据备注。
- [R-10] I 项数 = 单号/项目号/模组对应的项数统计。
- [R-11] J 总装/部装 = `+` 号后第 1 个；K 接收人 = 第 2 个；L 接收位置 = 第 3 个。
- [R-12] M 批次 = 第 5 个字段；N 开单下料时间 = 第 5 个字段。
- [R-13] P 是否收回 = 回单登记（Excel 第 10 行标注为 PDA 新增功能）。
- [R-14] Q 备料完成日期 = WMS 备料完成时间；R 备料人 = WMS 备料人（多个，分号拼接）。
- [R-15] S 转运下料时间 = WMS 物料配送→配送完成时间；T 转运人 = WMS 物料配送→配送人。
- [R-16] U 清点日期 = WMS 领料确认完成时间；V 清点人 = WMS 领料确认人。
- [R-17] 备注派生字段只用于展示，**不为其增加搜索条件**；只新增一个 T100 全模糊匹配搜索条件。
- [R-18] 基础数据来源是拣料单；其他可参考出库综合报表。

### Inferences

| ID | 基于 | 推断 | 置信度 | 推翻条件 |
|---|---|---|---|---|
| I-01 | F-12, F-21, R-07 | F 模组名称无系统字段，唯一可取来源是备注；按样例第 4 段「卷绕头模组-聂元克」形态推断 **X=4**，且该段需按 `-` 再拆为「模组名称 / 姓名」 | medium | 出现模组主数据表，或第 4 段不含 `-` 的实际样例 |
| I-02 | F-21, R-12 | M 与 N 同写「第 5 个字段」必有一处笔误；按段序语义推断 **N=第 6 段（8月5号）、M=第 7 段（第三批）** | medium | 用户确认另一种映射，或出现段数不同的实际数据 |
| I-03 | F-21, R-03, R-11 | B 与 J 同写「第 1 个字段」必有一处笔误；B=第 1 段（李怡静）与样例人名语义相符，故 J 应指向其他段位（第 2 段「WA41」语义不符） | low | 用户给出 J 的目标段位或新的备注样例 |
| I-04 | F-21, R-09 | H「T100 单据备注」与 B/F/J/K/L/M/N 引用的「单头备注」很可能同源 = 拣料单 `T100Remark` 整串；H 展示整串、其余列展示分段 | medium | 用户说明 H 取明细行备注 |
| I-05 | R-10, R-01 | 若一行 = 一条明细行，「项数」将恒为 1 而无意义 ⇒ 行粒度应为 **单号 × 项目号 × 模组号 的分组级** | medium | 用户确认粒度为「一条拣料单一行」或「一条明细一行」 |
| I-06 | F-22 | `+` 分段是据点自定义填单习惯而非系统保证；LEBGJS 实际命中率可能与 LEBGJM 完全不同，必须实测后才能评估本报表可用性 | medium | 在 LEBGJS 取样后得到高命中率 |
| I-07 | F-18, F-10 | 主同步链路写入的 `OutStockPickOrder.T100Remark` 取自 `delivery.T100Remark`，而该字段新建出库单时为空，因此报表依赖的备注可能在真实数据里大面积为空 | medium | 取样发现拣料单 `T100Remark` 填充率较高（说明数据主要来自补生成链路） |

## 4. Behavior

| 场景 | 触发 / 前置 | 系统行为 | 可观察结果 |
|---|---|---|---|
| Normal | 用户选时间范围（沿用 3 个月门禁）、可选填 T100 全模糊关键字，点查询 | 以拣料单为主表分页返回；每行按 D-05 粒度聚合；18 列按冻结段位规则 + 四段业务数据拼装 | 页面表格展示；导出按钮生成 Excel 并下载 |
| Failure | 备注为空或段位不足 | 该行备注派生列留空，其余列照常返回 | 不报错、不丢行、不补位错位 |
| Failure | 备注含全角 `＋` 或多余空格 | 按半角 `+` 精确切分，未命中即视为段位不足 | 同样留空，不做智能纠错（保证可解释） |
| Duplicate / Retry | 同一用户重复点击导出 | 复用既有按用户加锁机制 | 重复请求被拒绝或串行执行；不产生半截文件对外暴露 |
| Boundary | 查询跨度 > 3 个月，或导出行数超上限 | 返回既有门禁错误文案 | 明确报错，不静默截断 |
| Boundary | 该拣料单在回单登记中无记录 | 按 D-08 冻结口径展示 | 空值不与「已登记未确认」混淆 |
| Boundary | 同一 (单号, 项目号, 模组号) 分散在多条拣料单 | 按 D-05 粒度决定合并或各自成行 | 与 AC-01 一致 |

**一致性**：本期只读——不写入拣料单、出库单、领料单、回单登记等任何业务表，不新增定时任务，不修改既有报表实现。备注解析在查询期内存完成，不落库、不缓存，故不存在与源数据不一致的窗口。

**权限**：沿用参考实现现状——不给新控制器加权限特性，不写 `sys_role_menu`，页面可见性由 `sys_menu` 行本身控制（与出库综合报表一致）。

## 5. Business Rules

- [B-01] 备注解析对象为拣料单 `T100Remark` 整串，按半角 `+` 切分为段位数组 — Source: R-03/R-11/R-12 联合 + F-21 样例结构
- [B-02] 段位不足时对应列留空，不报错、不阻塞、不丢行 — Source: 备注为人工填写，缺段是常态（合理推断）
- [B-03] 多值字段（备料人/转运人/清点人）按**分号**拼接并去重 — Source: 需求 Excel 第 7 行明确「多个，分号拼接」；**与现网一律逗号先例不一致（F-13）**，差异见 K-08
- [B-04] 沿用既有查询门禁：时间跨度上限 3 个月、导出行数上限 500000、分批 100000 — Source: F-04
- [B-05] C/E/D 三列直接取真实字段（`SyncCode`/`ModuleNo`/`ProjectNo`），不经备注解析 — Source: F-10/F-11
- [B-06] Q/R 取拣料单备料字段，U/V 取领料确认字段，P 取回单登记 — Source: F-10/F-14/F-17
- [C-01] 必须在每个方法内部获取 `IReportDbScopeProvider.GetScope()`，不得跨方法传递 `SqlSugarScopeProvider`（会破坏全局 `IDeletedFilter`）— Source: F-25
- [C-02] 本期只读，禁止写入任何业务表 — Source: R-17 展示型需求 + 用户「先出方案不动业务代码」的边界
- [C-03] 新增文件的 `sys_menu.Component` 必须与前端 `defineOptions name` 完全一致（`Path==Component`，A 型）— Source: F-07/F-09
- [C-04] 不得修改既有报表实现文件，避免回归 — Source: 参考实现是现网在跑代码
- [C-05] 不手写 `approval.html`，不手工编辑 `logs/INDEX.md`，不新增权限特性 — Source: task-spec 契约 + F-05 + task-log 规则
- [C-06] 查询必须显式排序，不得复刻参考实现的无 ORDER BY 缺陷 — Source: F-03

> 不得把 Inference 当作已确认规则；I-01～I-05 的结论在 D-01～D-05 获批前不得写入实现。

## 6. Scope / Out of Scope

### In Scope

1. **服务层**：新增展示 DTO、查询 DTO、导出 DTO、服务接口、服务实现（含备注分段解析与四段业务数据批量补齐）。
2. **应用层**：新增报表控制器（路由族归属见 D-11）。
3. **前端**：新增 `src/api/reports/<x>.js`、`src/views/reports/<x>/{index.vue,schemas.tsx,typings.d.ts}`。
4. **数据库**：`sql/publish/v1.3.8.3/` 下菜单插入脚本 + `sql/logs/2026-09-23/` 变更说明 + `sql/index.md` 追加一行。
5. **任务日志**与 `logs/_entries/` 片段。

### Out of Scope

1. **PDA 端任何改动**：P 列依赖的「回单登记 PDA 功能」已存在（F-17），本报表只读消费。
2. **写链路与 T100 同步链路**（含 F-18 的 `T100Remark` 口径不一致问题）——除非 D-07 选 B，否则不得改同步代码。
3. 历史数据回填与备注补录。
4. 模组主数据建设（F-12 的缺口不在本期解决）。
5. T100 侧填单习惯治理：不推动业务方改备注格式。
6. **既有报表的任何重构**（含 F-03 无 ORDER BY、F-24 重复表头等既有缺陷，仅记录不修）。
7. 权限体系改造。

## 7. Risks / Edge Cases

| ID | 触发 | 影响 | 缓解 / 验证 | 需决策 |
|---|---|---|---|---|
| K-01 | LEBGJS 实际备注不遵循 `+` 分段约定，或段数不足 | B/F/J/K/L/M/N 七列大面积留空，报表核心价值落空 | **上线前必须在 LEBGJS 取样**：备注非空率、含 `+` 率、段数分布、各段取值样例。Go/No-Go 前置证据 | yes |
| K-02 | F-18：两处写入链路口径不一致，主链路写入的是出库单上恒为空的字段 | 即使填单规范正确也没有数据可解析 | 与 K-01 同批取样：统计 `outstock_pick_order.T100Remark` 非空率，并与 `outstock_delivery.Remark` 交叉比对；若主链路为空需另立任务修复同步口径（本期范围外） | yes |
| K-03 | `.env` 无 `PROD_LEBGJS_*` 路由 | 依赖真实数据的 AC 无法本地验证 | 由用户/DBA 提供 LEBGJS 取样结果作为附件证据；本地以构造样例驱动（AC-03） | yes |
| K-04 | 需求文本自相矛盾（M/N 同段、B/J 同段、F 的 X 空缺、H 归属） | 实现必然与业务预期不符，属返工而非缺陷 | D-01～D-04 全部 `blocking: true`，未确认前不得进入实现 | yes |
| K-05 | D-05 行粒度选错 | 主查询分组、项数语义、导出结构、前端表格全部重做 | D-05 标记 `blocking: true`，实现前冻结 | yes |
| K-06 | S/T 选错载体表（F-15 三套并存） | 转运两列取到错误业务段，且与出库综合报表口径不一致 | D-09 给推荐并请用户确认；实现时在代码注释写明所选表与字段来源 | yes |
| K-07 | F-17：回单主体是工号，明细才关联拣料单，未登记单据无从反查 | P 列大面积空值，可能被误读为「未收回」 | D-08 明确空值展示口径（建议展示为空而非「未收回」） | yes |
| K-08 | 需求要分号，现网所有报表用逗号（F-13） | 同一字段在不同报表分隔符不同，下游二次加工需特判 | 按需求执行分号（D-10 已记录依据）；若认为应统一为逗号，审批页直接改写该 Decision | no |
| K-09 | 照抄参考实现的无 ORDER BY、重复 `[DisplayName]`、1900-01-01 清洗样板 | 新报表继承分页不稳、导出表头重复 | C-06 强制显式排序；Reference Code Assessment 已逐项标注 do-not-reuse | no |
| K-10 | D-07 选择「同步层物化解析记录表」 | 需 DDL、回填、对账、回滚，复杂度升为 L4，本 Package 前提（只读、无迁移）失效 | 本 Spec 默认按方案 A 编写；若选 B 必须另开 r02 revision | yes |

## 8. Technical Direction

- **Contract boundary**：新增独立报表契约，不改动既有报表接口。后端新增展示 DTO（仅 XML `<summary>`）+ 查询 DTO + 导出 DTO（`[DisplayName]`/`[ExcelFormat]`/`[ExcelIgnore]`）；控制器路由族归属见 D-11，推荐对齐较新的 `reports/<kebab>/{query|export}` 风格而非旧族。导出沿用「返回相对路径 + 文件名，由前端 `download` 下载」的既有契约，**不采用** `File` 字节流写法。
- **State / data direction**：以 `outstock_pick_order` 为主表，LeftJoin `outstock_delivery`（`a.DeliveryId == b.Id`，与参考实现同路径以保持口径），主查询内用 `EXISTS` 子查询完成粗粒度过滤；分页后在 `FillXxxDataAsync` 阶段按主键批量补齐四段数据：备料（拣料单自身字段）、转运（F-15 三表之一，按 D-09 冻结）、领料确认（`outstock_receive_detail`）、回单登记（`operations_order_return_registration_detail` + 主表状态）。备注解析在补齐阶段对已批量取回的 `T100Remark` 做内存 `Split('+')`，**不落库、无迁移、完全可逆**。
- **方案 A（默认，推荐）**：查询期内存解析。不动数据模型、无迁移、口径可随规则调整立即生效、失败可回退；缺点是每次查询都要解析，且无法对解析质量做持久化巡检。对一张上限 3 个月、导出上限 50 万行的报表，字符串切分开销可接受。
- **方案 B（备选，需用户明确选择）**：新增解析记录表（单据 Id、同步单号、解析出的各字段、`ParseStatus`、`ParseRuleVersion`），在 T100 出库单据同步时落库，报表改为关联查询。优点是可质量巡检、可回填、查询更快；**前置条件是段位规则先定死**（即 D-01～D-04 必须先有结论），否则 `ParseRuleVersion` 会随规则反复变更，且需要 DDL、历史回填、对账与回滚方案，复杂度升级为 **L4**。本 revision 不按此方案实现。
- **Dependency order**：冻结 D-01～D-05（blocking）→ 冻结 D-06～D-11 → 后端契约与服务实现（含取样驱动的手工验证）→ 前端页面与 schema → 菜单 SQL 与文档 → 集成核对（Component/name 一致性、导出列与页面列一致性）。
- **Candidate code anchors**：`OutStockOrderReportService.cs:136-238`、`:243-446`；`OutStockDifferencePickReportService.cs`；`OutStockShipmentReportController.cs:6`、`:27`、`:40`、`:52`；`Services.Report/Services/ReportQueryPolicy.cs`；`IMTC.WMS.AdminUI/src/views/reports/outstock-order-report/{index.vue,schemas.tsx,typings.d.ts}`；`sql/publish/v1.3.8.3/2026-09-21_add_outstock_difference_pick_report_menu.sql`。
- **Style Contract**：`PROJECT + PERSONAL` — 遵循 AdminWebApi（SqlSugar + Mapster + `ITransient` + `IReportDbScopeProvider`）、`Application.Report` 控制器、AdminUI（Vue3 + `@/lebg/components` + `useTable` + `FormSchema`/`TableColumn`）三层既有结构与命名习惯；复用既有全局 `DateTimeJsonConverter`，不为日期列单写 formatter。

> 本节只收敛实现方向与契约边界，不写方法级步骤、伪代码或完整代码实施 Plan。

## 9. Reference Code Assessment

| 参考 | 相似性 | 可复用 | 不应复用 | 质量/遗留 | 架构适配 | 风格适配 |
|---|---|---|---|---|---|---|
| `OutStockOrderReportService.cs`（REF-01） | 同域同层同形态：拣料单主表 + 出库单 LeftJoin + 多段批量补齐 + 分页 + 分批导出 | 整体骨架（`BuilderMainQuery`/`ToPageAsync`/`FillOrderDataAsync`/`EnumerateExportRows`）、按用户加锁的导出、门禁校验、`ToLookup`/`ToDictionary` + `DistinctBy`/`MaxBy` 聚合 | 无 ORDER BY 的分页（F-03）；重复 `[DisplayName]` 导致导出表头重复（`:173/:179`、`:198/:204`）；`QueryDto` 与 `PagedQueryDto` 90% 重复且已漂移；错误文案硬编码 `/10000`；1900-01-01 清洗样板 | 现网主力报表，逻辑完整但带历史堆积 | 高：同层同域，依赖注入与作用域获取方式可直接沿用 | 高 |
| `OutStockDifferencePickReportService.cs`（REF-02） | 同为明细级备料/领料/配送多段时间列实现，已有备料人在明细为空时回退整单拼接 | 明细级备料人/领料人/配送人多值聚合与去重写法（`:462`、`:469-479`） | 同样缺少稳定排序；多值拼接用逗号（与 B-03 相反） | 较新，结构比 REF-01 清爽 | 高 | 高 |
| `OutStockShipmentReportController.cs:6,27,40,52`（REF-03） | 较新路由族 `reports/<kebab>/{query\|export\|enums}`，代表项目演进方向 | 路由命名与动词选择，作为 D-11 推荐依据 | 同目录 `ReceiptReportController.cs:41` 返回 `File` 字节流的写法——与前端既有 `download(path/fileName)` 契约不兼容 | 新 | 高，代表未来方向 | 高 |
| `sql/publish/v1.3.8.3/2026-09-21_add_outstock_difference_pick_report_menu.sql`（REF-04） | 同一目标：为新报表插入菜单行 | 完整脚本形态（父锚点 `COUNT(*)=1` 失败关闭校验、`OrderNum=MAX+1`、`Path==Component`、无 F 按钮、无 `sys_role_menu`） | 候选雪花 Id 需按本期日期重编，不得沿用旧 Id | 新，且已在本分支 v1.3.8.3 目录内 | 高 | 高 |
| `views/reports/outstock-order-report/*`（REF-05） | 同形态：搜索区 + 表格 + 导出按钮 | `useTable` 用法、导出 `download(...)` 调用形态、`getSearchSchema`/`getTableSchema` 结构与 `formatXxx` 辅助函数位置、`defineOptions name` 约定 | 日期列无需自定义 formatter（全局 `DateTimeJsonConverter` 已处理） | 新 | 高 | 高 |
| `OperationsOrderReturnRegistrationService.cs:511,536,547`（REF-06） | 回单登记与拣料单的关联路径定义处 | 按拣料单反查回单的键（`detail.PickOrderId`）与「已收回」判定（主表 `Status=BusinessCompleted`） | 该服务是写入方；本报表只读其表，不调用其写方法 | 新 | 中：跨服务域读表，需直接查表而非依赖该服务 | 中 |

> `Existing Pattern != Recommended Standard` — 上表「不应复用」列的每一项都必须在 review 阶段逐条核对。

## 10. Open Decisions

| ID | 决策 | 选项 | 推荐 | 用户决定 | 阻塞 |
|---|---|---|---|---|---|
| D-01 | M 批次 与 N 开单下料时间 均写「第 5 个字段」，正确段位是？ | A) N=第 6 段、M=第 7 段 / B) 都取第 5 段 / C) 其他 | A（推断 I-02） | PENDING | **yes** |
| D-02 | B 负责PC 与 J 总装/部装 均写「第 1 个字段」，J 取第几段？ | A) B=第 1 段、J=第 ? 段（需指明） / B) 其他 | 需用户指明（I-03 置信度低，无法自行收敛） | PENDING | **yes** |
| D-03 | F 模组名称 的 X 未填，且第 4 段内含 `-`；X 取几、是否再拆？ | A) X=4 并按 `-` 再拆 / B) X=4 整段不拆 / C) 其他 | A（推断 I-01；F-12 已排除其他来源） | PENDING | **yes** |
| D-04 | H 单据备注 与「单头备注」是否同一字段？ | A) 同源，H 为整串原文 / B) 不同源，H 取明细行备注 / C) 其他 | A（推断 I-04） | PENDING | **yes** |
| D-05 | 报表一行代表什么粒度？ | A) 单号 × 项目号 × 模组号 分组 / B) 一条拣料单 / C) 一条明细行 | A（推断 I-05：C 会使「项数」恒为 1；B 与 I 列说明不符） | PENDING | **yes** |
| D-06 | I 项数口径？ | A) 明细行数 / B) 去重物料数 / C) 标签数 | A（既有先例 F-19） | 已自动收敛 | no |
| D-07 | 备注解析放哪一层？ | A) 查询期解析 / B) 同步层物化解析记录表 | A（B 前置条件是段位先定死，且升为 L4，需另开 r02） | PENDING | no |
| D-08 | 回单登记查无记录时 P 是否收回怎么展示？ | A) 空 / B) 未收回 / C) 未登记 | A 或 C（F-17：未登记是常态，不应等同未收回） | PENDING | no |
| D-09 | S/T（及 A）取哪张表？ | A) S/T 取 `outstock_warehouse_delivery`、A 取 `operations_order_delivery` / B) 用户指定组合 | A（F-16；但「物料配送」一词同时对应 (c) 的表名，需确认） | PENDING | no |
| D-10 | 多值字段分隔符？ | A) 分号（需求明确） / B) 逗号（与现网一致） | A，并记录与 F-13 的差异 | 已自动收敛 | no |
| D-11 | 搜索条件与路由族形态？ | A) 保留时间范围 + 仅新增 T100 全模糊；路由对齐新族 / B) 其他 | A（用户原始需求已明确搜索条件形态；路由取 REF-03 新族） | 已自动收敛 | no |

只有 `user-required` 且 `blocking: true` 的项（D-01～D-05）阻塞计划级批准。

## 11. Acceptance Criteria

- [ ] **AC-01** — Given 已登录用户进入报表页，when 选择时间范围并查询，then 按 D-05 冻结粒度返回数据，一行含 A–W 中 18 个可见列且 G/O/W 不出现；追溯 `R-01/R-08/D-05`。
- [ ] **AC-02** — Given 一条已知拣料单，when 查询该单，then C/E/D 三列分别等于 `outstock_pick_order.SyncCode`、`outstock_pick_order_detail.ModuleNo`、`ProjectNo`，取值不经备注解析；追溯 `R-04/R-05/R-06/B-05`。
- [ ] **AC-03** — Given 备注为截图样例 `李怡静+WA41+1.5北区+卷绕头模组-聂元克+李想+8月5号+第三批`，when 解析，then 结果与 D-01～D-04 冻结的段位规则逐列一致；追溯 `R-03/R-07/R-09/R-11/R-12/D-01..D-04`。
- [ ] **AC-04** — Given 备注为空 / 仅 3 段 / 7 段 / 8 段四种输入，when 解析并展示，then 段位不足的列返回空值，查询不报错、不丢行、不发生补位错位；追溯 `B-02`。
- [ ] **AC-05** — Given 备注含全角 `＋` 或多余空格，when 解析，then 按半角 `+` 精确切分，未命中即视为段位不足并留空，不做智能纠错；追溯 `B-01/B-02`。
- [ ] **AC-06** — Given 点击导出，when 后端生成完成，then 前端经 `download(res.data.path,{name,fileName,target:'report'})` 下载成功，导出列与页面列一致且**表头无重复**；追溯 `R-01/F-08/F-24`。
- [ ] **AC-07** — Given 查询跨度 > 3 个月或导出行数超上限，when 提交，then 返回既有门禁错误文案，不静默截断；追溯 `B-04`。
- [ ] **AC-08** — Given 同一单据存在多个备料人/转运人/清点人，when 展示，then 按**分号**拼接且同值去重；R 备料人取自明细 `PickUser` 集合；追溯 `R-14/B-03/D-10`。
- [ ] **AC-09** — Given 已登记已确认 / 已登记未确认 / 未登记三类单据各一，when 查询，then P 是否收回分别按 `Status=BusinessCompleted` 与 D-08 冻结口径展示；追溯 `R-13/F-17/D-08`。
- [ ] **AC-10** — Given 同一查询条件，when 连续两次分页，then 结果顺序一致（存在显式稳定排序）；追溯 `C-06/K-09`。
- [ ] **AC-11** — Given 菜单脚本在干净库上执行，when 重复执行两次，then 只存在 1 行新 `sys_menu`（幂等），`Path==Component` 且与前端 `defineOptions name` 完全一致，无 F 按钮行、无 `sys_role_menu` 写入；追溯 `C-03/F-07/F-09`。
- [ ] **AC-12** — Given 已分配菜单权限的用户，when 从菜单进入，then 页面正常渲染、中文列名无乱码、导出按钮可用；追溯 `R-01`。
- [ ] **AC-13** — Given 本次变更的 diff，when 核对，then 未修改 `OutStockOrderReportService` 等既有报表文件，既有报表页面与导出行为不变；追溯 `C-04`。
- [ ] **AC-14** — Given D-07 选 A，when 核对 diff，then 不含任何业务表写操作、不含 DDL（菜单 SQL 的 `sys_menu` 插入除外）；追溯 `C-02/D-07`。

## 12. Implementation Boundary

- **Requirement source of truth**：本 Plan Package 的 APPROVED revision（r01）；批准结果只写入该 revision 的 `approval.json`，不得修改已批准 package。
- **Project / evidence baseline**：`project_id=http://10.10.80.231:8052/hjh1126123/wms`；`evidence_baseline=worktree .claude/worktree/prep-material-report @ feature/lyp/prep-material-report HEAD 3a59b94fc08323eb4ed161b786121fec3c37482f`。若 HEAD 或需求源 Excel 变化，先重验受影响 Fact、Scope 与 AC 再执行。
- **Allowed Plan Mode responsibility**：`HOW / FILES / METHODS / IMPLEMENTATION STEPS`。
- **Prohibited redefinition**：已批准的行为、业务规则、段位映射、范围与排除项、约束、兼容性要求、AC 均不得由实现方重新定义；**尤其不得在实现时自行猜测 D-01～D-05 的答案**。
- **Read boundary**：`AdminWebApi/Services/Services.Report/**`、`Application/Application.Report/**`、`Domain/Domain.Warehouse/Entities/OutStock/**`、`Domain/Domain.Operations/Entities/**`、`Domain/Domain.Shared/**`；`AdminUI/src/views/reports/**`、`src/api/reports/**`、`src/store/modules/permission.js`；`sql/publish/**`、`sql/logs/**`、`sql/index.md`；`logs/**`（只读参考）。
- **Expected write boundary**：以**新增文件**为主——`Services.Report` 下报表三件套、`Application.Report` 下新增控制器、AdminUI 下新增 api/views/schemas、`sql/publish/v1.3.8.3` 下新增菜单脚本、`sql/logs/2026-09-23` 下新增说明、`sql/index.md` 追加一行。不得无限制写入；不得修改既有报表实现文件。
- **Stop conditions**：出现以下任一必须停止并回到用户——1) D-01～D-05 任一仍 PENDING；2) 取样发现 LEBGJS 备注结构与本 Spec 假设冲突；3) 需要改同步链路或业务表才能满足 AC（即被迫选择方案 B）；4) 证据冲突导致 AC 不成立；5) 需要扩大写入范围到既有报表文件或 PDA 端。
- **Verification boundary**：必需检查——编译通过（**仅在用户明确要求时**执行 build）、AC-03 样例断言、菜单 SQL 幂等执行、页面实际打开。需额外授权——连接生产/测试库取样、执行任何 DDL、运行 build。

## Plan Package 交接

- `package_path`：`C:\Users\liyanpeng\.claude\skills\task-spec\20260923-prep-material-report\r01\`
- 必需文件：`plan.md`、`plan-package.json`、`approval.html`、`approval.json`。
- Decision 字段：`resolution: auto-resolved | user-required`；只有 `user-required` 且 `blocking: true` 的项阻塞批准（本 Spec 为 D-01～D-05）。
- 审批页面由脚本生成，页面导出 `approval-input.json`；脚本校验后写入 `approval.json`。
- `task-execute` 只能读取与 `approval.json` 精确匹配的 `APPROVED` revision。
- **执行包**：`PKG-01-backend-report` → `PKG-02-frontend-report`、`PKG-03-menu-and-sql-docs`（后两者依赖 PKG-01，写集互不重叠可并行）。

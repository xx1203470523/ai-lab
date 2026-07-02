# task-execute 示例

## 示例 1: 完整执行流程（Complex）

### 输入

> /task-execute

### Step 0: 计划选择

```
## 可执行计划

### 待执行 (pending)
- `task-20260703-1430-wms-inbound-query.md` — 实现 WMS 入库单查询功能（3 packages）
- `task-20260703-1600-trade-feishu-summary.md` — 飞书持仓汇总通知（1 package，Simple）

### 可续跑 (running)
- `task-20260702-0900-wms-stock.md` — 库存盘点功能（pkg-01 done, pkg-02 pending）

请选择要执行的计划：
```

用户选择 `task-20260703-1430-wms-inbound-query`

### 执行过程

```
Step 1: 前置检查通过
  - 项目: wms (E:\My\project\wms)
  - manifest 文件: 8/8 存在

Step 2: 开始执行
  包 pkg-01（数据层：入库单查询 Entity + Repository）
    → Agent 启动 (skill: wms-backend-dev)
    → Agent 完成: 3 files modified
    → 验证通过 → done

  包 pkg-02（业务层：入库单查询 Service + DTO）
    → Agent 启动 (skill: wms-backend-dev)
    → Agent 读取前序包输出: Entity 定义
    → [ESCALATE] 扩散检索已达 3 次上限
      已检索: StockInRepository.cs, BaseService.cs, QueryHelper.cs
      缺失信息: 不确定分页参数是否需要兼容旧接口
      建议: 需确认是否保持旧接口签名
    → 等待主会话确认...

--- 用户选择：批准继续，配额重置 ---

    → Agent 继续执行
    → Agent 完成: 2 files modified
    → 验证通过 → done

  包 pkg-03（接口层：入库单查询 Controller API）
    → Agent 启动 (skill: wms-backend-dev)
    → Agent 完成: 1 file modified
    → 验证通过 → done

Step 3: 完成汇总
  全部 3/3 done
```

---

## 示例 2: 中断恢复

### 场景

上次执行时包 pkg-01 完成，pkg-02 开始前用户关闭了会话。

### 输入

> /task-execute 继续执行

### Step 0c: 续跑判断

```
plan.status = running，续跑模式
已完成: pkg-01 (done)
待执行: pkg-02 (pending), pkg-03 (pending)
从 pkg-02 继续
```

### 执行

跳过 pkg-01，直接从 pkg-02 开始。

---

## 示例 3: Simple 模式直接执行

### 输入

> /task-execute task-20260703-1600-trade-feishu-summary.md

### Step 0d

```
mode: simple, 1 package → Simple 执行模式
不启 Agent，主会话直接处理
```

### 执行

主会话读取 manifest（`knowledge/patterns/prompt-eng.md`），
直接按 Task Contract 实现飞书通知函数，
完成后更新 plan 状态。

---

## 示例 4: 计划状态查询

### 输入

> 查看 task-20260703-1430-wms-inbound-query 的执行状态

### 输出

读取 plan 文件的任务日志：

```
## 任务日志

| 包 | 状态 | Agent | 开始时间 | 完成时间 | 备注 |
|----|------|-------|----------|----------|------|
| pkg-01 | done | a1b2c3 | 07-03 14:35 | 07-03 14:42 | 3 files, Entity + Repository |
| pkg-02 | done | d4e5f6 | 07-03 14:45 | 07-03 15:02 | 2 files, Service + DTO（含1次ESCALATE） |
| pkg-03 | pending | - | - | - | - |

进度: 2/3 done，下次从 pkg-03 继续
```

---

## 示例 5: blocked 后处理

### 场景

包 pkg-01 因扩散检索超限被标记 blocked。

### 任务日志

```
| pkg-01 | blocked | g7h8i9 | 07-03 14:30 | - | 阻塞: 扩散检索超限。需确认: 是否读取 ConfigService.cs。建议: 批准继续 |
| pkg-02 | pending | - | - | - | - |
```

### 用户处理

用户补充 manifest → 重置 pkg-01 为 pending → 重新执行。

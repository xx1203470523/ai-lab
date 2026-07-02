# task-plan 示例

## 示例 1: WMS 后端任务（Complex）

### 输入

> 实现 WMS 入库单查询功能，包括根据单号、供应商、日期范围筛选，支持分页

### Step 0.5 复杂度评估

| 维度 | 判断 |
|------|------|
| 知识域 | 1 个（入库） |
| 层级 | 3 层（Entity → Service → Controller） |
| 跨端 | 否 |
| 范围 | 明确 |
| 结论 | **Complex → 3 packages**（跨层 3 层） |

### Step 1 知识索引命中

```
命中: 入库,入库单,收货,WMS_StockIn → project/wms/knowledge/backend/
项目上下文: knowledge/domains/wms.md
```

### Step 2.5 技能分配

全部 3 个包的 `skill` 都是 `wms-backend-dev`

### 生成的计划文件

```yaml
---
plan_id: task-20260703-1430-wms-inbound-query
created: 2026-07-03T14:30:00
status: pending
mode: complex
project: wms
description: "实现 WMS 入库单查询功能"
packages:
  - id: pkg-01
    name: "数据层：入库单查询 Entity + Repository"
    skill: wms-backend-dev
    domain: "入库/StockIn"
    layer: data
    status: pending
    depends_on: []
    manifest:
      knowledge: ["project/wms/knowledge/backend/"]
      rules:
        - "project/wms/skills/wms-backend-dev/rules/entity.rules.md"
        - "project/wms/skills/wms-backend-dev/rules/repository.rules.md"
      packs:
        - "project/wms/skills/wms-backend-dev/rules/packs/entity-field.rules.md"
        - "project/wms/skills/wms-backend-dev/rules/packs/repository-query.rules.md"
      patterns: []
    boundaries:
      allow_read: ["IMTC.WMS.AdminWebApi/"]
      allow_write: ["IMTC.WMS.AdminWebApi/"]
      forbid: ["IMTC.WMS.AdminUI/", "IMTC.WMS.PDA/"]
    contract:
      in_scope: "入库单查询的 Entity 字段定义、Repository 查询方法（筛选+分页）"
      out_of_scope: "Service 层、Controller 层、前端、PDA"
      expected_files: "2-4"
      stop_condition: "需要修改 Service 或 Controller 时停止并回报"
  - id: pkg-02
    name: "业务层：入库单查询 Service + DTO"
    skill: wms-backend-dev
    domain: "入库/StockIn"
    layer: business
    status: pending
    depends_on: ["pkg-01"]
    manifest:
      knowledge: ["project/wms/knowledge/backend/"]
      rules:
        - "project/wms/skills/wms-backend-dev/rules/service.rules.md"
      packs:
        - "project/wms/skills/wms-backend-dev/rules/packs/service-dto.rules.md"
      patterns: []
    boundaries:
      allow_read: ["IMTC.WMS.AdminWebApi/"]
      allow_write: ["IMTC.WMS.AdminWebApi/"]
      forbid: ["IMTC.WMS.AdminUI/", "IMTC.WMS.PDA/"]
    contract:
      in_scope: "入库单查询的 DTO 定义（入参/出参）、Service 查询编排逻辑"
      out_of_scope: "Entity 定义、Controller 层、前端"
      expected_files: "2-4"
      stop_condition: "需要修改 Entity 定义时停止并回报"
  - id: pkg-03
    name: "接口层：入库单查询 Controller API"
    skill: wms-backend-dev
    domain: "入库/StockIn"
    layer: interface
    status: pending
    depends_on: ["pkg-01", "pkg-02"]
    manifest:
      knowledge: ["project/wms/knowledge/backend/"]
      rules:
        - "project/wms/skills/wms-backend-dev/rules/controller.rules.md"
      packs:
        - "project/wms/skills/wms-backend-dev/rules/packs/controller-route.rules.md"
        - "project/wms/skills/wms-backend-dev/rules/packs/controller-auth.rules.md"
      patterns: []
    boundaries:
      allow_read: ["IMTC.WMS.AdminWebApi/"]
      allow_write: ["IMTC.WMS.AdminWebApi/"]
      forbid: ["IMTC.WMS.AdminUI/", "IMTC.WMS.PDA/"]
    contract:
      in_scope: "入库单查询 API 端点、权限码、路由注册"
      out_of_scope: "Service 实现、Entity 定义、前端"
      expected_files: "1-2"
      stop_condition: "需要修改 Service 逻辑时停止并回报"
total_packages: 3
---
```

---

## 示例 2: 通用项目任务（Simple）

### 输入

> 在 trade 项目中增加一个飞书通知函数，用于发送每日持仓汇总

### Step 0.5 复杂度评估

| 维度 | 判断 |
|------|------|
| 知识域 | 1 个（飞书通知） |
| 层级 | 1 层（business，无数据层和接口层变化） |
| 跨端 | 否 |
| 范围 | 明确 |
| 结论 | **Simple → 1 package** |

### 生成的计划文件

```yaml
---
plan_id: task-20260703-1600-trade-feishu-summary
created: 2026-07-03T16:00:00
status: pending
mode: simple
project: trade
description: "增加飞书通知函数用于每日持仓汇总"
knowledge_sources:
  - ai-lab://knowledge/domains/trade.md
packages:
  - id: pkg-01
    name: "飞书每日持仓汇总通知"
    skill: ""
    domain: "飞书通知"
    layer: business
    status: pending
    depends_on: []
    manifest:
      knowledge: []
      rules: []
      packs: []
      patterns:
        - "knowledge/patterns/prompt-eng.md"
    boundaries:
      allow_read: ["E:\\My\\project\\trade\\"]
      allow_write: ["E:\\My\\project\\trade\\python\\chaogu\\notify\\"]
      forbid: []
    contract:
      in_scope: "新增一个发送每日持仓汇总飞书通知的函数，复用 FeishuNotifier"
      out_of_scope: "持仓数据采集逻辑、前端展示"
      expected_files: "1-2"
      stop_condition: "需要修改持仓数据采集逻辑时停止并回报"
total_packages: 1
---
```

---

## 示例 3: 通用项目（无知识索引）

### 输入

> 给这个 Node.js 项目加一个日志中间件，记录请求方法、路径、耗时

### 处理

1. 项目无 `knowledge/INDEX.md` → 触发**通用项目回退**
2. 从任务描述推断：
   - 核心名词：日志中间件、请求
   - 操作：记录（只读不写业务数据）
   - 层级：interface（中间件属于请求处理层，对外暴露的横切关注点）
3. 知识来源标注为 `"task-description"`
4. 技能：无（通用项目，skill 留空）

```yaml
---
plan_id: task-20260703-1700-nodejs-log-middleware
created: 2026-07-03T17:00:00
status: pending
mode: simple
project: general
description: "添加请求日志中间件"
knowledge_sources:
  - "task-description"
packages:
  - id: pkg-01
    name: "请求日志中间件"
    skill: ""
    domain: "日志/中间件"
    layer: interface
    status: pending
    depends_on: []
    manifest:
      knowledge: []
      rules: []
      packs: []
      patterns: []
    boundaries:
      allow_read: ["./"]
      allow_write: ["./"]
      forbid: []
    contract:
      in_scope: "实现日志中间件，记录请求方法、路径、耗时"
      out_of_scope: "日志持久化、监控告警、认证授权"
      expected_files: "1-2"
      stop_condition: "需要修改路由或认证逻辑时停止并回报"
total_packages: 1
---
```

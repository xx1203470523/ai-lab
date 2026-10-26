# 平台陷阱（已实测确认，非推测）

这些结论来自对 `10.10.76.109:5700`（QingLong v2.19.2）的实际探测与源码行为比对。改动脚本前先读这一份。

## 调度语义

- `isNodeCron = 段数 > 5 || extra_schedules`。**6 段走进程内 node-schedule，5 段写进容器系统 crontab。**
- 本部署容器里 crond 没在跑，所以 **5 段表达式的任务从不触发**，`isDisabled=0` 也一样。这不是「跑得少」，是「一次都不会跑」。
- 因此 `ql.ps1` 硬拒绝 5 段，不做兼容。
- `p-queue` 并发上限 `max(CPU, 4)`。同一 cron id 排队超过 5 次，触发器被丢弃并只发通知，不报错。

## 任务对象

- 状态字段实际是 `isDisabled`（0 启用 / 1 停用）。`status`（0 运行中 / 0.5 排队 / 1 空闲 / 2 停用）**对「计划是否生效」不可靠**，判断启停只看 `isDisabled`。
- `last_execution_time` 是 **Unix 秒**，不是毫秒。`createdAt` 是 **ISO 字符串**（如 `2026-09-22T02:55:35.918Z`），不是数字。
- 唯一索引在 `name + command + schedule` 三列上。重复创建 → HTTP 500，响应体里 `code=400`。
- `POST /crons` 的 Joi 白名单只有 `name, command, schedule, labels, sub_id, extra_schedules, task_before, task_after`。**创建时无法设置启停状态**，想建出来就是停用，只能 POST 之后补一次 disable。
- `PUT /crons` 是**整体替换**，必须带 `id` + `command` + `schedule`，漏字段会被拒。

## 请求体形状

- `PUT /crons/disable`、`PUT /crons/enable`、`PUT /crons/run`、`DELETE /crons` 的 body 是**裸 JSON 数组**（`[12]` 或 `["12"]`）。
- 传 `{"ids":[12]}` 会被 Joi 拒为 HTTP 400 `"value" must be an array`。这个报错完全不提 `ids`，极易误判成「不支持 PUT」。
- `DELETE /scripts` 的 body 是**对象** `{filename, path}`，与上面相反。

## 响应契约

- 成功：`{"code":200, "data":...}`。
- 失败：真实 HTTP 状态码 + `{"code", "message"}`。校验失败是 Hapi 风格 `{statusCode, error, message, validation}`。
- **部分操作对不存在的对象也回 `{"code":200}`**（如 `DELETE /scripts`、`PUT /crons/run`）。所以删除类操作**必须靠回读**判定，响应码不是证据。

## 日志

- `GET /logs` **忽略 `path` 参数并无条件递归**，在此数据量下必然超时。不要用。
- 正确用法：`GET /crons/:id/logs` 列表、`GET /crons/:id/log` 最新一篇、`GET /logs/detail?path=&file=` 指定文件。
- 日志目录名由 `getUniqPath` 生成，会把路径分隔符折叠成下划线：`BI/bi_pivot.js` + id 29 → `BI_bi_pivot_29`。

## 脚本

- `GET /scripts/:file` **不跨 `/` 匹配**，多段路径直接 404。
- `GET /scripts?path=<文件>` → 500（对文件调 `fs.readdir` 抛 ENOTDIR）。只能传目录。
- `GET /scripts?path=<目录>` 只返回**单层**，且 `children` 恒为 `[]`。要整棵树必须自己递归。
- 读内容的正确端点是 `GET /scripts/detail?file=&path=`。
- **路径越界不报错，返回 `{code:200, data:''}`**。空内容与不存在无法区分 → 判定存在性必须走目录列举。

## 认证

- `/open/*` 在服务端被重写为 `/api/*`，两者等价。
- 应用令牌是**纯 UUID**（不是 JWT），有效期 30 天，每个应用最多 5 个有效令牌。
- **令牌创建后无法再读回**，只能持久化到 `state/token.json`。丢了就重建应用。

## PowerShell 5.1 坑（本机无 pwsh）

- `Invoke-RestMethod -Body <字符串>` 按 **ISO-8859-1** 编码字符串，中文逐字变成 `?`。**必须传 UTF-8 字节**（`[System.Text.Encoding]::UTF8.GetBytes($json)`），否则任务名和脚本内容全部损坏。
- `$array | ConvertTo-Json` 走管道会**展开数组**，`@(31)` 变成 `31`。必须用 `-InputObject`。
- **空数组跨函数边界返回会被解包成 `$null`**，调用方 `.Count` 直接抛错。函数返回的数组一律 `@()` 兜底。
- `Set-StrictMode -Version 2.0` 禁止访问不存在的属性。可选字段一律经 `Get-QlProp`。
- `.ps1` 含非 ASCII 必须存成 **UTF-8 带 BOM**，否则被当 GBK 读、中文字面量损坏。JSON 文件则用**不带 BOM** 的 UTF-8。
- `[void]()` 会丢弃函数的所有成功流输出（含 `Write-Output`），调试时不要用它包住取值。

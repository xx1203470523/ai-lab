# 诊断

全部是 level 0 只读，不需要确认，不写平台。**只报事实与差值，不做因果推断**——根因要有证据链，不能从现象直接编故事。

## 第一步：全面体检

```powershell
& $ql -Verb diagnose
```

一次拿到：

| 字段 | 含义 |
|---|---|
| `total` / `enabled` / `disabled` | 任务总数与启停分布（按 `isDisabled` 判定） |
| `scheduleFormat` | **段数不等于 6 的任务**。本部署下这些任务从不触发 |
| `concurrency.maxConcurrent` | 展开 cron 后单分钟槽位的最大并发任务数，以及超过 `-Threshold` 的热点槽位 |
| `stale` | 已启用、但超过期望间隔 3 倍仍未执行的任务 |
| `stateDiff` | 期望态与平台的差异（不含 no-op） |
| `orphans` | 平台上有 `qls.key` 标签、但本地没有对应期望态文件的任务 |

## 第二步：按线索深入

- **某个任务该跑没跑** → `task.get -Id <id>` 看 `schedule` 段数与 `isDisabled`；段数是 5 就到此为止，结论是「调度路径不生效」，不要继续猜脚本问题。
- **想看它到底跑出什么** → `log.list -Id <id>` 列历史，`log.tail -Id <id>` 看最新一篇。`facts.running` 判是否还在跑，`facts.hasEndMark` 判是否正常收尾，`facts.lastErrorLines` 是脚本自己打出的失败行。
- **并发是否过载** → `diagnose` 的 `concurrency`。与 `reference/platform-traps.md` 里 `p-queue` 的队列上限对照。
- **任务与期望态不一致** → `state.diff`，逐行的 `diff` 指出差在哪个字段。

## 报告格式

给用户的诊断报告至少包含：

1. **结论**：一句话说清是什么问题，或者「未发现异常」。
2. **证据**：具体任务 id、字段值、日志行。不要只给判断不给依据。
3. **影响**：这个异常导致什么后果（例如「该任务从未触发，盘点计划不会自动生成」）。
4. **建议动作**：要改什么，以及这属于哪个级别、需不需要确认。**只建议，不要顺手改。**

## 已知结论（不要重复推导）

- 停用任务（`isDisabled=1`）长期没有执行记录是**正常**的，不是异常。判定「停滞」前必须先看 `isDisabled`。
- 5 段 cron 任务即使 `isDisabled=0` 也不触发。这是调度路径问题，不是脚本问题。
- `last_execution_time` 是 Unix 秒；看到巨大数字不要当毫秒解析。

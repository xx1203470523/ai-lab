# 自检

用一对**空任务 + 空脚本**验证技能的读写链路，不碰任何业务任务。

## 内容

- `noop.js` —— 只打印一行时间戳，不连业务系统、不做任何写操作。
- `desired-noop.json` —— 对应的期望态模板。

## 跑法

```powershell
$ql  = "$env:USERPROFILE\.claude\skills\qinglong\scripts\ql.ps1"
$skl = "$env:USERPROFILE\.claude\skills\qinglong"

# 1. 把模板放进期望态目录，state.diff 应报一条 create
Copy-Item "$skl\selftest\desired-noop.json" "$skl\tasks\_selftest-noop.json"
& $ql -Verb state.diff

# 2. 建脚本再建任务；两条都是 level 1，会先出计划，带 -ConfirmPlan 才落地
& $ql -Verb script.new -Key _qls_selftest_noop.js -ContentFile "$skl\selftest\noop.js"
& $ql -Verb script.new -Key _qls_selftest_noop.js -ContentFile "$skl\selftest\noop.js" -ConfirmPlan <digest>
& $ql -Verb task.create -Key _selftest-noop
& $ql -Verb task.create -Key _selftest-noop -ConfirmPlan <digest>

# 3. 稳态：state.diff 应报 no-op、pendingCount=0
& $ql -Verb state.diff

# 4. 幂等：再跑一次 update 应直接 no-op
& $ql -Verb task.update -Key _selftest-noop

# 5. 拆干净（两条都是 level 2）
& $ql -Verb task.delete   -Key _selftest-noop      -ConfirmPlan <digest>
& $ql -Verb script.delete -Key _qls_selftest_noop.js -ConfirmPlan <digest>
Remove-Item "$skl\tasks\_selftest-noop.json"

# 6. 收尾确认：total 应回到原值、managed=0
& $ql -Verb task.list
```

## 注意

- 自检结束后**务必删掉 `tasks\_selftest-noop.json`**。留着的后果是 `state.diff` 永远报一条待创建，污染真实状态视图。
- 自检脚本名统一带 `_qls_selftest_` 前缀，便于在平台上辨认和清理。
- `task.run` 不在自检范围内——它会真的执行，属于 level 2，必须由用户显式发起。

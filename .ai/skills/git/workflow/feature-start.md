# 需求开工工作流

用户敲 `/git` 后直接跟一段需求描述（「给在库标签查询支持储位用 | 拼接」「备料综合报表要按备注取数」），
要的是**找一个地方开始写代码**，不是问 Git 问题。

本工作流只负责**编排**。判定与执行由 `scripts/` 下的脚本完成，
接口与阻断码见 `../reference/scripts/script-contract.md`。

```
/git <需求描述>
   │
   ├─ 1. find    找近 30 天仍未合并的分支迭代候选
   │
   ├─ 2. 你判断有无同一迭代          ← 只有这一步是判断
   │      ├─ 有 + 已有工作区 → 3a enter
   │      ├─ 有 + 没有工作区 → 3b attach
   │      └─ 没有            → 3c create
   │
   └─ 4. 切进去，开始开发
```

## 1. 找候选

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\wt.ps1 `
    -Action find [-Target <集成分支>] [-SinceDays 30] [-AllowFetch]
```

`find` **不做语义匹配**，它给的是客观事实。报 `target-branch-unresolved` 时
停下问用户这次是并入 `main` 还是 `production` —— 猜错会让 `production` 上还没合完的
迭代被当成「已合并」从候选里丢掉。

## 2. 判断是不是同一个迭代

拿需求去比对候选的 `name`、`tipSubject`、`recentCommits`。

**必须能指出证据**：说出是候选的哪几个提交标题或分支名让你认为它是同一迭代。
指不出证据就当成没匹配到，走第 3c 步。分支名是英文/拼音、需求是中文，
这是翻译加判断，不存在「看起来差不多」，只有「能从提交标题里对上」。

候选为空、或没有一个对得上，就明确说「没有找到对应这个需求的进行中分支」。

## 3a. 找到，且已有工作区

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\wt.ps1 `
    -Action enter -Name <分支名>
```

**先把候选与证据报给用户，等确认再进入**。这是唯一一步把判断权交出去的地方：
匹配错了会让你在错的分支上写代码。

## 3b. 找到，但没有工作区

分支还在，工作区已被清理。用 `attach` 接着做，**不要**用 `create` —— `create` 会试图
新建同名分支并被 `branch-already-exists` 拦下。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\wt.ps1 `
    -Action attach -Branch <分支名> [-Name <工作区名>]
```

`attach` 挂本地已有分支时保持它当前的提交位置不动，不会擅自重置到 origin。
若报 `branch-already-checked-out`，说明工作区其实还在，回第 3a 步。

## 3c. 没找到，新建

从需求里提炼分支名（`<type>/<scope>/<功能简写>/<操作类型>`，见 `../rules/branch.rules.md`），
然后：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\wt.ps1 `
    -Action create -Branch <新分支名> -Name <工作区名> [-Base main|production]
```

1. **基分支**：先看需求里有没有写明 `main` / `production`。没写就不传 `-Base` 让脚本推断；
   脚本报 `base-branch-ambiguous`（两个远端都有）时**停下来问用户**，不要默认 main。
2. **分支名与工作区名报给用户**，同时说明是从哪段需求提炼的。名字由你拟，
   但用户看不出这是新分支还是接旧分支时会困惑。
3. 建好后报告：分支名、基分支、工作区路径、下一步。

## 4. 切换与开工

三条件一（3a/3b/3c）成功后都会返回 `cdCommand`，按
`../reference/scripts/script-contract.md` 的要求自己执行并回读确认。

切换成功后，回到用户的需求本身开始开发。需求描述里往往已经带了任务内容
（这类调用常常一次说 700–850 字），不要再回头问「你要做什么」。

## 边界

需求描述里如果同时点名了要 rebase / 要合并 / 要推送，那是另外的意图，
按 `push.md` 处理，不要在这个工作流里顺手做掉。

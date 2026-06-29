# 使用示例

## 基本触发

```
/git-push
```

```
推送
```

```
提交并推送
```

## 典型流程

### feature 分支开发完成

```
用户: /git-push

Claude:
  1. 检查分支: feature/xxx ✅
  2. 检查远端: 落后 origin/master 2 个提交 → 用户确认 rebase → 成功
  3. 分析改动:
      M python/chaogu/fetcher.py
      M python/chaogu/models.py
      A python/chaogu/providers/akshare.py

      feat(python): 新增 AKShare 数据源，重构 fetcher 降级链

  4. 暂存提交 → 成功 (a1b2c3d)
  5. git push origin feature/xxx → ✅
```

### master 分支小修复

```
用户: 推送

Claude:
  ⚠️ 你正在 master 分支上直接提交，确认继续？ [是/否]
  
用户: 是

Claude:
  2. git pull --rebase origin master → 成功
  3. 分析改动:
      M docs/DEPLOY.md

      docs: 更新部署文档端口号

  4. 暂存提交 → 成功 (e5f6g7h)
  5. git push origin master → ✅
```

### rebase 冲突

```
用户: /git-push

Claude:
  1. 分支检查: feature/xxx ✅
  2. git rebase origin/master → ⚠️ 冲突:
      CONFLICT in python/chaogu/fetcher.py
      CONFLICT in python/chaogu/client.py

      请手动解决冲突后重新 /git-push
```

### 远端有新提交

```
用户: /git-push

Claude:
  1. 分支检查: feature/xxx ✅
  2. 远端检查: 已最新 ✅
  3. 改动分析: ...
  4. 提交: 成功
  5. git push → ⚠️ 远端有新提交，推送被拒绝。
      请 rebase origin/master 后再推送。
```

# Git 本机环境

> 最后更新: 2026-07-02

## 托管平台

- **GitLab 自建实例**（非 GitHub）
- CLI 工具：`glab`（非 `gh`）
- MR 链接格式：`https://<host>/<project>/-/merge_requests/<iid>`

## 个人分支命名

```
<type>/lyp/<功能英文简写>/<操作类型>
```

- type: feat | fix | chore | docs | refactor
- 隔断符：分支用 `/`，工作区用 `-`

## 保护分支

- main, production, staging — 禁止直接提交或推送

## 个人偏好

- 冲突策略：优先 rebase 而非 merge
- diff tool: Beyond Compare
- 不跳过 hooks（不使用 --no-verify / --no-gpg-sign）

# Git Push 个人配置

未配置的项回退到 `git config`。

## 用户信息

```yaml
name: ""           # 留空 = git config user.name
email: ""          # 留空 = git config user.email
```

## 提交信息格式

```
<type>(<scope>): <中文简述>

- <子项目>: 改动项
- 改动项（无归属不加前缀）
```

- scope = 项目子目录名
- type + scope: 英文
- 简述: 中文

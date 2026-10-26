# 归档查询索引

规范见 `README.md`。索引里的每一行都应当对应一个真实存在的文件——**不预先填占位行**。

> 不要在这里登记一次性的临时查询；不要登记生产变更 SQL（那类归项目仓库的 `sql/`）；也不要登记 `operations/` 下的写模板（技能不执行它们）。

**「验证时间」列必须如实写。** 写过「未验证」比写一个看起来对的时间有价值：下一个人据此决定要不要先自己跑一遍。

| 日期 | 文件 | 用途 | 路由 | 验证时间 |
|---|---|---|---|---|
| 2026-10-13 | [queries/q_menu_subtree_role_usage.sql](queries/q_menu_subtree_role_usage.sql) | 按菜单名/Component 关键字列出菜单行 + 子树 + 每行角色分配数 + 分配了这些行的角色清单；用于菜单合并/清理/改路由前摸底影响面 | `dev.lebgjm`（拟定） | **未验证** |

## 待办

- `q_menu_subtree_role_usage.sql` 在真实库上跑通后，把「验证时间」补成实际日期，并把实测结论与差异回填 `references/projects/wms/menu-management.md`。
- `references/projects/wms/scenarios/arn-head-dept-shows-none.md` 里的 3 条诊断语句，在真实库上跑通并确认结果后，按 `README.md` 的规范归档一份到 `queries/`，并把实测结论回填进剧本（剧本当前标注「未用真实查询复核」）。

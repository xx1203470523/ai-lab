# 使用示例

## 新建 Skill

### 基本用法

```
/skill-core-build 生成 git 分支管理 skill
```

```
/skill-core-build 新建一个日志查看器 skill
```

### 完整流程

```
用户: /skill-core-build 生成一个环境检测 skill

Claude:
  ## 需求分析
  检测系统环境（OS/Node/Python/Git 版本、端口占用、磁盘空间）

  ## 调研参考
  1. doctor CLI（npm）— 单命令输出全量报告
  2. checkup（GitHub）— 分项检测 + 通过/失败状态
  3. envcheck（Python）— YAML 配置驱动检测项

  ## 方案 A：全量报告式
  一次运行，输出表格化报告，适合人工查看

  ## 方案 B：分项检测式
  按需检测单项，--json 输出，适合脚本集成

  ## 方案 C：配置驱动式
  通过 YAML 定义检测规则，可扩展，但复杂度高

  推荐方案 B，适合本项目需要。
```

## 优化 Skill

```
/skill-core-build 优化 git-push
```

流程：
1. 读取 `~/.claude/skills/git-push/` 全部文件
2. 实跑一次 git-push（dry-run），记录：
   - 步骤是否流畅
   - 错误处理是否覆盖
   - 输出信息是否清晰
3. 进入计划模式列出优化项
4. 用户确认后修改

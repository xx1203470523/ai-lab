---
name: trade-watch
description: "启动本机炒股监控进程（chaogu watcher + cc-connect 行情连接），检查运行状态。仅在用户明确要求启动炒股项目、启动watcher、或使用 /trade-watch 时触发"
---

# Trade Watch

启动并验证本机炒股辅助项目的 Python watcher 与 cc-connect。幂等：已运行则报告状态，不重复启动。

## 固定路径

- 项目根目录：`E:\My\project\trade`
- 统一启动脚本：`ai-lab://project/trade/skills/trade-watch/scripts/start-my.ps1`
- Watcher 项目脚本：`E:\My\project\trade\cmd\start-watcher.ps1`
- cc-connect 项目脚本：`E:\My\project\trade\cmd\start-cc-connect.ps1`
- Python 子项目目录：`E:\My\project\trade\python`

## 执行

1. 执行统一启动脚本
2. 检查 Python import：`python -c "import chaogu; print('python import ok')"`
3. 检查 watcher 进程：命令行含 `chaogu` 和 `watch`
4. 检查 cc-connect 进程：`node.exe` 命令行含 `cc-connect`
5. 汇总：watcher 状态/PID、Python import、cc-connect 状态/PID

失败项如实报告，不隐藏。

## 约束

- 不停止或杀掉进程，除非用户明确要求
- 不要默认调用 `start-cc-connect.ps1 -Stop`（会停止所有 Node 进程）

## 飞书测试

需要测试飞书时，在 `E:\My\project\trade\python` 下读取 `config/notify.json`，复用 `chaogu.notify.feishu.FeishuNotifier`。

不要输出 `appSecret`，不要把 `notify.json` 内容贴到对话中。

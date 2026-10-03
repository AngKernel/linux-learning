# prompts/ 使用说明

把整个 prompts/ 目录放进 linux-learning 仓库根目录，和 AGENTS.md 一起提交到 main。

## 执行顺序
1. P0（AGENTS.md）已经在 main 上完成并提交
2. 在 main 上开一个 Codex 会话，贴入 RUN-orchestrator.md 的全部内容。它会自动执行 P1–P6、P8（建 worktree、分派子任务、监控、验收、合并）
3. P7-papers.md 交给 ChatGPT Work 或深度研究执行，结果手动保存到 notes/05-papers/
4. 全部合并后，按 P9-fact-check.md 里的说明拆分会话做事实核查
5. 最后执行 P10-integrate.md（先把 <X> 改成每周能投入的小时数）

## 中断后怎么办
用量用完或会话中断，恢复额度后在 main 上重新运行 RUN-orchestrator.md 即可，它会沿用已有的 worktree 和分支，从断点继续。

## 文件清单
| 文件 | 内容 | 执行方 |
|---|---|---|
| RUN-orchestrator.md | 调度提示词 | Codex（main 上） |
| P1-overview.md | 网络栈全景地图 | 子任务 |
| P2-kernel-basics.md | 内核基础速成 | 子任务 |
| P3-env.md | 实验环境一键化 | 子任务 |
| P4a-rx-tx-paths.md | 收发包路径 | 子任务 |
| P4b-tcp-mechanisms.md | TCP 连接与可靠性机制 | 子任务 |
| P5-tcp-design.md | 内核 TCP 设计原理与取舍 | 子任务（需完整 git 历史） |
| P6-userspace-stacks.md | 用户态协议栈源码导读 | 子任务 |
| P7-papers.md | 论文研读 | ChatGPT Work / 深度研究 |
| P8-labs.md | 动手实验 | 子任务 |
| P9-fact-check.md | 事实核查 | 合并后按目录分会话 |
| P10-integrate.md | 整合与学习计划 | 最后执行 |

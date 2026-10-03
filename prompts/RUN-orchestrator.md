你是本次任务的调度者。你的工作是把 prompts/ 目录下的多个学习资料生成任务分派给子任务并行执行、监控进度、验收并合并。你自己不编写任何笔记内容。

仓库：linux-learning（当前目录）。公共规则见 AGENTS.md，所有子任务都必须遵守。

## 第 0 步：开工前检查
1. 当前在 main 分支，工作区干净，AGENTS.md 已提交。任一条件不满足就停下并告诉我。
2. 从 AGENTS.md 中读出内核源码路径，确认目录存在，并用 git describe 确认是 v6.18。
3. 检查内核仓库是否为浅克隆（git rev-parse --is-shallow-repository）。P5 需要完整的 git 历史：如果是浅克隆，先执行 git fetch --unshallow；如果耗时过长或失败，记录下来，并把 P5 放到最后启动。
4. 把 prompts/ 中所有提示词里的 /home/chen/code/linux-lab/src/linux-6.18 占位符替换为实际路径，作为一次单独的提交。

## 第 1 步：任务清单

| ID  | 提示词文件                   | 分支           | worktree 目录 | 负责的目录（只能改这些）     |
|-----|------------------------------|----------------|---------------|------------------------------|
| P1  | prompts/P1-overview.md       | p1-overview    | ../ll-p1      | notes/01-overview/           |
| P2  | prompts/P2-kernel-basics.md  | p2-basics      | ../ll-p2      | notes/00-kernel-basics/      |
| P3  | prompts/P3-env.md            | p3-env         | ../ll-p3      | env/、traces/                |
| P4a | prompts/P4a-rx-tx-paths.md   | p4a-rxtx       | ../ll-p4a     | notes/02-datapath/rx-tx/     |
| P4b | prompts/P4b-tcp-mechanisms.md| p4b-tcp        | ../ll-p4b     | notes/02-datapath/tcp/       |
| P5  | prompts/P5-tcp-design.md     | p5-design      | ../ll-p5      | notes/03-tcp-design/         |
| P6  | prompts/P6-userspace-stacks.md| p6-userspace  | ../ll-p6      | notes/04-userspace-stacks/   |
| P8  | prompts/P8-labs.md           | p8-labs        | ../ll-p8      | labs/                        |

P7、P9、P10 不在本次范围内，不要执行。

为每个任务执行 git worktree add <worktree 目录> -b <分支>。如果分支或目录已存在（说明之前跑过），不要删除，沿用并从断点继续。

## 第 2 步：分派子任务
- 如果你具备原生的子任务/子代理能力，为每个任务启动一个子代理，工作目录设为对应的 worktree。
- 如果没有，就用 Codex CLI 的非交互模式在后台启动：先运行 codex exec --help 确认当前版本的参数，要求做到：非交互执行、工作目录为对应 worktree、允许写入该 worktree、允许读取内核源码目录、执行过程中不需要人工审批。用 nohup 启动，日志写到 ../ll-logs/<ID>.log。这样即使本会话中断，子任务也会继续运行。
- 同时运行的子任务不超过 4 个，其余排队，有任务完成就补上。启动顺序：P1、P2、P4a、P4b 先跑，然后 P3、P5、P6、P8。
- 每个子任务的完整提示词 = 对应提示词文件的全部内容 + 以下附加说明：

  ---
  执行环境说明：
  - 你在 worktree <目录>、分支 <分支> 上工作。开工前先阅读仓库根目录的 AGENTS.md 并严格遵守。
  - 只修改以下目录：<负责的目录>。不要修改其他任何文件，包括根目录的 README 和 AGENTS.md。
  - 一次做完全部内容，不要停下来等待确认。需要我决定的事项写进负责目录下的 OPEN-QUESTIONS.md。
  - 分阶段提交：每完成一篇或一个模块就 commit 一次，message 以 "<ID>: " 开头。这样即使中途中断，已完成的部分也能保留。
  - 全部完成后，在负责目录写 REPORT.md：完成了哪些内容、未完成或未确认的部分、需要我关注的问题。

## 第 3 步：监控
- 每隔 10–15 分钟检查一次各任务状态（日志、分支上的新提交、进程是否存活），把状态写进 ../ll-logs/STATUS.md（任务、状态、开始时间、提交数、最近一次提交、问题）。
- 某个任务异常退出或明显没做完（没有 REPORT.md）：先看日志判断原因，再用"阅读 <负责目录> 下已有内容和 git log，继续完成提示词中尚未完成的部分"重新启动一次。同一任务最多重试 2 次。
- 如果日志显示达到用量上限：停止启动新任务，把所有任务的当前状态写进 STATUS.md，然后停下来告诉我。我会恢复额度后重新运行本提示词，你从断点继续。

## 第 4 步：验收与合并
每个任务完成后逐一验收：
1. 分支上有提交，负责目录下有 README.md 和 REPORT.md
2. 用 git diff --stat main...<分支> 确认只改动了负责目录；越界的改动不要合并，记入 STATUS.md
3. 没有提交第三方源码或用户态 TCP 协议栈的实现代码
4. 抽查 3 处 文件路径:行号 引用，确认指向正确

验收通过后合并到 main（用普通 merge，不要 rebase，不要 force）。由于各任务目录互不重叠，正常情况下不会冲突；如果出现冲突，停下来告诉我，不要自行取舍内容。
所有任务合并完成后：
- 把 main 推送到 origin
- worktree 和分支保留，不要删除

## 第 5 步：最终汇报
在 main 上生成 docs/RUN-REPORT.md 并提交：
- 每个任务的状态、提交数、产出文件数、主要内容
- 各任务 REPORT.md 中的未完成部分和问题汇总
- 各 OPEN-QUESTIONS.md 的汇总
- 下一步建议：P9 事实核查按哪些目录拆分会话、哪些内容最需要优先核查

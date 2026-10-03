# P6 后续选择与核查

这些事项不影响本次源码导读完成，不需中途确认。没有任何实际部署、性能或协议互通结果被写成已完成。

| 事项 | 当前处理 | 后续建议 |
|---|---|---|
| 源码长期保存 | 按授权克隆到仓库外 `/tmp/p6-sources/`，完整 hash 写入 README | 若计划数周后逐行阅读，可自行保留或重建持久 checkout；不要提交第三方源码到学习仓库 |
| lwIP port | 只核实核心与 Unix 测试源码，NIC TSO/LRO 未确认 | 先选 Unix port 做虚拟时间/丢包单测，再决定是否做 DPDK port 对照 |
| VPP 后端与队列 | 固定 v25.06 源码，未配置设备 | 后续明确 NIC、worker、RSS、前置 steering 和 GSO/LRO 配置；优先验证错误线程是否触达 drop 分支 |
| Seastar backend | 本文只比较 native；POSIX 明确分开 | 若做实验，记录 native/POSIX、DPDK/virtio、内存后端、LRO 构建条件；先验证 SYN options、TIME_WAIT 与 keepalive 边界 |
| F-Stack 模式 | 已确认传统多进程之外存在 thread_mode，以及 worker VNET/callwheel 初始化 | 建议单开事实核查会话追踪 VNET、PCB、锁、FD 归属；先用传统模式建立基线，再测新线程模式 |
| 是否需要完整互通证据 | 当前只做源码追踪与测试入口定位 | 用同一个参考内核 peer 注入 loss、reorder、duplicate、FIN 后旧包，再比较恢复/关闭行为；普通 echo 成功不足以覆盖 |
| 性能实验是否做成后续 lab | 不在本次研究中启动 root 网络操作或占用 NIC | 固定相同功能集和负载，分别测调用/唤醒、复制、迁核、batch、timer lateness；同时记录尾延迟与正确性 |
| 各目录版本不同 | P6 固定版本独立、行号与上游链接齐全 | P9 先做版本映射；不同版本的函数/默认值差异不应直接合并成统一结论 |

优先级：F-Stack 新线程模式 → Seastar native 协议缺口与测试覆盖 → VPP ACK 调度/错误线程/复制边界 → lwIP SACK 方向性与 port 能力。前两项最容易因套用项目介绍或旧博客而出错。

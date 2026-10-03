# E2. ULP 与 sockops：扩展功能放在合适的边界

本篇回答：kTLS 接管 TLS 的哪一部分？ULP、sockops 和 BPF CC 有何不同？前置阅读：E1、A3、socket API。预计阅读：10 分钟。源码基准：Linux v6.18。

## 1. 问题

应用需要 TLS record（记录层）处理、按连接定制策略或观察 TCP 事件。每次修改核心 TCP 既难部署，也扩大回归范围；简单在最底层截一个包又得不到完整连接语义。

## 2. 约束

扩展必须与 TCP 锁、模块引用、重传和 socket 生命周期协作。TLS 密钥配置和连接状态不能任意顺序切换；BPF 事件上下文也不是用户线程可睡眠、任意系统调用的环境。

## 3. 方案

| 扩展点 | 工作范围 | v6.18 证据 |
|---|---|---|
| ULP（Upper Layer Protocol，上层协议） | 在 TCP socket 上装入上层行为，提供 init/update/release 等操作 | `include/net/tcp.h:2677`、`net/ipv4/tcp_ulp.c:130` |
| kTLS | 将 TLS record 对称加解密等数据路径下沉，保留应用握手配置责任 | `Documentation/networking/tls.rst:16` |
| BPF sockops | 按连接事件运行 cgroup 关联程序，观察或调整允许的参数 | `net/ipv4/tcp_input.c:182`、`include/net/tcp.h:2757` |
| BPF CC struct_ops | 提供拥塞控制算法操作表 | E1 |

`TCP_ULP` 选项经 `tcp_set_ulp()` 安装扩展（`net/ipv4/tcp.c:3834`）。已有 `icsk_ulp_ops` 时拒绝重复安装；不应把 ULP 想成可以任意串联的过滤器链。没有 clone 支持的 ULP 不能直接装在 listener 上，见 `net/ipv4/tcp_ulp.c:130`。

kTLS 的名字为 `tls`，注册见 `net/tls/tls_main.c:1166`。握手通常先在用户态完成，再把相应参数配置进 `TLS_TX/TLS_RX`；发送和接收分别配置，接收解密需完整 record（`Documentation/networking/tls.rst:28`、第 101 行）。内核处理数据记录不等于实现证书验证或完整 TLS 握手。

sockops 的 `op` 区分事件，例如主动/被动建立、RTT、状态变化。`bpf_skops_established()` 明确构造已锁 TCP socket 上下文，再运行 cgroup hook（`net/ipv4/tcp_input.c:182`）；回调 flags 控制某些事件是否触发。它不意味着每个 payload 字节必经 sockops，也不是 E1 的算法操作表。

## 4. 演进

| commit / 作者 | 动机 | 性能数据 |
|---|---|---|
| `734942cc4ea6` / Dave Watson | 引入 TCP ULP 安装/注册基础设施，允许上层替换相关 socket 行为。 | 该提交未提供性能数据。 |
| `3c4d7559159b` / Dave Watson | 通过 ULP 实现软件 kTLS；握手后配置密钥，内核做对称加密。 | 该提交未提供性能数据。 |
| `40304b2a1567` / Lawrence Brakmo | 引入 sockops 框架，用连接信息和 cgroup 策略补充 sysctl、route metric、应用 setsockopt。 | 该提交未提供性能数据；正文的百分比分组是试验方式示例，不是效果测量。 |

这些初始提交的具体函数、配置能力随版本演进；本篇只用当前源码描述 6.18 接口。

## 5. 取舍

扩展复用 TCP 与 socket 生命周期，避免复制整个栈；代价是更多组合状态、错误回滚和语义限制。kTLS 能减少应用数据路径搬运机会，但不能无条件与 A3 每一种零拷贝接口组合。按连接策略越灵活，定位“谁改了参数”越需要可观测性。

## 6. 用户态对照

lwIP 2.2.1 的 altcp TLS 层在 `src/apps/altcp_tls/altcp_tls_mbedtls.c:285` 调用 mbedTLS 握手，第 1250 行调用写接口，将 TLS 库包在传输抽象上。[固定源码](https://github.com/lwip-tcpip/lwip/blob/77dcd25a72509eb83f72b033d219b1d40cd8eb95/src/apps/altcp_tls/altcp_tls_mbedtls.c#L285) 分层原则相同，执行位置与应用契约不同；不能从它有 TLS 就推导具备 kTLS 的内核/设备卸载路径。

## 7. 验证

目标环境先检查已构建 TLS 与 BPF 功能，再用既有 TLS 测试程序对比用户态 record 与 kTLS。确认握手、证书校验、消息大小和加密算法一致；分开验证 TX/RX。BPF 程序加载成功只证明接入可用，还要验证预期事件真的发生。未运行。

## 要点回顾

- ULP 扩展上层数据行为，sockops 按事件施加连接策略。
- kTLS 不替代完整用户态 TLS 协商。
- 可组合性必须逐对验证，不能按功能名推断。

## 自测

1. 装上 tls ULP 就完成证书验证了吗？
2. sockops 是否每包扫描 payload？
3. 一个 socket 能无条件叠加任意 ULP 吗？

<details><summary>答案</summary>

1. 没有。2. 不是，它是受定义的连接事件接口。3. 不能，已有 ULP 会被安装检查拒绝。

</details>

## 与 DPDK/VPP 的对照

VPP graph node 的扩展点更接近处理图中的包操作；ULP 位于有状态 socket 上层，sockops 位于连接生命周期事件。三者都可插入逻辑，但上下文、可见状态与所有权边界不同，不能一一替换。

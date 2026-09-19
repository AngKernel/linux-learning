# <主题>

- 版本：`v6.18`
- 入口：`net/core/dev.c :: netif_receive_skb()`
- 读的时间：2026-xx-xx

## 1. 调用链

```
netif_receive_skb()
  └─ netif_receive_skb_internal()
       └─ __netif_receive_skb()
            └─ __netif_receive_skb_core()
                 ├─ ...
```

## 2. 关键结构体 / 字段

| 结构体 | 字段 | 作用 | 备注 |
| ------ | ---- | ---- | ---- |
|        |      |      |      |

## 3. 实测

跑了什么、看到什么（ftrace / kprobe / pktpeek 的实际输出贴这里）：

```
$ trace-cmd record -p function_graph -g __netif_receive_skb_core -- ping -c1 ...
```

## 4. 和 DPDK / VPP 的对照

内核这里怎么做、用户态数据面怎么做、为什么不一样。

## 5. 相关 commit

```
$ git log -S'<符号>' --oneline
```

## 6. 还没搞懂的

- [ ]

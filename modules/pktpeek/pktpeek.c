// SPDX-License-Identifier: GPL-2.0
/*
 * pktpeek —— 在 NF_INET_PRE_ROUTING 挂一个观察点，打印 skb 的关键字段。
 *
 * 这是收包路径上第一个「你自己的代码能站上去」的位置，
 * 用来对照着读 __netif_receive_skb_core() -> ip_rcv() -> NF_HOOK() 这一段。
 *
 *   insmod pktpeek.ko limit=20
 *   ping -c 3 1.1.1.1
 *   dmesg | tail -20
 *   rmmod pktpeek
 *
 * 注意 skb->len / data_len / nr_frags 的关系：
 *   len      = 线性区 + 所有分片的总长
 *   data_len = 非线性部分（frags + frag_list）的长度
 *   len - data_len = skb_headlen()，线性区实际字节数
 * 和 rte_mbuf 的 pkt_len / data_len / nb_segs 对着看，差异点很有意思。
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/atomic.h>
#include <linux/skbuff.h>
#include <linux/ip.h>
#include <linux/netdevice.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <net/net_namespace.h>

static unsigned int limit = 20;
module_param(limit, uint, 0644);
MODULE_PARM_DESC(limit, "最多打印多少个包，0 = 不限");

static atomic_t seen = ATOMIC_INIT(0);

static unsigned int pktpeek_hook(void *priv, struct sk_buff *skb,
				 const struct nf_hook_state *state)
{
	const struct iphdr *iph;
	int n;

	if (!skb)
		return NF_ACCEPT;

	iph = ip_hdr(skb);
	if (!iph)
		return NF_ACCEPT;

	n = atomic_inc_return(&seen);
	if (limit && (unsigned int)n > limit)
		return NF_ACCEPT;

	pr_info("pktpeek[%d] in=%s %pI4 -> %pI4 proto=%u | len=%u headlen=%u data_len=%u nr_frags=%u cloned=%d shared=%d\n",
		n,
		state->in ? state->in->name : "?",
		&iph->saddr, &iph->daddr, iph->protocol,
		skb->len, skb_headlen(skb), skb->data_len,
		skb_shinfo(skb)->nr_frags,
		skb->cloned ? 1 : 0,
		skb_shared(skb) ? 1 : 0);

	return NF_ACCEPT;
}

static struct nf_hook_ops pktpeek_ops = {
	.hook     = pktpeek_hook,
	.pf       = NFPROTO_IPV4,
	.hooknum  = NF_INET_PRE_ROUTING,
	.priority = NF_IP_PRI_FIRST,
};

static int __init pktpeek_init(void)
{
	int ret = nf_register_net_hook(&init_net, &pktpeek_ops);

	if (ret) {
		pr_err("pktpeek: 注册 hook 失败 %d\n", ret);
		return ret;
	}
	pr_info("pktpeek: 已挂在 PRE_ROUTING，limit=%u\n", limit);
	return 0;
}

static void __exit pktpeek_exit(void)
{
	nf_unregister_net_hook(&init_net, &pktpeek_ops);
	pr_info("pktpeek: 卸载，共看到 %d 个 IPv4 包\n", atomic_read(&seen));
}

module_init(pktpeek_init);
module_exit(pktpeek_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("PRE_ROUTING 观察点：打印 skb 关键字段");

// SPDX-License-Identifier: GPL-2.0
/* Original learning module: count/drop unfragmented IPv4 Echo requests. */
#include <linux/atomic.h>
#include <linux/icmp.h>
#include <linux/inet.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/netfilter.h>
#include <linux/netfilter_ipv4.h>
#include <linux/skbuff.h>
#include <net/ip.h>
#include <net/net_namespace.h>

static unsigned int hook = NF_INET_LOCAL_IN;
static char *dst = "192.0.2.11";
static bool drop;
module_param(hook, uint, 0444);
module_param(dst, charp, 0444);
module_param(drop, bool, 0444);
MODULE_PARM_DESC(hook, "IPv4 hook number, 0..4");
MODULE_PARM_DESC(dst, "Destination IPv4 address");
MODULE_PARM_DESC(drop, "Drop matched ICMP Echo requests");
static __be32 dst_addr;
static atomic64_t matched = ATOMIC64_INIT(0);
static atomic64_t dropped = ATOMIC64_INIT(0);
static struct nf_hook_ops ops;

static unsigned int inspect(void *priv, struct sk_buff *skb,
                            const struct nf_hook_state *state)
{
    struct iphdr iph_buf;
    struct icmphdr icmp_buf;
    const struct iphdr *iph;
    const struct icmphdr *icmp;
    int offset = skb_network_offset(skb);
    unsigned int ihl;
    (void)priv;
    (void)state;
    if (offset < 0)
        return NF_ACCEPT;
    iph = skb_header_pointer(skb, offset, sizeof(iph_buf), &iph_buf);
    if (!iph || iph->version != 4 || iph->ihl < 5 ||
        iph->protocol != IPPROTO_ICMP || iph->daddr != dst_addr ||
        ip_is_fragment(iph))
        return NF_ACCEPT;
    ihl = iph->ihl * 4;
    if (ntohs(iph->tot_len) < ihl + sizeof(icmp_buf))
        return NF_ACCEPT;
    icmp = skb_header_pointer(skb, offset + ihl, sizeof(icmp_buf), &icmp_buf);
    if (!icmp || icmp->type != ICMP_ECHO || icmp->code != 0)
        return NF_ACCEPT;
    atomic64_inc(&matched);
    if (drop) {
        atomic64_inc(&dropped);
        return NF_DROP;
    }
    return NF_ACCEPT;
}
static int __init lab_init(void)
{
    const char *end = NULL;
    if (hook > NF_INET_POST_ROUTING ||
        !in4_pton(dst, -1, (u8 *)&dst_addr, -1, &end) || !end || *end)
        return -EINVAL;
    ops.hook = inspect;
    ops.pf = NFPROTO_IPV4;
    ops.hooknum = hook;
    ops.priority = NF_IP_PRI_FILTER;
    return nf_register_net_hook(&init_net, &ops);
}
static void __exit lab_exit(void)
{
    nf_unregister_net_hook(&init_net, &ops);
    pr_info("ll-l06 hook=%u dst=%pI4 matched=%lld dropped=%lld\n",
            hook, &dst_addr, (long long)atomic64_read(&matched),
            (long long)atomic64_read(&dropped));
}
module_init(lab_init);
module_exit(lab_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("linux-learning L06 ICMP netfilter hook exercise");

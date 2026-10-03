/* Original XDP learning example; Ethernet + IPv4 UDP/9000 only. */
#include <linux/bpf.h>
#define SEC(name) __attribute__((section(name), used))
#ifndef LAB_DROP
#define LAB_DROP 0
#endif
struct {
    int (*type)[BPF_MAP_TYPE_PERCPU_ARRAY];
    int (*max_entries)[3];
    __u32 *key;
    __u64 *value;
} counts SEC(".maps");
static void *(*lookup)(const void *, const void *) =
    (void *)BPF_FUNC_map_lookup_elem;
static __attribute__((always_inline)) inline void count(__u32 key)
{
    __u64 *v = lookup(&counts, &key);
    if (v) ++*v;
}
/* Parse in bytes so wire order is explicit and no unaligned casts are needed. */
SEC("xdp")
int lab_udp(struct xdp_md *ctx)
{
    unsigned char *p = (void *)(long)ctx->data;
    unsigned char *end = (void *)(long)ctx->data_end;
    count(0);
    if (p + 14 + 20 > end) return XDP_PASS;
    if (p[12] != 0x08 || p[13] != 0x00) return XDP_PASS;
    unsigned char *ip = p + 14;
    if ((ip[0] >> 4) != 4 || ip[9] != 17) return XDP_PASS;
    unsigned int ihl = (ip[0] & 15) * 4;
    if (ihl < 20 || (ip[6] & 0x3f) || ip[7]) return XDP_PASS;
    unsigned int total = ((unsigned int)ip[2] << 8) | ip[3];
    if (total < ihl + 8 || ip + total > end) return XDP_PASS;
    unsigned char *udp = ip + ihl;
    if (udp + 8 > end) return XDP_PASS;
    if (udp[2] != 0x23 || udp[3] != 0x28) return XDP_PASS; /* 9000 */
    count(1);
#if LAB_DROP
    count(2);
    return XDP_DROP;
#else
    return XDP_PASS;
#endif
}
char license[] SEC("license") = "GPL";

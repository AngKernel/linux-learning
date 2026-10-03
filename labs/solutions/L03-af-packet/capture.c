/* Educational AF_PACKET capture; no protocol-stack implementation. */
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <net/if.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static volatile sig_atomic_t stopped;
static void stop(int sig) { (void)sig; stopped = 1; }

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s IFNAME\n", argv[0]);
        return 2;
    }
    unsigned int idx = if_nametoindex(argv[1]);
    if (!idx) { perror("if_nametoindex"); return 1; }
    int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) { perror("socket"); return 1; }
    struct sockaddr_ll bind_addr = {
        .sll_family = AF_PACKET, .sll_protocol = htons(ETH_P_ALL),
        .sll_ifindex = (int)idx,
    };
    if (bind(fd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
        perror("bind"); close(fd); return 1;
    }
    struct sigaction sa = { .sa_handler = stop };
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    setvbuf(stdout, NULL, _IOLBF, 0);
    unsigned char buf[65536];
    int result = 0;
    while (!stopped) {
        struct sockaddr_ll from;
        socklen_t fromlen = sizeof(from);
        ssize_t n = recvfrom(fd, buf, sizeof(buf), 0,
                             (struct sockaddr *)&from, &fromlen);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("recvfrom"); result = 1; break;
        }
        printf("ifindex=%d type=%u %s len=%zd", from.sll_ifindex,
               from.sll_pkttype,
               from.sll_pkttype == PACKET_OUTGOING ? "OUT" : "IN", n);
        if (n >= ETH_HLEN)
            printf(" ethertype=0x%02x%02x", buf[12], buf[13]);
        putchar('\n');
        for (ssize_t i = 0; i < n && i < 64; ++i)
            printf("%02x%s", buf[i], (i + 1) % 16 ? " " : "\n");
        putchar('\n');
    }
    close(fd);
    return result;
}

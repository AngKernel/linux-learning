/* Minimal non-fragmented IPv4 ICMP Echo responder, not a TCP stack. */
#define _DEFAULT_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static volatile sig_atomic_t stopped;
static void stop(int sig) { (void)sig; stopped = 1; }
static unsigned get16(const unsigned char *p)
{ return (unsigned)p[0] * 256 + p[1]; }
static void put16(unsigned char *p, unsigned n)
{ p[0] = (unsigned char)(n >> 8); p[1] = (unsigned char)n; }
static uint16_t checksum(const unsigned char *p, size_t n)
{
    uint32_t sum = 0;
    while (n >= 2) { sum += get16(p); p += 2; n -= 2; }
    if (n) sum += (uint32_t)*p << 8;
    while (sum >> 16) sum = (sum & 0xffffu) + (sum >> 16);
    return (uint16_t)~sum;
}
/* Return reply length or zero. Reject unsupported packets without mutation. */
static size_t make_reply(unsigned char *p, size_t n, const unsigned char dst[4])
{
    if (n < 28 || p[0] != 0x45 || p[9] != 1) return 0;
    size_t total = get16(p + 2);
    if (total < 28 || total > n || (get16(p + 6) & 0x3fff)) return 0;
    if (memcmp(p + 16, dst, 4) || p[20] != 8 || p[21] != 0) return 0;
    if (checksum(p, 20) || checksum(p + 20, total - 20)) return 0;
    unsigned char tmp[4];
    memcpy(tmp, p + 12, 4);
    memcpy(p + 12, p + 16, 4);
    memcpy(p + 16, tmp, 4);
    p[8] = 64;
    p[20] = 0;
    put16(p + 22, 0);
    put16(p + 22, checksum(p + 20, total - 20));
    put16(p + 10, 0);
    put16(p + 10, checksum(p, 20));
    return total;
}
int main(int argc, char **argv)
{
    int sink = argc == 2 && strcmp(argv[1], "--sink") == 0;
    if (argc != 1 && !sink) {
        fprintf(stderr, "usage: %s [--sink]\n", argv[0]); return 2;
    }
    int fd = open("/dev/net/tun", O_RDWR);
    if (fd < 0) { perror("open tun"); return 1; }
    struct ifreq ifr = { .ifr_flags = IFF_TUN | IFF_NO_PI };
    snprintf(ifr.ifr_name, sizeof(ifr.ifr_name), "l5tun");
    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        perror("TUNSETIFF"); close(fd); return 1;
    }
    struct sigaction sa = { .sa_handler = stop };
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    fprintf(stderr, "%s ready; configure IP in another terminal\n", ifr.ifr_name);
    unsigned char buf[65536], dst[4] = {10, 77, 0, 2};
    unsigned long long received = 0, replied = 0;
    int result = 0;
    while (!stopped) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("read"); result = 1; break;
        }
        ++received;
        size_t out = sink ? 0 : make_reply(buf, (size_t)n, dst);
        if (!out) continue;
        ssize_t written = write(fd, buf, out);
        if (written != (ssize_t)out) {
            if (written < 0) perror("write");
            else fprintf(stderr, "short TUN write\n");
            result = 1; break;
        }
        ++replied;
    }
    close(fd);
    fprintf(stderr, "received=%llu replied=%llu\n", received, replied);
    return result;
}

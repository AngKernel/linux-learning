#!/usr/bin/env python3
"""只读统计 v6.18 已跟踪 C/H 文件的 wc -l 物理行数。"""
import argparse
from pathlib import Path
import subprocess

GROUPS = [
    'net', 'net/core', 'net/ipv4', 'net/ipv6', 'net/sched', 'net/netfilter',
    'net/packet', 'net/netlink', 'net/bridge', 'net/xdp', 'net/xfrm',
    'net/mptcp', 'net/unix', 'include/net', 'include/linux', 'drivers/net',
    'drivers/net/ethernet', 'drivers/net/wireless', 'drivers/net/phy',
]
SELECTED_HEADERS = [
    'net.h', 'skbuff.h', 'netdevice.h', 'tcp.h', 'udp.h', 'ip.h', 'ipv6.h',
    'if_ether.h', 'if_vlan.h', 'inet.h', 'inetdevice.h', 'etherdevice.h',
    'filter.h', 'bpf.h', 'netfilter.h', 'netfilter_ipv4.h', 'netfilter_ipv6.h',
    'netfilter_netdev.h', 'rtnetlink.h', 'netlink.h', 'if_bridge.h', 'if_link.h',
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel_root', type=Path)
    args = parser.parse_args()
    root = args.kernel_root.resolve()
    version = subprocess.check_output(
        ['git', 'describe', '--always', '--dirty', '--tags'], cwd=root, text=True
    ).strip()
    if version != 'v6.18':
        parser.error(f'需要干净的 v6.18 跟踪源码，实际为 {version}')
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root)
    paths = [s.decode() for s in tracked.split(b'\0') if s.endswith((b'.c', b'.h'))]

    def emit(label, files):
        lines = 0
        for i in range(0, len(files), 200):
            output = subprocess.check_output(
                ['wc', '-l', '--', *files[i:i + 200]], cwd=root, text=True
            )
            lines += sum(int(row.split()[0]) for row in output.splitlines()
                         if row.split()[-1] != 'total')
        print(f'{label}\t{len(files)}\t{lines}')

    print('# source=' + version)
    print('# metric=wc -l; tracked .c/.h only; includes comments and blank lines')
    print('scope\tfiles\tphysical_lines')
    for group in GROUPS:
        emit(group, [p for p in paths if p.startswith(group + '/')])
    selected = ['include/linux/' + name for name in SELECTED_HEADERS]
    missing = set(selected) - set(paths)
    if missing:
        raise SystemExit('所选头文件未被跟踪：' + ', '.join(sorted(missing)))
    emit('include/linux selected 22 headers', selected)


if __name__ == '__main__':
    main()

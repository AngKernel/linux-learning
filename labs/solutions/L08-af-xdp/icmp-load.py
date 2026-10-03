#!/usr/bin/env python3
"""Original bounded ICMP workload. No TCP, no remote timestamp comparison."""
import argparse
import socket
import statistics
import struct
import time

MAGIC = b"LLP8PING"
SOURCE = socket.inet_aton("192.0.2.12")
TARGET = socket.inet_aton("10.77.0.2")


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


def frame(srcmac, dstmac, number, size, timestamp):
    payload = struct.pack("!8sIQ", MAGIC, number, timestamp)
    payload += bytes(size - len(payload))
    icmp = struct.pack("!BBHHH", 8, 0, 0, 0x4C38, number & 65535) + payload
    icmp = icmp[:2] + struct.pack("!H", checksum(icmp)) + icmp[4:]
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(icmp),
                     number & 65535, 0x4000, 64, 1, 0, SOURCE, TARGET)
    ip = ip[:10] + struct.pack("!H", checksum(ip)) + ip[12:]
    return dstmac + srcmac + b"\x08\x00" + ip + icmp, payload


def response(packet, srcmac, peer, payload):
    if len(packet) < 42 or packet[:6] != srcmac or packet[6:12] != peer:
        return None
    if packet[12:14] != b"\x08\x00" or packet[14] != 0x45:
        return None
    ip = packet[14:]
    total = struct.unpack("!H", ip[2:4])[0]
    if total < 28 or len(ip) < total or ip[9] != 1 or checksum(ip[:20]):
        return None
    icmp = ip[20:total]
    if icmp[1] or icmp[4:6] != b"\x4c\x38" or checksum(icmp):
        return None
    if icmp[8:] != payload:
        return None
    if icmp[0] == 8 and ip[12:20] == SOURCE + TARGET:
        return "reflection"
    if icmp[0] == 0 and ip[12:20] == TARGET + SOURCE:
        return "echo-reply"
    return None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--interface", required=True)
    p.add_argument("--peer-mac", required=True)
    p.add_argument("--mode", choices=("burst", "rtt"), required=True)
    p.add_argument("--count", type=int, default=100)
    p.add_argument("--pps", type=float, default=20)
    p.add_argument("--size", type=int, default=64, help="ICMP payload bytes")
    args = p.parse_args()
    if not 1 <= args.count <= 10000000 or not 0 < args.pps <= 1000000:
        p.error("count must be 1..10000000 and pps must be 0..1000000")
    if not 20 <= args.size <= 1400:
        p.error("size must be 20..1400")
    try:
        peer = bytes.fromhex(args.peer_mac.replace(":", ""))
    except ValueError:
        p.error("invalid peer MAC")
    if len(peer) != 6 or peer[0] & 1:
        p.error("peer must be a six-byte unicast MAC")
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800))
    try:
        sock.bind((args.interface, 0))
        srcmac = sock.getsockname()[4]
        rtts, kinds = [], {}
        start = time.monotonic()
        last = start
        for number in range(args.count):
            wait = start + number / args.pps - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            timestamp = time.monotonic_ns()
            packet, payload = frame(srcmac, peer, number, args.size, timestamp)
            if sock.send(packet) != len(packet):
                raise RuntimeError("short packet send")
            last = time.monotonic()
            if args.mode == "burst":
                continue
            deadline = last + 1
            while time.monotonic() < deadline:
                sock.settimeout(max(0.000001, deadline - time.monotonic()))
                try:
                    received = sock.recv(65536)
                except socket.timeout:
                    break
                kind = response(received, srcmac, peer, payload)
                if kind:
                    rtts.append((time.monotonic_ns() - timestamp) / 1000)
                    kinds[kind] = kinds.get(kind, 0) + 1
                    break
        elapsed = max(last - start, 0.000000001)
        print(f"sent={args.count} payload={args.size} span_s={elapsed:.6f} "
              f"actual_pps={(args.count - 1) / elapsed:.2f}")
        if args.mode == "rtt":
            print(f"received={len(rtts)} timeout={args.count - len(rtts)} kinds={kinds}")
            if rtts:
                rtts.sort()
                print(f"RTT_us p50={statistics.median(rtts):.3f} "
                      f"p95={rtts[max(0, (95 * len(rtts) + 99) // 100 - 1)]:.3f} "
                      f"max={max(rtts):.3f}")
    finally:
        sock.close()


if __name__ == "__main__":
    main()

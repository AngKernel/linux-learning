#!/usr/bin/env python3
"""Ordinary kernel TCP sockets for L10, not a userspace TCP implementation.
Guest communication is UNTESTED; syntax is checked without opening sockets.
"""
import argparse
import socket
import time


def server(address, port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((address, port))
        listener.listen(1)
        listener.settimeout(120)
        print(f"READY server {address}:{port}", flush=True)
        connection, peer = listener.accept()
        with connection:
            connection.settimeout(15)
            print(f"accepted {peer}", flush=True)
            received = 0
            while True:
                data = connection.recv(4096)
                if not data:
                    break
                received += len(data)
            print(f"peer EOF after {received} bytes; wait 1 second", flush=True)
            time.sleep(1)
            connection.sendall(b"reply from kernel TCP socket\n")
            connection.shutdown(socket.SHUT_WR)


def client(address, port):
    with socket.create_connection((address, port), timeout=15) as connection:
        print(f"connected local={connection.getsockname()} peer={connection.getpeername()}", flush=True)
        connection.sendall(b"hello\n")
        connection.shutdown(socket.SHUT_WR)
        print("local write side closed; waiting for reply and peer EOF", flush=True)
        reply = bytearray()
        while True:
            data = connection.recv(4096)
            if not data:
                break
            reply.extend(data)
        print(f"peer EOF; reply={bytes(reply)!r}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("role", choices=("server", "client"))
    parser.add_argument("address", help="server bind address or client destination IPv4")
    parser.add_argument("port", type=int)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("port must be between 1 and 65535")
    if args.role == "server":
        server(args.address, args.port)
    else:
        client(args.address, args.port)

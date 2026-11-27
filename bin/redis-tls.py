#!/usr/bin/env python3
"""Run redis-cli over a private Unix socket with verified TLS or a selected DB."""

import argparse
import os
import re
import signal
import socket
import ssl
import subprocess
import sys
import tempfile


REDIRECT = re.compile(rb"^-(MOVED|ASK) [0-9]+ (.+):([0-9]+)\r\n$")


def read_line(reader):
    line = reader.readline()
    if line and not line.endswith(b"\r\n"):
        raise OSError("Incomplete Redis reply")
    return line


def read_exact(reader, size):
    data = reader.read(size)
    if len(data) != size:
        raise OSError("Redis connection closed before the message finished")
    return data


def encode_command(*parts):
    return (
        b"*" + str(len(parts)).encode() + b"\r\n"
        + b"".join(b"$" + str(len(part)).encode() + b"\r\n" + part + b"\r\n" for part in parts)
    )


def read_command(reader):
    head = read_line(reader)
    if not head:
        return b""
    if not head.startswith(b"*"):
        raise OSError("Expected a RESP command")
    command = [head]
    for _ in range(int(head[1:])):
        field = read_line(reader)
        if not field.startswith(b"$"):
            raise OSError("Expected a Redis command argument")
        command.extend((field, read_exact(reader, int(field[1:]) + 2)))
    return b"".join(command)


def forward_reply(header, reader, output):
    if not header:
        raise OSError("Redis closed the connection")
    output.sendall(header)
    if header.startswith(b"$"):
        size = int(header[1:])
        if size >= 0:
            remaining = size + 2
            while remaining:
                data = read_exact(reader, min(remaining, 65536))
                output.sendall(data)
                remaining -= len(data)
    elif header.startswith(b"*"):
        for _ in range(int(header[1:])):
            forward_reply(read_line(reader), reader, output)


class RedisConnection:
    def __init__(self, context, host, port, server_name, username, password, database):
        host = host.strip("[]")
        if context is None:
            self.socket = socket.create_connection((host, port), timeout=5)
        else:
            with socket.create_connection((host, port), timeout=5) as raw:
                self.socket = context.wrap_socket(raw, server_hostname=server_name or host)
        self.socket.settimeout(30)
        self.reader = self.socket.makefile("rb")
        try:
            if password is not None:
                parts = [b"AUTH"]
                if username:
                    parts.append(username.encode())
                parts.append(password.encode("utf-8", "surrogateescape"))
                if self.send(encode_command(*parts)) != b"+OK\r\n":
                    raise OSError("Redis authentication failed")
            # redis-cli can continue after -n fails. Gate commands on SELECT here.
            if database:
                reply = self.send(encode_command(b"SELECT", str(database).encode()))
                if reply != b"+OK\r\n":
                    raise OSError(reply.decode("utf-8", "replace").strip() or "Redis rejected SELECT")
        except BaseException:
            self.close()
            raise

    def send(self, command):
        self.socket.sendall(command)
        return read_line(self.reader)

    def close(self):
        self.reader.close()
        self.socket.close()


def serve(frontend, upstream, connect, follow):
    try:
        with frontend.makefile("rb") as reader:
            while True:
                command = read_command(reader)
                if not command:
                    return
                reply = upstream.send(command)
                for _ in range(8 if follow else 0):
                    moved = REDIRECT.match(reply)
                    if moved is None:
                        break
                    redirected = connect(moved[2].decode(), int(moved[3]))
                    upstream.close()
                    upstream = redirected
                    if moved[1] == b"ASK" and upstream.send(encode_command(b"ASKING")) != b"+OK\r\n":
                        raise OSError("Redis rejected ASKING")
                    reply = upstream.send(command)
                forward_reply(reply, upstream.reader, frontend)
    finally:
        upstream.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--user", default="")
    parser.add_argument("--ca", default="")
    parser.add_argument("--server-name", default="")
    parser.add_argument("--follow", action="store_true")
    parser.add_argument("--plain", action="store_true")
    parser.add_argument("--database", type=int, default=0)
    options, cli_arguments = parser.parse_known_args()
    if cli_arguments[:1] == ["--"]:
        cli_arguments = cli_arguments[1:]
    if os.name != "posix":
        raise OSError("This connection requires a POSIX environment, such as WSL")

    environment = os.environ.copy()
    password = environment.pop("REDISCLI_AUTH", None)
    context = None if options.plain else ssl.create_default_context(cafile=options.ca or None)

    def connect(host, port):
        return RedisConnection(context, host, port, options.server_name, options.user, password, options.database)

    with tempfile.TemporaryDirectory(prefix="redis-tui-tls-", dir="/tmp") as directory:
        path = os.path.join(directory, "redis.sock")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(path)
            listener.listen(1)
            listener.settimeout(5)
            upstream = connect(options.host, options.port)
            try:
                child = subprocess.Popen([options.cli, "-s", path, *cli_arguments], env=environment)
                try:
                    frontend, _ = listener.accept()
                    with frontend:
                        serve(frontend, upstream, connect, options.follow)
                    return child.wait(timeout=5)
                finally:
                    if child.poll() is None:
                        child.terminate()
                        try:
                            child.wait(timeout=1)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait()
            finally:
                upstream.close()


def terminate(_signum, _frame):
    raise SystemExit(143)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, terminate)
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"Redis: {error}", file=sys.stderr)
        sys.exit(1)

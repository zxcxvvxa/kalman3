#!/usr/bin/env python3
"""
ssh_ws.py - SSH-over-"WebSocket" bridge, compatible with lightweight SSH
tunneling client apps (HTTP Injector style) that fake a WebSocket Upgrade
purely to get past reverse proxies like haproxy/nginx. These clients do
NOT implement real RFC 6455 framing or masking - they only want:

  1. an HTTP request with an `Upgrade: websocket` header
  2. any 101 Switching Protocols response
  3. a raw, byte-for-byte tunnel to the real SSH server after that

This intentionally does NOT use the strict `websockets` library, which
requires a valid Sec-WebSocket-Key and returns 400 Bad Request without
one. Most SSH-WS client apps never send that header, so a strict server
will reject every connection with exactly that 400.
"""
import asyncio
import base64
import hashlib
import logging
import os

LISTEN_HOST = os.environ.get("SSH_WS_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("SSH_WS_LISTEN_PORT", "10005"))
SSH_HOST = os.environ.get("SSH_WS_TARGET_HOST", "127.0.0.1")
SSH_PORT = int(os.environ.get("SSH_WS_TARGET_PORT", "22"))
BUF_SIZE = 65536
HANDSHAKE_TIMEOUT = 10
WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

logging.basicConfig(level=logging.INFO, format="%(asctime)s [ssh-ws] %(message)s")
log = logging.getLogger("ssh-ws")


async def read_http_request(reader: asyncio.StreamReader):
    """Read a raw HTTP request line + headers, tolerant of whatever the
    client actually sends (missing Sec-WebSocket-* headers included)."""
    request_line = await asyncio.wait_for(reader.readline(), HANDSHAKE_TIMEOUT)
    if not request_line:
        raise ConnectionError("client closed before sending a request")

    headers = {}
    while True:
        line = await asyncio.wait_for(reader.readline(), HANDSHAKE_TIMEOUT)
        if line in (b"\r\n", b"\n", b""):
            break
        if b":" not in line:
            continue
        name, _, value = line.decode("latin-1").partition(":")
        headers[name.strip().lower()] = value.strip()

    return request_line, headers


def build_switching_protocols(headers: dict) -> bytes:
    """101 response. Adds a correct Sec-WebSocket-Accept when the client
    actually sent a Sec-WebSocket-Key (real WS clients do), but never
    requires one - most SSH-WS client apps don't send it."""
    lines = ["HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade"]
    ws_key = headers.get("sec-websocket-key")
    if ws_key:
        accept = base64.b64encode(
            hashlib.sha1((ws_key + WS_MAGIC).encode()).digest()
        ).decode()
        lines.append(f"Sec-WebSocket-Accept: {accept}")
    lines.append("")
    lines.append("")
    return "\r\n".join(lines).encode()


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await reader.read(BUF_SIZE)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, OSError):
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    peer = writer.get_extra_info("peername")

    try:
        request_line, headers = await read_http_request(reader)
    except (asyncio.TimeoutError, ConnectionError) as exc:
        log.info("dropping %s: %s", peer, exc)
        writer.close()
        return

    if "websocket" not in headers.get("upgrade", "").lower():
        log.info("rejecting %s: no websocket upgrade (%r)", peer, request_line)
        writer.write(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        await writer.drain()
        writer.close()
        return

    try:
        ssh_reader, ssh_writer = await asyncio.open_connection(SSH_HOST, SSH_PORT)
    except OSError as exc:
        log.warning("cannot reach local sshd at %s:%s (%s)", SSH_HOST, SSH_PORT, exc)
        writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        await writer.drain()
        writer.close()
        return

    writer.write(build_switching_protocols(headers))
    await writer.drain()

    log.info("session opened from %s", peer)
    await asyncio.gather(
        pipe(reader, ssh_writer),
        pipe(ssh_reader, writer),
        return_exceptions=True,
    )
    log.info("session closed from %s", peer)


async def main() -> None:
    server = await asyncio.start_server(handle_client, LISTEN_HOST, LISTEN_PORT)
    log.info("listening on %s:%s -> sshd %s:%s", LISTEN_HOST, LISTEN_PORT, SSH_HOST, SSH_PORT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())

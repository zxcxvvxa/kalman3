#!/usr/bin/env python3
"""
ssh_ws.py - minimal WebSocket <-> TCP bridge that exposes local sshd over WS.

nginx forwards the client's Upgrade: websocket request straight through
(proxy_http_version 1.1 + Upgrade/Connection headers), so this process is
the one that actually terminates the WebSocket handshake and framing.
Every accepted WS connection opens a fresh TCP connection to the real
sshd (bound to 127.0.0.1:22) and relays bytes in both directions.
"""
import asyncio
import logging
import os

import websockets

LISTEN_HOST = os.environ.get("SSH_WS_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("SSH_WS_LISTEN_PORT", "10005"))
SSH_HOST = os.environ.get("SSH_WS_TARGET_HOST", "127.0.0.1")
SSH_PORT = int(os.environ.get("SSH_WS_TARGET_PORT", "22"))
BUF_SIZE = 65536

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [ssh-ws] %(message)s",
)
log = logging.getLogger("ssh-ws")


async def tcp_to_ws(reader: asyncio.StreamReader, ws) -> None:
    try:
        while True:
            data = await reader.read(BUF_SIZE)
            if not data:
                break
            await ws.send(data)
    except (websockets.ConnectionClosed, ConnectionResetError, OSError):
        pass
    finally:
        try:
            await ws.close()
        except Exception:
            pass


async def ws_to_tcp(ws, writer: asyncio.StreamWriter) -> None:
    try:
        async for message in ws:
            if isinstance(message, str):
                message = message.encode("utf-8", "ignore")
            writer.write(message)
            await writer.drain()
    except (websockets.ConnectionClosed, ConnectionResetError, OSError):
        pass
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def handler(ws) -> None:
    peer = ws.remote_address
    try:
        reader, writer = await asyncio.open_connection(SSH_HOST, SSH_PORT)
    except OSError as exc:
        log.warning("cannot reach local sshd at %s:%s (%s)", SSH_HOST, SSH_PORT, exc)
        await ws.close(code=1011, reason="upstream unavailable")
        return

    log.info("session opened from %s", peer)
    await asyncio.gather(
        tcp_to_ws(reader, ws),
        ws_to_tcp(ws, writer),
        return_exceptions=True,
    )
    log.info("session closed from %s", peer)


async def main() -> None:
    async with websockets.serve(
        handler,
        LISTEN_HOST,
        LISTEN_PORT,
        max_size=None,       # SSH traffic is arbitrary binary, don't cap frame size
        ping_interval=20,
        ping_timeout=20,
        compression=None,    # SSH traffic is already encrypted, compression buys nothing
    ):
        log.info("listening on %s:%s -> sshd %s:%s", LISTEN_HOST, LISTEN_PORT, SSH_HOST, SSH_PORT)
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    asyncio.run(main())

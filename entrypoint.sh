#!/bin/bash
set -e

echo "[+] Starting container initialization..."

# 1. File descriptor limits (best-effort; some sandboxed hosts like Cloud Run
#    disallow raising this, so never fail the container over it).
ulimit -n 65535 2>/dev/null || true

# 2. SSH host keys (generated fresh on first boot if missing).
echo "[+] Generating SSH host keys..."
mkdir -p /run/sshd /var/run/sshd
ssh-keygen -A

# 3. Make sure the xray/log dirs supervisord's children expect exist.
mkdir -p /var/log/supervisor

echo "[+] Handing over process management to supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf

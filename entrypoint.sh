#!/bin/bash
set -e

echo "[+] Starting container initialization..."

# 1. File Descriptor Limits (Matched to Nginx worker_rlimit_nofile)
ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null || true

# 2. Kernel & TCP Socket Tuning (Attempted for privileged runtimes, failsafe in Cloud Run/containers)
echo "[+] Attempting Kernel & TCP Socket Tuning..."
# BBR & Queue Management
sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true

# Maximize Connection Backlogs for Epoll / worker_connections (161072)
sysctl -w net.core.somaxconn=65535 2>/dev/null || true
sysctl -w net.core.netdev_max_backlog=65535 2>/dev/null || true

# Buffer Sizes (16MB max buffers)
sysctl -w net.core.rmem_max=16777216 2>/dev/null || true
sysctl -w net.core.wmem_max=16777216 2>/dev/null || true
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216" 2>/dev/null || true
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216" 2>/dev/null || true

# Ephemeral Port Range Expansion & Socket Recycling
sysctl -w net.ipv4.ip_local_port_range="1024 65535" 2>/dev/null || true
sysctl -w net.ipv4.tcp_fin_timeout=15 2>/dev/null || true
sysctl -w net.ipv4.tcp_tw_reuse=1 2>/dev/null || true
sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null || true

echo "[+] Generating SSH Host Keys..."
ssh-keygen -A 2>/dev/null || true
mkdir -p /run/sshd /var/run/sshd

echo "[+] Handing over process management to Supervisor..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf

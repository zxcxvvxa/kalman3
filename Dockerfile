FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# --- base packages -----------------------------------------------------
# haproxy + nginx + openssh-server : full stack, apt-installed (glibc, not musl)
# python3                          : runs ssh_ws.py (pure-stdlib WS<->TCP bridge)
# supervisor                       : process manager
# build-essential/cmake/git        : only needed transiently to build badvpn
RUN apt-get update && apt-get install -y \
        ca-certificates wget unzip curl git cmake build-essential \
        haproxy nginx openssh-server supervisor python3 tzdata \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- xray-core -----------------------------------------------------------
RUN wget -qO /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip && \
    unzip -j /tmp/xray.zip xray -d /usr/local/bin/ && \
    chmod +x /usr/local/bin/xray && \
    rm -rf /tmp/xray.zip

# --- BadVPN UDPGW ---------------------------------------------------------
# Build tools installed above are removed afterward to keep the image slim.
RUN git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/badvpn \
    && mkdir -p /tmp/badvpn/build \
    && cd /tmp/badvpn/build \
    && cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    && make -j"$(nproc)" install \
    && cd / \
    && rm -rf /tmp/badvpn \
    && apt-get purge -y build-essential cmake git \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# --- SSH user + sshd hardening/tuning ---------------------------------------
# NOTE: change this password (or switch to key-only auth) before exposing
# this publicly - password auth + a known default password is not safe
# to leave as-is on the internet.
RUN useradd -m -s /bin/bash cxlvin \
    && echo 'cxlvin:cxlvin' | chpasswd \
    && mkdir -p /run/sshd /var/run/sshd

RUN sed -i \
      -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
      -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
      -e 's/^#\?UseDNS.*/UseDNS no/' \
      -e 's/^#\?Port .*/Port 22/' \
      /etc/ssh/sshd_config \
    && { \
        echo "ListenAddress 127.0.0.1"; \
        echo "TCPKeepAlive yes"; \
        echo "ClientAliveInterval 15"; \
        echo "ClientAliveCountMax 3"; \
        echo "MaxSessions 50"; \
        echo "MaxStartups 50:30:100"; \
        echo "Compression no"; \
        echo "AllowTcpForwarding yes"; \
        echo "PermitOpen any"; \
        echo "LogLevel VERBOSE"; \
    } >> /etc/ssh/sshd_config

# sshd only listens on 127.0.0.1:22 - it is never reachable directly, only
# through ssh_ws.py -> haproxy:8080, same as every other protocol in this image.

COPY banner.txt /etc/ssh/banner.txt
RUN echo "Banner /etc/ssh/banner.txt" >> /etc/ssh/sshd_config

COPY config.json /etc/xray.json
COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY nginx.conf /etc/nginx/nginx.conf
COPY index.html /var/lib/nginx/html/index.html
COPY ssh_ws.py /usr/local/bin/ssh_ws.py
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/ssh_ws.py \
    && mkdir -p /var/log/supervisor \
    && mkdir -p /var/lib/nginx/html

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]

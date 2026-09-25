FROM haproxy:alpine
USER root

ENV TZ=Asia/Shanghai
ENV DEBIAN_FRONTEND=noninteractive

# --- base packages ---------------------------------------------------------
# ca-certificates/wget/unzip/nginx : original stack
# openssh + openssh-server        : real sshd that SSH-WS tunnels into
# python3 + py3-pip               : runs ssh_ws.py (WS<->TCP bridge)
# supervisor                      : process manager (replaces the old `&` chaining)
# tzdata                          : so ENV TZ actually takes effect
RUN apk add --no-cache \
        ca-certificates wget unzip nginx tzdata \
        openssh openssh-server \
        python3 py3-pip \
        supervisor \
    && cp /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo "$TZ" > /etc/timezone

# websockets ships musllinux wheels (no compiler needed on Alpine)
RUN pip3 install --no-cache-dir --break-system-packages "websockets>=13,<16"

# --- xray-core ---------------------------------------------------------
RUN wget -qO /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip && \
    unzip -j /tmp/xray.zip xray -d /usr/local/bin/ && \
    chmod +x /usr/local/bin/xray && \
    rm -rf /tmp/xray.zip

# --- BadVPN UDPGW -----------------------------------------------------------
# Lets clients tunnel UDP (games, DNS, etc.) through the SSH connection via
# the SSH client's own local port-forward to 127.0.0.1:7300 on this box.
# Build tools are installed into a virtual package and removed right after
# so they don't stick around in the final image.
RUN apk add --no-cache --virtual .badvpn-build-deps build-base cmake git \
    && git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/badvpn \
    && mkdir -p /tmp/badvpn/build \
    && cd /tmp/badvpn/build \
    && cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
    && make -j"$(nproc)" install \
    && cd / \
    && rm -rf /tmp/badvpn \
    && apk del .badvpn-build-deps

# --- SSH user + sshd hardening/tuning ---------------------------------------
# NOTE: change this password (or switch to key-only auth) before exposing
# this publicly - password auth + a known default password is not safe
# to leave as-is on the internet.
RUN adduser -D -s /bin/sh cxlvin \
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
    } >> /etc/ssh/sshd_config

# sshd only listens on 127.0.0.1:22 - it is never reachable directly, only
# through ssh_ws.py -> nginx -> haproxy:8080, same as every other protocol
# in this image.

COPY banner.txt /etc/ssh/banner.txt
RUN echo "Banner /etc/ssh/banner.txt" >> /etc/ssh/sshd_config

COPY config.json /etc/xray.json
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY nginx.conf /etc/nginx/nginx.conf
COPY index.html /var/lib/nginx/html/index.html
COPY ssh_ws.py /usr/local/bin/ssh_ws.py
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/ssh_ws.py \
    && mkdir -p /var/log/supervisor

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]

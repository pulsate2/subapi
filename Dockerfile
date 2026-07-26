FROM weishaw/sub2api:latest

LABEL maintainer="Sub2API + Optional Cloudflare Tunnel"
LABEL description="Official sub2api with optional CF Tunnel (HTTP/2) for Render"

# 安装 dumb-init + cloudflared
RUN apk add --no-cache dumb-init curl ca-certificates tzdata && \
    ARCH=$(apk --print-arch) && \
    if [ "$ARCH" = "x86_64" ]; then \
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        -o /usr/local/bin/cloudflared; \
    elif [ "$ARCH" = "aarch64" ]; then \
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 \
        -o /usr/local/bin/cloudflared; \
    else \
      echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    chmod +x /usr/local/bin/cloudflared

# 自定义启动脚本（TUNNEL_TOKEN 可选）
COPY <<'EOF' /app/docker-entrypoint.sh
#!/bin/sh
set -e

export PORT="${PORT:-8080}"

echo "============================================================="
echo "🚀 Sub2API (官方镜像版) 启动"
echo "📍 监听端口: ${PORT}"
echo "🌐 模式: ${TUNNEL_TOKEN:+TUNNEL MODE (Cloudflare Tunnel + HTTP/2)}${TUNNEL_TOKEN:-DIRECT MODE}"
echo "============================================================="

if [ -n "${TUNNEL_TOKEN:-}" ]; then
    echo "🌩️  启动 Cloudflared (后台运行)..."
    cloudflared tunnel --no-autoupdate run \
        --protocol http2 \
        --token "$TUNNEL_TOKEN" \
        > /proc/1/fd/1 2>&1 &
fi

echo "🌟 启动 Sub2API 为主进程..."
exec dumb-init /app/sub2api
EOF

RUN chmod +x /app/docker-entrypoint.sh

ENTRYPOINT ["/app/docker-entrypoint.sh"]

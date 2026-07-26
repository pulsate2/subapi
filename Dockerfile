FROM weishaw/sub2api:latest

LABEL maintainer="Sub2API + CF Tunnel for Render"
LABEL description="Fixed AUTO_SETUP with external PostgreSQL"

RUN apk add --no-cache dumb-init curl ca-certificates tzdata && \
    ARCH=$(apk --print-arch) && \
    if [ "$ARCH" = "x86_64" ]; then \
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared; \
    elif [ "$ARCH" = "aarch64" ]; then \
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o /usr/local/bin/cloudflared; \
    else \
      echo "Unsupported architecture" && exit 1; \
    fi && \
    chmod +x /usr/local/bin/cloudflared

COPY <<'EOF' /app/docker-entrypoint.sh
#!/bin/sh
set -e

echo "============================================================="
echo "🚀 Sub2API Render 启动 (强化版)"
echo "📍 PORT = ${PORT:-8080}"
echo "🔧 AUTO_SETUP = ${AUTO_SETUP:-false}"
echo "🌐 TUNNEL = ${TUNNEL_TOKEN:+ENABLED}${TUNNEL_TOKEN:-DISABLED}"
echo "============================================================="

# 关键修复：强制清理旧配置，让 AUTO_SETUP 从环境变量重新生成
echo "🧹 清理旧配置..."
rm -f /app/data/config.yaml
rm -f /app/data/.env

# 强制设置核心变量
export AUTO_SETUP=true
export RUN_MODE=release
export GIN_MODE=release
export SERVER_HOST=0.0.0.0
export SERVER_PORT="${PORT:-8080}"

# 调试输出（隐藏密码）
if [ -n "${DATABASE_URL}" ]; then
    echo "✅ 已读取 DATABASE_URL: ${DATABASE_URL%%:*}://***@***"
else
    echo "❌ 未检测到 DATABASE_URL！请检查 Render 环境变量设置"
fi

if [ -n "${REDIS_URL}" ]; then
    echo "✅ 已读取 REDIS_URL"
else
    echo "❌ 未检测到 REDIS_URL！"
fi

# 启动 Cloudflare Tunnel（如果设置了 Token）
if [ -n "${TUNNEL_TOKEN:-}" ]; then
    echo "🌩️ 启动 Cloudflared Tunnel (HTTP/2)..."
    cloudflared tunnel --no-autoupdate run --protocol http2 --token "$TUNNEL_TOKEN" > /proc/1/fd/1 2>&1 &
fi

echo "⏳ 等待外部数据库就绪 (10秒)..."
sleep 10

echo "🌟 启动 Sub2API 主进程..."
exec dumb-init /app/sub2api
EOF

RUN chmod +x /app/docker-entrypoint.sh

ENTRYPOINT ["/app/docker-entrypoint.sh"]

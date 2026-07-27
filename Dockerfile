FROM weishaw/sub2api:latest

LABEL maintainer="Sub2API + Embedded Redis + Cloudflare Tunnel"
LABEL description="No Upstash | Redis runs inside container"

# 安装 redis + cloudflared + 必要工具
RUN apk add --no-cache dumb-init redis curl ca-certificates tzdata && \
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
    chmod +x /usr/local/bin/cloudflared && \
    echo "✅ cloudflared 和 redis 已安装完成"

COPY <<'EOF' /app/docker-entrypoint.sh
#!/bin/sh
set -e

echo "============================================================="
echo "🚀 Sub2API + 内嵌 Redis 启动 (不使用 Upstash)"
echo "📍 PORT = ${PORT:-8080}"
echo "============================================================="

# ==================== 变量检查 ====================
echo "🔍 环境变量检查："
echo "   • POSTGRES_HOST       : $([ -n "${POSTGRES_HOST}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • POSTGRES_USER       : $([ -n "${POSTGRES_USER}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • POSTGRES_PASSWORD   : $([ -n "${POSTGRES_PASSWORD}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • POSTGRES_DB         : $([ -n "${POSTGRES_DB}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • JWT_SECRET          : $([ -n "${JWT_SECRET}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • TOTP_ENCRYPTION_KEY : $([ -n "${TOTP_ENCRYPTION_KEY}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • TUNNEL_TOKEN        : $([ -n "${TUNNEL_TOKEN}" ] && echo "[SET] (Tunnel Mode)" || echo "[NOT SET] (Direct Mode)")"
echo "============================================================="

# 严格检查必要变量
if [ -z "$POSTGRES_HOST" ] || [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || \
   [ -z "$POSTGRES_DB" ] || [ -z "$JWT_SECRET" ] || [ -z "$TOTP_ENCRYPTION_KEY" ]; then
    echo "❌ 错误：缺少必须的环境变量，请检查 Render 设置"
    exit 1
fi

# 启动内嵌 Redis
echo "🗄️  启动内嵌 Redis (localhost:6379)..."
redis-server --daemonize yes \
    --port 6379 \
    --protected-mode no \
    --save "" \
    --appendonly no \
    --maxmemory 400mb \
    --maxmemory-policy allkeys-lru

echo "✅ Redis 内嵌服务已启动"

# 清理旧配置
rm -rf /app/data/* /app/config.yaml 2>/dev/null || true
mkdir -p /app/data

# 生成 config.yaml（使用内嵌 Redis）
cat > /app/config.yaml << CONFIG
server:
  host: "0.0.0.0"
  port: ${PORT:-8080}
  mode: "release"

database:
  host: "${POSTGRES_HOST}"
  port: ${DATABASE_PORT:-5432}
  user: "${POSTGRES_USER}"
  password: "${POSTGRES_PASSWORD}"
  dbname: "${POSTGRES_DB}"
  sslmode: "require"

redis:
  host: "127.0.0.1"
  port: 6379

jwt:
  secret: "${JWT_SECRET}"
  expire_hour: 24

totp:
  encryption_key: "${TOTP_ENCRYPTION_KEY}"

default:
  user_concurrency: 10
  user_balance: 0
  api_key_prefix: "sk-"
  rate_multiplier: 1.0

security:
  url_allowlist_enabled: true
CONFIG

cp /app/config.yaml /app/data/config.yaml
echo "✅ config.yaml 已生成（使用内嵌 Redis）"
echo "============================================================="

# 启动 Cloudflare Tunnel（仅当设置了 TUNNEL_TOKEN 时）
if [ -n "${TUNNEL_TOKEN:-}" ]; then
    echo "🌩️ 启动 Cloudflared Tunnel (HTTP/2)..."
    if command -v cloudflared >/dev/null 2>&1; then
        cloudflared tunnel --no-autoupdate run --protocol http2 --token "$TUNNEL_TOKEN" > /proc/1/fd/1 2>&1 &
        echo "✅ Cloudflared 已启动"
    else
        echo "❌ cloudflared 命令不存在！"
        exit 1
    fi
else
    echo "🌐 当前为 Direct Mode（未启用 Cloudflare Tunnel）"
fi

echo "⏳ 等待服务就绪 (12秒)..."
sleep 12

echo "🌟 启动 Sub2API 主进程..."
exec dumb-init /app/sub2api
EOF

RUN chmod +x /app/docker-entrypoint.sh

ENTRYPOINT ["/app/docker-entrypoint.sh"]

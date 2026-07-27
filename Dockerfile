FROM weishaw/sub2api:latest

LABEL maintainer="Sub2API + Embedded Redis (No Upstash)"
LABEL description="Redis runs inside container - Save quota"

# 安装 redis + 必要工具
RUN apk add --no-cache dumb-init curl ca-certificates tzdata redis

COPY <<'EOF' /app/docker-entrypoint.sh
#!/bin/sh
set -e

echo "============================================================="
echo "🚀 Sub2API + 内嵌 Redis 启动 (无 Upstash)"
echo "📍 PORT = ${PORT:-8080}"
echo "============================================================="

# ==================== 环境变量检查 ====================
echo "🔍 变量检查："
echo "   • POSTGRES_HOST     : $([ -n "${POSTGRES_HOST}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • POSTGRES_USER     : $([ -n "${POSTGRES_USER}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • POSTGRES_PASSWORD : $([ -n "${POSTGRES_PASSWORD}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • POSTGRES_DB       : $([ -n "${POSTGRES_DB}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • JWT_SECRET        : $([ -n "${JWT_SECRET}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • TOTP_ENCRYPTION_KEY : $([ -n "${TOTP_ENCRYPTION_KEY}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "============================================================="

if [ -z "$POSTGRES_HOST" ] || [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || \
   [ -z "$POSTGRES_DB" ] || [ -z "$JWT_SECRET" ] || [ -z "$TOTP_ENCRYPTION_KEY" ]; then
    echo "❌ 错误：缺少必须的环境变量"
    exit 1
fi

# 启动内嵌 Redis（禁用持久化，节省 IO）
echo "🗄️  启动内嵌 Redis Server (localhost:6379)..."
redis-server --daemonize yes \
    --port 6379 \
    --protected-mode no \
    --save "" \
    --appendonly no \
    --maxmemory 512mb \
    --maxmemory-policy allkeys-lru

echo "✅ Redis 内嵌服务已启动"

# 清理旧配置 + 生成 config.yaml
rm -rf /app/data/* /app/config.yaml 2>/dev/null || true
mkdir -p /app/data

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

# Cloudflare Tunnel（可选）
if [ -n "${TUNNEL_TOKEN:-}" ]; then
    echo "🌩️ 启动 Cloudflared Tunnel (HTTP/2)..."
    cloudflared tunnel --no-autoupdate run --protocol http2 --token "$TUNNEL_TOKEN" > /proc/1/fd/1 2>&1 &
fi

echo "⏳ 等待服务就绪 (12秒)..."
sleep 12

echo "🌟 启动 Sub2API 主进程..."
exec dumb-init /app/sub2api
EOF

RUN chmod +x /app/docker-entrypoint.sh

ENTRYPOINT ["/app/docker-entrypoint.sh"]

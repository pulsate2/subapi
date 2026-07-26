FROM weishaw/sub2api:latest

LABEL maintainer="Sub2API + CF Tunnel (Official .env.example style)"
LABEL description="Fixed migration + external PostgreSQL for Render"

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
echo "🚀 Sub2API Render 启动 (基于官方 .env.example)"
echo "📍 PORT = ${PORT:-8080}"
echo "============================================================="

# ==================== 变量检查 ====================
echo "🔍 变量检查结果："
echo "   • POSTGRES_HOST     : $([ -n "${POSTGRES_HOST}" ] && echo "[SET]" || echo "[MISSING]")"
echo "   • POSTGRES_USER     : $([ -n "${POSTGRES_USER}" ] && echo "[SET]" || echo "[MISSING]")"
echo "   • POSTGRES_PASSWORD : $([ -n "${POSTGRES_PASSWORD}" ] && echo "[SET]" || echo "[MISSING]")"
echo "   • POSTGRES_DB       : $([ -n "${POSTGRES_DB}" ] && echo "[SET]" || echo "[MISSING]")"
echo "   • JWT_SECRET        : $([ -n "${JWT_SECRET}" ] && echo "[SET]" || echo "[MISSING]")"
echo "   • TOTP_ENCRYPTION_KEY : $([ -n "${TOTP_ENCRYPTION_KEY}" ] && echo "[SET]" || echo "[MISSING]")"
echo "   • REDIS_URL         : $([ -n "${REDIS_URL}" ] && echo "[SET]" || echo "[MISSING]")"
echo "============================================================="

if [ -z "$POSTGRES_HOST" ] || [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || \
   [ -z "$POSTGRES_DB" ] || [ -z "$JWT_SECRET" ] || [ -z "$TOTP_ENCRYPTION_KEY" ] || [ -z "$REDIS_URL" ]; then
    echo "❌ 错误：存在必须的环境变量未设置！"
    exit 1
fi

# 清理历史配置（防止残留 config.yaml 导致连 localhost）
rm -rf /app/data/* /app/config.yaml 2>/dev/null || true
mkdir -p /app/data
chmod 755 /app/data

echo "🛠️ 生成正确的 config.yaml ..."

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
  max_open_conns: 128
  max_idle_conns: 64

redis:
  url: "${REDIS_URL}"

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

admin:
  email: "${ADMIN_EMAIL:-admin@admin.com}"
  password: "${ADMIN_PASSWORD:-admin123}"
CONFIG

cp /app/config.yaml /app/data/config.yaml

export CONFIG_FILE=/app/config.yaml
export AUTO_SETUP=true
export SETUP_MIGRATION_TIMEOUT_SECONDS=120
export RUN_MODE=standard
export SERVER_MODE=release

echo "✅ config.yaml 已生成并生效"
echo "✅ SETUP_MIGRATION_TIMEOUT_SECONDS=120（解决 migration lock 问题）"
echo "============================================================="

# Cloudflare Tunnel（可选）
if [ -n "${TUNNEL_TOKEN:-}" ]; then
    echo "🌩️ 启动 Cloudflared Tunnel (HTTP/2)..."
    cloudflared tunnel --no-autoupdate run --protocol http2 --token "$TUNNEL_TOKEN" > /proc/1/fd/1 2>&1 &
fi

echo "⏳ 等待外部数据库就绪 (15秒)..."
sleep 15

echo "🌟 启动 Sub2API 主进程..."
exec dumb-init /app/sub2api
EOF

RUN chmod +x /app/docker-entrypoint.sh

ENTRYPOINT ["/app/docker-entrypoint.sh"]

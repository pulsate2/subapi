FROM weishaw/sub2api:latest

LABEL maintainer="Sub2API + CF Tunnel for Render (Fixed DB Config)"
LABEL description="Correct database config structure + diagnostics"

RUN apk add --no-cache dumb-init curl ca-certificates tzdata && \
    ARCH=$(apk --print-arch) && \
    if [ "$ARCH" = "x86_64" ]; then \
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared; \
    elif [ "$ARCH" = "aarch64" ]; then \
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o /usr/local/bin/cloudflared; \
    else \
      echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    chmod +x /usr/local/bin/cloudflared

COPY <<'EOF' /app/docker-entrypoint.sh
#!/bin/sh
set -e

echo "============================================================="
echo "🚀 Sub2API Render 启动 - 修复版（正确 config 结构）"
echo "📍 PORT = ${PORT:-8080}"
echo "============================================================="

# ==================== 严格环境变量检查 ====================
echo "🔍 环境变量检查："
echo "   • DATABASE_URL        : $([ -n "${DATABASE_URL}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • REDIS_URL           : $([ -n "${REDIS_URL}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • JWT_SECRET          : $([ -n "${JWT_SECRET}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • TOTP_ENCRYPTION_KEY : $([ -n "${TOTP_ENCRYPTION_KEY}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "============================================================="

if [ -z "$DATABASE_URL" ] || [ -z "$REDIS_URL" ] || [ -z "$JWT_SECRET" ] || [ -z "$TOTP_ENCRYPTION_KEY" ]; then
    echo "❌ 错误：存在必须的环境变量未设置"
    exit 1
fi

# 解析 DATABASE_URL 为官方要求的拆分字段
echo "🔧 正在解析 DATABASE_URL..."
# 简单解析 postgres://user:pass@host:port/dbname?sslmode=...
DB_USER=$(echo "${DATABASE_URL}" | sed -E 's|.*://([^:]+):.*|\1|')
DB_PASS=$(echo "${DATABASE_URL}" | sed -E 's|.*://[^:]+:([^@]+)@.*|\1|')
DB_HOST=$(echo "${DATABASE_URL}" | sed -E 's|.*@([^:]+):.*|\1|')
DB_PORT=$(echo "${DATABASE_URL}" | sed -E 's|.*:([0-9]+)/.*|\1|')
DB_NAME=$(echo "${DATABASE_URL}" | sed -E 's|.*/([^?]+).*|\1|')

echo "✅ 解析完成 → Host: ${DB_HOST}, Port: ${DB_PORT}, DB: ${DB_NAME}"

# 清理旧配置
rm -rf /app/data/* /app/config.yaml 2>/dev/null || true
mkdir -p /app/data
chmod 755 /app/data

echo "🛠️ 生成 config.yaml 到 /app/config.yaml 和 /app/data/config.yaml ..."

cat > /app/config.yaml << CONFIG
server:
  host: "0.0.0.0"
  port: ${PORT:-8080}
  mode: "release"

database:
  host: "${DB_HOST}"
  port: ${DB_PORT}
  user: "${DB_USER}"
  password: "${DB_PASS}"
  dbname: "${DB_NAME}"
  sslmode: "require"

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
  url_allowlist_allow_insecure_http: false
CONFIG

cp /app/config.yaml /app/data/config.yaml

echo "✅ config.yaml 已生成（内容已隐藏）"
echo "============================================================="

if [ -n "${TUNNEL_TOKEN:-}" ]; then
    echo "🌩️ 启动 Cloudflared Tunnel (HTTP/2)..."
    cloudflared tunnel --no-autoupdate run --protocol http2 --token "$TUNNEL_TOKEN" > /proc/1/fd/1 2>&1 &
fi

echo "⏳ 等待数据库就绪 (12秒)..."
sleep 12

echo "🌟 启动 Sub2API 主进程..."
exec dumb-init /app/sub2api
EOF

RUN chmod +x /app/docker-entrypoint.sh

ENTRYPOINT ["/app/docker-entrypoint.sh"]

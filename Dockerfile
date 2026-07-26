FROM weishaw/sub2api:latest

LABEL maintainer="Sub2API + CF Tunnel for Render"
LABEL description="Force config.yaml for external PostgreSQL + Upstash"

# 安装必要工具
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

# 创建启动脚本（所有逻辑都在这里面）
COPY <<'EOF' /app/docker-entrypoint.sh
#!/bin/sh
set -e

echo "============================================================="
echo "🚀 Sub2API Render 启动 - 强制生成 config.yaml"
echo "📍 PORT = ${PORT:-8080}"
echo "============================================================="

# 彻底清理旧配置
rm -rf /app/data/*
mkdir -p /app/data
chmod 755 /app/data

# 检查必要环境变量
if [ -z "$DATABASE_URL" ]; then
    echo "❌ 错误: 未设置 DATABASE_URL"
    echo "请在 Render 设置 DATABASE_URL=postgres://user:pass@host:5432/dbname?sslmode=require"
    exit 1
fi

if [ -z "$REDIS_URL" ]; then
    echo "❌ 错误: 未设置 REDIS_URL"
    exit 1
fi

if [ -z "$JWT_SECRET" ]; then
    echo "❌ 错误: 未设置 JWT_SECRET"
    exit 1
fi

echo "✅ DATABASE_URL 已读取"
echo "✅ REDIS_URL 已读取"
echo "✅ JWT_SECRET 已读取"
echo "🛠️ 正在生成 /app/data/config.yaml ..."

# 生成完整的 config.yaml
cat > /app/data/config.yaml << CONFIG
server:
  host: "0.0.0.0"
  port: ${PORT:-8080}
  mode: "release"

database:
  url: "${DATABASE_URL}"
  type: "postgres"

redis:
  url: "${REDIS_URL}"

jwt:
  secret: "${JWT_SECRET}"
  expire_hour: 24

totp:
  encryption_key: "${TOTP_ENCRYPTION_KEY:-default_encryption_key_change_me}"

default:
  user_concurrency: 10
  user_balance: 0
  api_key_prefix: "sk-"
  rate_multiplier: 1.0

security:
  url_allowlist_enabled: true
  url_allowlist_allow_insecure_http: false

admin:
  email: "${ADMIN_EMAIL:-admin@admin.com}"
  password: "${ADMIN_PASSWORD:-admin123}"
CONFIG

echo "✅ config.yaml 生成完成，内容如下："
cat /app/data/config.yaml
echo "============================================================="

# 启动 Cloudflare Tunnel（可选）
if [ -n "${TUNNEL_TOKEN:-}" ]; then
    echo "🌩️ 启动 Cloudflared Tunnel (HTTP/2)..."
    cloudflared tunnel --no-autoupdate run --protocol http2 --token "$TUNNEL_TOKEN" > /proc/1/fd/1 2>&1 &
fi

echo "⏳ 等待数据库就绪 (10秒)..."
sleep 10

echo "🌟 启动 Sub2API 主进程..."
exec dumb-init /app/sub2api
EOF

RUN chmod +x /app/docker-entrypoint.sh

ENTRYPOINT ["/app/docker-entrypoint.sh"]

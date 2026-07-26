FROM weishaw/sub2api:latest

LABEL maintainer="Sub2API + CF Tunnel for Render (Force config.yaml)"
LABEL description="Fixed external PG by generating config.yaml"

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
echo "🚀 Sub2API Render 启动 - 强制生成 config.yaml"
echo "📍 PORT = ${PORT:-8080}"
echo "🌐 TUNNEL = ${TUNNEL_TOKEN:+ENABLED}${TUNNEL_TOKEN:-DISABLED}"
echo "============================================================="

# 彻底清理旧配置（关键！）
rm -rf /app/data/*
mkdir -p /app/data
chmod 755 /app/data

# 强制设置核心变量
export SERVER_PORT="${PORT:-8080}"
export SERVER_HOST="0.0.0.0"

if [ -z "$DATABASE_URL" ]; then
    echo "❌ 错误: 未设置 DATABASE_URL"
    echo "请在 Render 设置 DATABASE_URL=postgres://user:pass@host:5432/dbname?sslmode=require"
    exit 1
fi

if [ -z "$REDIS_URL" ]; then
    echo "❌ 错误: 未设置 REDIS_URL"
    exit 1
fi

echo "✅ DATABASE_URL 已读取: ${DATABASE_URL%%@*}@***"
echo "✅ REDIS_URL 已读取"
echo "🛠️ 正在生成 /app/data/config.yaml ..."

# 动态生成 config.yaml（这是最可靠的方式）
cat > /app/data/config.yaml << EOF
server:
  host: "0.0.0.0"
  port: ${SERVER_PORT}
  mode: "release"

database:
  url: "${DATABASE_URL}"

redis:
  url: "${REDIS_URL}"

jwt:
  secret: "${JWT_SECRET}"
  expire_hour: 24

default:
  user_concurrency: 10
  user_balance: 0
  api_key_prefix: "sk-"
  rate_multiplier: 1.0

security:
  url_allowlist_enabled: true
  url_allowlist_allow_insecure_http: false
EOF

echo "✅ config.yaml 已生成，内容如下："
cat /app/data/config.yaml
echo "============================================================="

# 如果设置了 TUNNEL_TOKEN，则后台启动 Cloudflare Tunnel
if [ -n "${TUNNEL_TOKEN:-}" ]; then
    echo "🌩️ 启动 Cloudflared Tunnel (HTTP/2)..."
    cloudflared tunnel --no-autoupdate run --protocol http2 --token "$TUNNEL_TOKEN" > /proc/1/fd/1 2>&1 &
fi

echo "⏳ 等待 8 秒让数据库就绪..."
sleep 8

echo "🌟 启动 Sub2API 主进程..."
exec dumb-init /app/sub2api
EOF

RUN chmod +x /app/docker-entrypoint.sh

ENTRYPOINT ["/app/docker-entrypoint.sh"]

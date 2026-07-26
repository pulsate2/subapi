FROM weishaw/sub2api:latest

LABEL maintainer="Sub2API + CF Tunnel for Render"
LABEL description="Strict mode - No fallback, strong diagnostics"

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
echo "🚀 Sub2API Render 启动 - 严格诊断版（无任何兜底）"
echo "📍 PORT = ${PORT:-8080}"
echo "============================================================="

# ==================== 关键环境变量诊断（不输出具体值）===================
echo "🔍 环境变量诊断结果："
echo "   • DATABASE_URL          : $([ -n "${DATABASE_URL}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • REDIS_URL             : $([ -n "${REDIS_URL}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • JWT_SECRET            : $([ -n "${JWT_SECRET}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • TOTP_ENCRYPTION_KEY   : $([ -n "${TOTP_ENCRYPTION_KEY}" ] && echo "[SET]" || echo "[MISSING!]")"
echo "   • ADMIN_EMAIL           : $([ -n "${ADMIN_EMAIL}" ] && echo "[SET]" || echo "[MISSING]")"
echo "   • ADMIN_PASSWORD        : $([ -n "${ADMIN_PASSWORD}" ] && echo "[SET]" || echo "[MISSING]")"
echo "   • TUNNEL_TOKEN          : $([ -n "${TUNNEL_TOKEN}" ] && echo "[SET]" || echo "[NOT SET (DIRECT MODE)]")"
echo "============================================================="

# 严格检查，缺失就直接失败（不做任何自动生成）
if [ -z "$DATABASE_URL" ]; then
    echo "❌ 错误: DATABASE_URL 未读取到"
    exit 1
fi

if [ -z "$REDIS_URL" ]; then
    echo "❌ 错误: REDIS_URL 未读取到"
    exit 1
fi

if [ -z "$JWT_SECRET" ]; then
    echo "❌ 错误: JWT_SECRET 未读取到"
    echo "   请确认你在 Render 的 Environment 变量中真的设置了 JWT_SECRET"
    echo "   注意：变量名称必须完全大写，且必须是 Production 环境而非 Preview"
    exit 1
fi

if [ -z "$TOTP_ENCRYPTION_KEY" ]; then
    echo "❌ 错误: TOTP_ENCRYPTION_KEY 未读取到"
    exit 1
fi

echo "✅ 所有关键环境变量均已检测到"

# 清理旧配置
rm -rf /app/data/*
mkdir -p /app/data
chmod 755 /app/data

echo "🛠️ 正在生成 config.yaml（内容已隐藏）..."

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
  encryption_key: "${TOTP_ENCRYPTION_KEY}"

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

echo "✅ config.yaml 已生成"
echo "============================================================="

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

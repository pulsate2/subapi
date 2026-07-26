# syntax=docker/dockerfile:1.7
# =============================================================================
# Sub2API + Cloudflare Tunnel (单进程版 - TUNNEL_TOKEN 可选)
# - TUNNEL_TOKEN 未设置 → 只运行 sub2api (DIRECT MODE)
# - TUNNEL_TOKEN 已设置 → 后台运行 cloudflared (HTTP/2)
# - sub2api 始终作为前台主进程，日志最清晰
# - 专为 Render + 外部 PostgreSQL + Upstash 优化
# =============================================================================

ARG NODE_IMAGE=node:24-alpine
ARG GOLANG_IMAGE=golang:1.26.5-alpine
ARG ALPINE_IMAGE=alpine:3.21
ARG GOPROXY=https://goproxy.cn,direct

# -----------------------------------------------------------------------------
# Stage 1: Frontend Builder
# -----------------------------------------------------------------------------
FROM --platform=${BUILDPLATFORM} ${NODE_IMAGE} AS frontend-builder
WORKDIR /app/frontend
RUN corepack enable && corepack prepare pnpm@9 --activate

COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN --mount=type=cache,id=sub2api-pnpm,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile --prefer-offline

COPY frontend/ ./
COPY docs/legal/ /app/docs/legal/
RUN pnpm run build

# -----------------------------------------------------------------------------
# Stage 2: Backend Builder
# -----------------------------------------------------------------------------
FROM --platform=${BUILDPLATFORM} ${GOLANG_IMAGE} AS backend-builder

ARG VERSION=
ARG COMMIT=docker
ARG DATE
ARG GOPROXY
ARG TARGETOS
ARG TARGETARCH

ENV GOPROXY=${GOPROXY}
ENV CGO_ENABLED=0

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /app/backend
COPY backend/go.mod backend/go.sum ./
RUN --mount=type=cache,id=sub2api-gomod,target=/go/pkg/mod \
    go mod download

COPY backend/ ./
COPY --from=frontend-builder /app/backend/internal/web/dist ./internal/web/dist

RUN --mount=type=cache,id=sub2api-gomod,target=/go/pkg/mod \
    --mount=type=cache,id=sub2api-gobuild,target=/root/.cache/go-build \
    VERSION_VALUE="${VERSION:-docker}" && \
    DATE_VALUE="${DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" && \
    GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build \
    -tags embed \
    -ldflags="-s -w -X main.Version=${VERSION_VALUE} -X main.Commit=${COMMIT} -X main.Date=${DATE_VALUE}" \
    -trimpath -o /app/sub2api ./cmd/server

# -----------------------------------------------------------------------------
# Stage 3: Runtime (单进程 + TUNNEL_TOKEN 可选)
# -----------------------------------------------------------------------------
FROM ${ALPINE_IMAGE}

LABEL maintainer="Sub2API with Optional Cloudflare Tunnel"
LABEL description="Sub2API (Direct or Tunnel Mode) for Render"

RUN apk add --no-cache \
    ca-certificates \
    tzdata \
    dumb-init \
    curl \
    && rm -rf /var/cache/apk/*

# 安装 cloudflared
RUN ARCH=$(apk --print-arch) && \
    if [ "$ARCH" = "x86_64" ]; then \
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared; \
    elif [ "$ARCH" = "aarch64" ]; then \
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o /usr/local/bin/cloudflared; \
    else \
      echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    chmod +x /usr/local/bin/cloudflared

RUN addgroup -g 1000 sub2api && adduser -u 1000 -G sub2api -s /bin/sh -D sub2api

WORKDIR /app
COPY --from=backend-builder --chown=sub2api:sub2api /app/sub2api /app/sub2api
COPY --from=backend-builder --chown=sub2api:sub2api /app/backend/resources /app/resources

RUN mkdir -p /app/data && chown sub2api:sub2api /app/data

# ==================== 启动脚本（核心修改在这里）====================
COPY <<'EOF' /app/docker-entrypoint.sh
#!/bin/sh
set -e

# 兼容 Render 的 $PORT 变量
export SERVER_PORT="${PORT:-8080}"
export SERVER_HOST="0.0.0.0"

echo "============================================================="
echo "🚀 Sub2API Docker 启动"
echo "📍 监听端口: ${SERVER_PORT}"
echo "============================================================="

if [ -n "${TUNNEL_TOKEN:-}" ]; then
    echo "🌐 模式: TUNNEL MODE (Cloudflare Tunnel + HTTP/2)"
    echo "📡 Cloudflared 后台运行中..."
    
    cloudflared tunnel --no-autoupdate run \
        --protocol http2 \
        --token "$TUNNEL_TOKEN" \
        > /proc/1/fd/1 2>&1 &
    
    CLOUDFLARED_PID=$!
    echo "✅ Cloudflared 已启动 (PID: $CLOUDFLARED_PID)"
    
    trap 'echo "🛑 接收到终止信号，正在关闭..."; kill $CLOUDFLARED_PID 2>/dev/null || true; exit 0' TERM INT
else
    echo "🌐 模式: DIRECT MODE (仅运行 Sub2API，未启用 Cloudflare Tunnel)"
    echo "💡 提示：如需启用 Tunnel，请设置环境变量 TUNNEL_TOKEN"
fi

echo "🌟 启动 Sub2API 为主进程（日志将直接显示）..."
echo "============================================================="

exec dumb-init -- /app/sub2api
EOF

RUN chmod +x /app/docker-entrypoint.sh

USER sub2api

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider "http://127.0.0.1:${PORT:-8080}/health" || exit 1

ENTRYPOINT ["/usr/bin/dumb-init", "--",

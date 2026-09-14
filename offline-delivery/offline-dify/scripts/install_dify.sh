#!/usr/bin/env bash
# install_dify.sh - 离线环境一键启动 Dify (使用 dify 项目自带的 docker-compose)
#
# 设计原则:
#   - 不修改 dify 项目任何文件
#   - 直接调用 dify 项目自带的 docker-compose.yaml
#   - 用户可在 .env 中切换 VECTOR_STORE (weaviate/qdrant/chroma/...)
#   - 持久化数据保存在 dify/docker/volumes/
#
# 前置条件:
#   - 已执行 load_dify.sh 加载所有镜像
#   - dify 项目源码在 DIFY_DIR (默认: /opt/install/dify)
#   - Docker + Docker Compose 已安装
#
# 用法:
#   ./install_dify.sh                                    # 默认参数
#   DIFY_DIR=/path/to/dify ./install_dify.sh             # 指定 dify 目录
#   VECTOR_STORE=qdrant ./install_dify.sh                # 选择其他向量库
#   ACTION=down ./install_dify.sh                        # 停止服务
#   ACTION=status ./install_dify.sh                      # 查看状态
#   ACTION=reset ./install_dify.sh                       # 停止并删除 volumes
#   ACTION=logs ./install_dify.sh                        # 查看日志

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFY_DIR="${DIFY_DIR:-$(cd "$SCRIPT_DIR/../../dify" 2>/dev/null && pwd || echo "")}"
ACTION="${ACTION:-up}"
VECTOR_STORE="${VECTOR_STORE:-weaviate}"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }

command -v docker >/dev/null 2>&1 || fatal "缺少 docker 命令"
docker info >/dev/null 2>&1 || fatal "docker daemon 未运行"

if [[ -z "$DIFY_DIR" ]] || [[ ! -d "$DIFY_DIR/docker" ]]; then
  fatal "找不到 dify 项目目录 (DIFY_DIR=$DIFY_DIR)。请设置 DIFY_DIR 环境变量"
fi

COMPOSE_DIR="$DIFY_DIR/docker"
ENV_FILE="$COMPOSE_DIR/.env"
ENV_EXAMPLE="$COMPOSE_DIR/.env.example"

cd "$COMPOSE_DIR"

# ─── 初始化 .env ───
if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ENV_EXAMPLE" ]]; then
    log "未找到 .env，从 .env.example 复制"
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    warn "请编辑 $ENV_FILE 修改密码等敏感配置后再次执行"
    warn "尤其是: DB_PASSWORD, REDIS_PASSWORD, SECRET_KEY"
  else
    fatal "缺少 .env 和 .env.example，请先准备 dify 项目"
  fi
fi

# ─── 写入向量库选择 ───
if grep -q "^VECTOR_STORE=" "$ENV_FILE"; then
  sed -i "s/^VECTOR_STORE=.*/VECTOR_STORE=${VECTOR_STORE}/" "$ENV_FILE"
else
  echo "VECTOR_STORE=${VECTOR_STORE}" >> "$ENV_FILE"
fi
log "向量库: $VECTOR_STORE"

# ─── 检查关键镜像已加载 ───
check_images() {
  log "检查关键镜像是否已加载..."
  local missing=0
  for img in langgenius/dify-api:1.16.0-rc1 langgenius/dify-web:1.16.0-rc1 \
             postgres:15-alpine redis:6-alpine; do
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      warn "  [MISSING] $img"
      missing=$((missing + 1))
    else
      log "  [OK] $img"
    fi
  done
  if [[ $missing -gt 0 ]]; then
    fatal "缺少 $missing 个关键镜像，请先执行 load_dify.sh"
  fi
}

# ─── 启动 ───
do_up() {
  check_images
  log "========================================"
  log "启动 Dify (docker compose up -d)"
  log "========================================"
  log "项目: $COMPOSE_DIR"
  log "向量库: $VECTOR_STORE"

  # 准备 volumes 目录
  mkdir -p volumes/db/data volumes/redis/data volumes/app/storage \
           volumes/nginx/conf.d volumes/nginx/html volumes/nginx/ssl volumes/nginx/logs \
           volumes/plugin_daemon volumes/weaviate

  # 拷贝 nginx 配置 (如果 dify 仓库有)
  if [[ -d "$COMPOSE_DIR/nginx/conf.d" ]]; then
    cp -rn "$COMPOSE_DIR/nginx/conf.d/." volumes/nginx/conf.d/ 2>/dev/null || true
  fi

  # 拷贝 ssrf_proxy 配置
  if [[ -d "$COMPOSE_DIR/ssrf_proxy" ]]; then
    cp -rn "$COMPOSE_DIR/ssrf_proxy/." volumes/ssrf_proxy/ 2>/dev/null || true
  fi

  # docker compose
  docker compose up -d

  echo ""
  log "========================================"
  log "Dify 已启动"
  log "========================================"
  log "访问地址: http://<host>:80 (或 .env 中 EXPOSE_NGINX_PORT)"
  log "默认账户: 首次访问时设置管理员账号"
  log ""
  log "查看状态: docker compose ps"
  log "查看日志: docker compose logs -f [service]"
  log "停止:     ACTION=down $0"
  log "========================================"
}

# ─── 停止 ───
do_down() {
  log "停止 Dify 服务..."
  docker compose down
  log "已停止"
}

# ─── 状态 ───
do_status() {
  log "Dify 服务状态:"
  docker compose ps
}

# ─── 日志 ───
do_logs() {
  docker compose logs -f --tail=100
}

# ─── 清理 (包括 volumes) ───
do_reset() {
  warn "将停止服务并删除所有数据卷 (不可恢复)"
  read -rp "确认? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { log "已取消"; exit 0; }
  docker compose down -v
  log "已停止并清理所有数据卷"
}

# ─── 分发 ───
case "$ACTION" in
  up|start)
    do_up
    ;;
  down|stop)
    do_down
    ;;
  status|ps)
    do_status
    ;;
  logs)
    do_logs
    ;;
  reset)
    do_reset
    ;;
  *)
    fatal "未知 ACTION: $ACTION (可选: up, down, status, logs, reset)"
    ;;
esac

#!/usr/bin/env bash
# install_db.sh - 数据库/中间件离线一键部署入口
#
# 部署行为由 config/database-package.conf 控制：
#   enabled=true + deploy_mode=docker-compose  -> 使用 docker compose 部署
#   enabled=true + deploy_mode=binary          -> 使用二进制包安装（依赖 third-party/ 下实际安装包）
#   enabled=false                              -> 默认跳过
#
# 用法:
#   ./install_db.sh                            # 按配置文件部署所有启用服务
#   ./install_db.sh mysql redis                # 仅部署指定服务（忽略配置 enabled）
#   ./install_db.sh --binary                   # 仅安装二进制包（Doris/ES/JDK）
#   ./install_db.sh --docker                   # 仅部署 docker-compose 服务
#   ./install_db.sh --start-only [svc...]      # 仅启动服务，不加载镜像
#   ./install_db.sh --status                   # 查看服务状态

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }

# ---- compose 命令检测 ----
detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return 0
  fi
  return 1
}

ensure_compose() {
  # 读取全局架构配置，定位 offline-docker/bin/${ARCH}/docker-compose
  local arch=""
  for _p in "$ROOT_DIR/../arch.env" "$ROOT_DIR/arch.env" "$ROOT_DIR/config/arch.env"; do
    if [[ -f "$_p" ]]; then
      # shellcheck disable=SC1090
      source "$_p"
      arch="${ARCH:-}"
      break
    fi
  done
  arch="${arch:-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')}"

  local compose_src=""
  for candidate in \
    /opt/install/offline-docker/bin/${arch}/docker-compose \
    "$ROOT_DIR/../offline-docker/bin/${arch}/docker-compose" \
    "$(dirname "$ROOT_DIR")/offline-docker/bin/${arch}/docker-compose"; do
    if [[ -f "$candidate" ]]; then
      compose_src="$candidate"
      break
    fi
  done

  if [[ -z "$compose_src" ]]; then
    fatal "未找到可用的 compose 命令，且 offline-docker 包中无 docker-compose 二进制 (arch=${arch})。"
  fi

  log "未检测到 compose，从 offline-docker 包自动安装: $compose_src"
  local plugin_dir="/usr/local/lib/docker/cli-plugins"
  mkdir -p "$plugin_dir"
  install -m 0755 "$compose_src" "$plugin_dir/docker-compose"
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  else
    fatal "compose 插件安装后仍不可用"
  fi
}

# ---- 读取部署配置 ----
CONFIG_FILE="$ROOT_DIR/config/database-package.conf"

# 服务 -> 数据目录映射
declare -A DATA_DIRS=(
  [mysql]="/data/mysql"
  [redis]="/data/redis"
  [kafka]="/data/kafka"
  [nebulagraph]="/data/nebulagraph"
  [nebulagraph-cluster]="/data/nebulagraph"
  [doris]="/data/doris"
  [elasticsearch]="/data/elasticsearch"
)

# 所有已知服务（jdk 仅支持 binary 模式）
ALL_SERVICES=(mysql redis kafka nebulagraph nebulagraph-cluster doris elasticsearch jdk)

# 解析配置文件
parse_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    warn "配置文件不存在: $CONFIG_FILE，使用默认配置"
    return
  fi

  local current_section=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    # 跳过空行和注释
    [[ -z "${line// }" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # section [service]
    if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
      current_section="${BASH_REMATCH[1]}"
      continue
    fi

    # key = value
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      # 去除行尾注释
      value="${value%%#*}"
      value="$(echo -n "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

      if [[ -n "$current_section" ]]; then
        case "$key" in
          enabled) CFG_ENABLED["$current_section"]="$value" ;;
          deploy_mode) CFG_MODE["$current_section"]="$value" ;;
        esac
      fi
    fi
  done < "$CONFIG_FILE"
}

declare -A CFG_ENABLED=()
declare -A CFG_MODE=()

# 获取服务部署模式
get_mode() {
  local svc="$1"
  local mode="${CFG_MODE[$svc]:-docker-compose}"
  echo "$mode"
}

# 获取服务是否启用
is_enabled() {
  local svc="$1"
  local enabled="${CFG_ENABLED[$svc]:-true}"
  [[ "$enabled" == "true" ]]
}

# ---- 状态显示 ----
show_status() {
  log "数据库服务容器状态:"
  docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" \
    | grep -iE "mysql|redis|kafka|elasticsearch|doris|nebula|^NAMES" || true
}

# ---- 参数解析 ----
MODE="all"          # all | start | status | binary | docker
SELECTED_MODE=""    # 用户强制指定的 deploy_mode
USER_SERVICES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-only) MODE="start" ;;
    --status)     MODE="status" ;;
    --binary)     MODE="binary" ;;
    --docker)     MODE="docker" ;;
    --help|-h)    MODE="help" ;;
    --mode)
      shift
      SELECTED_MODE="${1:-}"
      [[ "$SELECTED_MODE" == "docker-compose" || "$SELECTED_MODE" == "binary" ]] || fatal "--mode 参数必须是 docker-compose 或 binary"
      ;;
    all|mysql|redis|kafka|nebulagraph|nebulagraph-cluster|doris|elasticsearch)
      USER_SERVICES+=("$1")
      ;;
    *)
      fatal "未知参数: $1 (可用服务: mysql/redis/kafka/nebulagraph/nebulagraph-cluster/doris/elasticsearch, 选项: --start-only/--status/--binary/--docker/--mode)"
      ;;
  esac
  shift
done

if [[ "$MODE" == "help" ]]; then
  cat <<EOF
用法: $(basename "$0") [选项] [服务名...]

配置文件: config/database-package.conf
  enabled=true/false      是否默认部署
  deploy_mode=binary/docker-compose  部署方式

选项:
  (无参数)      按配置文件部署所有启用服务
  --docker      仅部署 docker-compose 方式的服务
  --binary      仅安装二进制包（Doris/ES/JDK）
  --start-only  仅启动服务（不加载镜像）
  --status      查看运行状态
  --mode        强制指定本次部署方式: docker-compose 或 binary

服务名(可多个):
  mysql redis kafka nebulagraph nebulagraph-cluster doris elasticsearch

示例:
  $(basename "$0") mysql redis                    # 仅部署 MySQL + Redis
  $(basename "$0") --mode binary doris            # 用二进制方式安装 Doris
  $(basename "$0") --binary                       # 安装所有二进制包
  $(basename "$0") --docker                       # 部署所有 docker-compose 服务
  $(basename "$0") --start-only                   # 启动所有已启用服务
EOF
  exit 0
fi

# status 模式直接退出
if [[ "$MODE" == "status" ]]; then
  show_status
  exit 0
fi

# 解析配置
parse_config

# 确定要部署的服务列表
DEPLOY_SERVICES=()
if [[ ${#USER_SERVICES[@]} -gt 0 ]]; then
  DEPLOY_SERVICES=("${USER_SERVICES[@]}")
else
  for svc in "${ALL_SERVICES[@]}"; do
    is_enabled "$svc" && DEPLOY_SERVICES+=("$svc")
  done
fi

# 过滤 deploy_mode
DOCKER_SERVICES=()
BINARY_SERVICES=()
for svc in "${DEPLOY_SERVICES[@]}"; do
  svc_mode="$(get_mode "$svc")"
  # 用户强制 --mode 优先
  [[ -n "$SELECTED_MODE" ]] && svc_mode="$SELECTED_MODE"

  case "$svc" in
    jdk)
      # JDK 只能作为 binary 依赖安装
      if [[ "$svc_mode" != "binary" ]]; then
        warn "JDK 仅支持 binary 部署，强制使用 binary 模式"
      fi
      BINARY_SERVICES+=("$svc")
      ;;
    doris|elasticsearch)
      # 这些服务支持 binary，但也允许 docker-compose
      if [[ "$svc_mode" == "binary" ]]; then
        BINARY_SERVICES+=("$svc")
      else
        DOCKER_SERVICES+=("$svc")
      fi
      ;;
    mysql|redis|kafka|nebulagraph|nebulagraph-cluster)
      # 这些服务只支持 docker-compose
      if [[ "$svc_mode" == "binary" ]]; then
        warn "$svc 不支持 binary 部署，将使用 docker-compose"
      fi
      DOCKER_SERVICES+=("$svc")
      ;;
  esac
done

# 根据模式过滤
if [[ "$MODE" == "binary" ]]; then
  DOCKER_SERVICES=()
elif [[ "$MODE" == "docker" ]]; then
  BINARY_SERVICES=()
fi

# 去重
DOCKER_SERVICES=($(printf '%s\n' "${DOCKER_SERVICES[@]}" | sort -u))
BINARY_SERVICES=($(printf '%s\n' "${BINARY_SERVICES[@]}" | sort -u))

log "本次部署计划:"
if [[ ${#DOCKER_SERVICES[@]} -gt 0 ]]; then
  log "  docker-compose: ${DOCKER_SERVICES[*]}"
fi
if [[ ${#BINARY_SERVICES[@]} -gt 0 ]]; then
  log "  binary: ${BINARY_SERVICES[*]}"
fi
if [[ ${#DOCKER_SERVICES[@]} -eq 0 && ${#BINARY_SERVICES[@]} -eq 0 ]]; then
  log "  没有需要部署的服务"
  exit 0
fi

# ---- 加载镜像 ----
if [[ "$MODE" != "binary" && "$MODE" != "start" && ${#DOCKER_SERVICES[@]} -gt 0 ]]; then
  command -v docker >/dev/null 2>&1 || fatal "未安装 docker，请先安装 offline-docker 包"
  detect_compose || ensure_compose
  log "使用 compose 命令: ${COMPOSE_CMD[*]}"

  log "校验并加载数据库镜像..."
  bash "$ROOT_DIR/scripts/load_database_images.sh"
fi

# ---- 二进制安装 ----
if [[ ${#BINARY_SERVICES[@]} -gt 0 ]]; then
  log "安装二进制包: ${BINARY_SERVICES[*]}"
  bash "$ROOT_DIR/scripts/install_third_party_binaries.sh"
fi

# ---- docker-compose 部署 ----
if [[ ${#DOCKER_SERVICES[@]} -gt 0 ]]; then
  command -v docker >/dev/null 2>&1 || fatal "未安装 docker，请先安装 offline-docker 包"
  detect_compose || ensure_compose
  log "使用 compose 命令: ${COMPOSE_CMD[*]}"

  log "启动 compose 服务: ${DOCKER_SERVICES[*]}"
  for svc in "${DOCKER_SERVICES[@]}"; do
    compose_file="$ROOT_DIR/compose/$svc/docker-compose.yml"
    if [[ ! -f "$compose_file" ]]; then
      warn "缺少 compose 文件，跳过 $svc: $compose_file"
      continue
    fi

    deploy_dir="${DATA_DIRS[$svc]:-/data/$svc}"
    mkdir -p "$deploy_dir"

    # 复制 compose 文件到部署根目录
    /bin/cp "$compose_file" "$deploy_dir/docker-compose.yml"
    log "  -> 复制 compose 到 $deploy_dir/docker-compose.yml"

    # 复制额外配置文件
    if [[ "$svc" == "elasticsearch" ]]; then
      mkdir -p "$deploy_dir/config"
      [[ -f "$ROOT_DIR/compose/$svc/elasticsearch.yml" ]] && /bin/cp "$ROOT_DIR/compose/$svc/elasticsearch.yml" "$deploy_dir/config/elasticsearch.yml"
    fi

    # 复制 .env.example
    [[ -f "$ROOT_DIR/compose/$svc/.env.example" ]] && /bin/cp "$ROOT_DIR/compose/$svc/.env.example" "$deploy_dir/.env.example"

    # nebulagraph-cluster 特殊处理：需要环境变量
    if [[ "$svc" == "nebulagraph-cluster" ]]; then
      if [[ -z "${LOCAL_IP:-}" || -z "${METAD_ADDRS:-}" ]]; then
        warn "nebulagraph-cluster 需要环境变量 LOCAL_IP 和 METAD_ADDRS"
        warn "已复制 compose 到 $deploy_dir/，请修改 .env 后手动启动"
        continue
      fi
      cat > "$deploy_dir/.env" <<EOF
LOCAL_IP=${LOCAL_IP}
METAD_ADDRS=${METAD_ADDRS}
EOF
    fi

    log "  -> ${COMPOSE_CMD[*]} up -d [$svc]"
    (cd "$deploy_dir" && "${COMPOSE_CMD[@]}" up -d)
  done

  # 第三方占位脚本（Nebula 相关）
  if [[ " ${DOCKER_SERVICES[*]} " =~ " nebulagraph " || " ${DOCKER_SERVICES[*]} " =~ " nebulagraph-cluster " ]]; then
    if [[ -x "$ROOT_DIR/scripts/install_nebula_third_party.sh" ]]; then
      log "部署 NebulaGraph 第三方占位组件..."
      bash "$ROOT_DIR/scripts/install_nebula_third_party.sh" || warn "Nebula 第三方组件部署有警告"
    fi
  fi
fi

# ---- 状态汇总 ----
if [[ ${#DOCKER_SERVICES[@]} -gt 0 ]]; then
  log "等待服务就绪(15s)..."
  sleep 15
  echo ""
  show_status
  echo ""
  log "完成。可用以下命令验证:"
  log "  mysql    : docker exec -it mysql84 mysql -uroot -p"
  log "  redis    : docker exec -it redis redis-cli -a ChangeMe_123456 ping"
  log "  kafka    : docker exec -it kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list"
  log "  kafka-ui : http://<host>:9090"
  log "  nebula   : docker run --rm --network container:nebula-graphd vesoft/nebula-console:v3.8.0 -addr 127.0.0.1 -port 9669 -u root -p nebula"
  log "  es       : curl http://<host>:9200"
  log "  doris    : mysql -h<host> -P9030 -uroot"
fi

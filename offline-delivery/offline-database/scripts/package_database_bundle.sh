#!/usr/bin/env bash
# package_database_bundle.sh - 导出独立数据库/中间件离线包
# 根据 config/database-package.conf 控制打包内容：
#   - enabled=false 的服务：不打包
#   - deploy_mode=docker-compose：打包 compose，不打包二进制包
#   - deploy_mode=binary：打包 third-party 二进制包，不打包 compose

set -euo pipefail
ROOT_DIR="${ROOT_DIR:-/opt/install/offline-database}"

# 读取全局架构配置
for _p in "$ROOT_DIR/../arch.env" "$ROOT_DIR/arch.env" "$ROOT_DIR/config/arch.env"; do
  if [[ -f "$_p" ]]; then source "$_p"; break; fi
done
ARCH="${ARCH:-arm64}"
case "$ARCH" in
  arm64) PKG_ARCH="aarch64"; ARCH_LABEL="ARM64/aarch64" ;;
  amd64) PKG_ARCH="x86_64"; ARCH_LABEL="AMD64/x86_64" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

TS=$(date +%Y%m%d%H%M%S)
PKG_NAME="offline-database-${PKG_ARCH}"
GLOBAL_BUNDLE_ROOT="$ROOT_DIR/../bundle"
BUNDLE_DIR="$GLOBAL_BUNDLE_ROOT/$ARCH/database"
OUT_DIR="$BUNDLE_DIR/$PKG_NAME"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }

# ---- 读取部署配置 ----
CONFIG_FILE="$ROOT_DIR/config/database-package.conf"
declare -A CFG_ENABLED=()
declare -A CFG_MODE=()

parse_config() {
  [[ ! -f "$CONFIG_FILE" ]] && return
  local current_section=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line// }" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
      current_section="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
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

is_enabled() {
  local svc="$1"
  local enabled="${CFG_ENABLED[$svc]:-true}"
  [[ "$enabled" == "true" ]]
}

get_mode() {
  local svc="$1"
  echo "${CFG_MODE[$svc]:-docker-compose}"
}

parse_config

# ---- 清理旧包 ----
rm -rf "$OUT_DIR" \
       "$BUNDLE_DIR"/${PKG_NAME}-*.tar.gz \
       "$BUNDLE_DIR"/${PKG_NAME}-*.tar.gz.sha256
mkdir -p "$BUNDLE_DIR" "$OUT_DIR"/{images,compose,scripts,third-party,config}

# 清理孤儿 .sha256: 上一次异常中断可能留下没有对应 tar.gz 的 .sha256 文件
for sha in "$BUNDLE_DIR"/${PKG_NAME}-*.tar.gz.sha256; do
  [[ -f "$sha" ]] || continue
  tar="${sha%.sha256}"
  if [[ ! -f "$tar" ]]; then
    warn "清理孤儿 .sha256: $(basename "$sha")"
    rm -f "$sha"
  fi
done

# ---- 复制基础文件 ----
# scripts
if [[ -d "$ROOT_DIR/scripts" ]] && [[ -n "$(ls -A "$ROOT_DIR/scripts" 2>/dev/null)" ]]; then
  cp -a "$ROOT_DIR/scripts/"* "$OUT_DIR/scripts/"
  log "  [OK] scripts/"
fi

# config (arch.env + database-package.conf)
if [[ -f "$ROOT_DIR/../arch.env" ]]; then
  cp "$ROOT_DIR/../arch.env" "$OUT_DIR/arch.env"
fi
if [[ -f "$ROOT_DIR/config/database-package.conf" ]]; then
  cp "$ROOT_DIR/config/database-package.conf" "$OUT_DIR/config/database-package.conf"
  log "  [OK] config/database-package.conf"
fi

# ---- 按配置复制 compose 和 third-party ----
# 服务与目录名映射（含仅支持 binary 的 JDK）
declare -A SERVICE_DIR_MAP=(
  [mysql]="mysql"
  [redis]="redis"
  [kafka]="kafka"
  [nebulagraph]="nebulagraph"
  [nebulagraph-cluster]="nebulagraph-cluster"
  [doris]="doris"
  [elasticsearch]="elasticsearch"
  [jdk]=""
)
# 服务与 third-party 子目录映射（多个服务可能共用一个 third-party 目录）
declare -A SERVICE_TP_MAP=(
  [doris]="doris"
  [elasticsearch]="elasticsearch"
  [jdk]="jdk"
)

declare -A tp_dirs_to_copy=()

for svc in "${!SERVICE_DIR_MAP[@]}"; do
  is_enabled "$svc" || continue

  mode="$(get_mode "$svc")"
  dir_name="${SERVICE_DIR_MAP[$svc]}"

  if [[ "$mode" == "docker-compose" ]]; then
    if [[ -z "$dir_name" ]]; then
      warn "$svc 不支持 docker-compose 部署，跳过"
      continue
    fi
    compose_enabled=true
    src="$ROOT_DIR/compose/$dir_name"
    dst="$OUT_DIR/compose/$dir_name"
    if [[ -d "$src" ]]; then
      mkdir -p "$dst"
      cp -a "$src/"* "$dst/"
      # 过滤可能存在的二进制包（原则上 compose 目录不应放二进制包，但以防万一）
      find "$dst" -maxdepth 2 -type f \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar' -o -name '*.tar.xz' \) -delete
      log "  [OK] compose/$dir_name/ (docker-compose)"
    else
      warn "compose 目录不存在: $src"
    fi
  elif [[ "$mode" == "binary" ]]; then
    tp_enabled=true
    tp_dir="${SERVICE_TP_MAP[$svc]:-}"
    [[ -n "$tp_dir" ]] && tp_dirs_to_copy["$tp_dir"]=1
  fi
done

# 复制需要的 third-party 目录
if [[ -d "$ROOT_DIR/third-party" ]]; then
  for tp_dir in "${!tp_dirs_to_copy[@]}"; do
    src="$ROOT_DIR/third-party/$tp_dir"
    dst="$OUT_DIR/third-party/$tp_dir"
    if [[ -d "$src" ]]; then
      mkdir -p "$dst"
      cp -a "$src/"* "$dst/"
      log "  [OK] third-party/$tp_dir/ (binary)"
    fi
  done
fi

# 对 deploy_mode=docker-compose 的服务，即使 third-party 有对应目录也不打包二进制包
for svc in "${!SERVICE_DIR_MAP[@]}"; do
  is_enabled "$svc" || continue
  mode="$(get_mode "$svc")"
  if [[ "$mode" == "docker-compose" ]]; then
    tp_dir="${SERVICE_TP_MAP[$svc]:-}"
    [[ -n "$tp_dir" ]] || continue
    dst="$OUT_DIR/third-party/$tp_dir"
    if [[ -d "$dst" ]]; then
      # 删除二进制包，保留 README、service 文件等
      find "$dst" -maxdepth 2 -type f \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar' -o -name '*.tar.xz' \) -delete
      # 如果目录变空则删除
      if [[ -z "$(ls -A "$dst" 2>/dev/null)" ]]; then
        rm -rf "$dst"
      else
        log "  [OK] third-party/$tp_dir/ (文档/占位，已过滤二进制包)"
      fi
    fi
  fi
done

# ---- 复制镜像 ----
src="$ROOT_DIR/images/${ARCH}"
dst="$OUT_DIR/images/${ARCH}"
if [[ -d "$src" ]] && [[ -n "$(ls -A "$src" 2>/dev/null)" ]]; then
  mkdir -p "$OUT_DIR/images"
  cp -a "$src" "$dst/"
  log "  [OK] images/${ARCH}/"
else
  log "  [EMPTY] images/${ARCH}/"
fi

chmod +x "$OUT_DIR"/scripts/*.sh 2>/dev/null || true

# 确保 .env.example 被复制
for svc_dir in "$OUT_DIR"/compose/*/; do
  svc=$(basename "$svc_dir")
  src_env="$ROOT_DIR/compose/$svc/.env.example"
  if [[ -f "$src_env" ]] && [[ ! -f "$svc_dir/.env.example" ]]; then
    cp "$src_env" "$svc_dir/.env.example"
    log "  [OK] compose/$svc/.env.example"
  fi
done

# ---- 验证关键文件 ----
if [[ ! -d "$OUT_DIR/images/${ARCH}" ]] || [[ -z "$(ls "$OUT_DIR/images/${ARCH}"/*.tar 2>/dev/null)" ]]; then
  warn "镜像目录为空或不存在，请先执行 scripts/download_database_images.sh"
fi
if [[ ! -d "$OUT_DIR/compose" ]]; then
  fatal "缺少 compose 目录"
fi

# ---- 创建版本信息 ----
cat > "$OUT_DIR/VERSION.txt" <<EOF
Offline Database/Middleware Package
===================================
构建时间: $(date '+%F %T')
架构: ${ARCH_LABEL}

部署配置: config/database-package.conf
  enabled=false   -> 打包和部署时均忽略
  deploy_mode=docker-compose -> 打包 compose，不打包二进制包
  deploy_mode=binary         -> 打包 third-party 二进制包，不打包 compose

内容（按当前配置）:
- MySQL: 8.4 (端口 3306, 数据 /data/mysql)
- Redis: 8.8 (端口 6379, 数据 /data/redis)
- Kafka: 4.0.2 (端口 9092, KRaft 模式, 数据 /data/kafka)
- Kafka UI: latest (端口 9090)
- NebulaGraph: 3.8.0 (单机/集群, 端口 9669)
- Doris: 2.1.11 (支持 docker-compose 或 binary 安装)
- Elasticsearch: 7.17.29 (支持 docker-compose 或 binary 安装)
- JDK: 8u491 / 17.0.19 (binary 安装，Doris/ES 依赖)

使用方法:
---------
1. 先安装 Docker 离线包 (offline-docker)
2. ./scripts/load_database_images.sh  # 导入镜像
3. ./scripts/install_db.sh [选项] [服务...]  # 按配置文件或指定服务部署
4. 集群版 NebulaGraph 需手动执行:
   docker exec -it nebula-graphd nebula -addr=127.0.0.1 -port=9669 -u root -p nebula -e 'ADD HOSTS "<storaged_ip>:9779"'
EOF

log "VERSION.txt 已创建"

# ---- 生成校验文件 ----
(cd "$OUT_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum > sha256sum.txt)
log "sha256sum.txt 已生成"

# ---- 打包 ----
log "创建归档..."
(cd "$BUNDLE_DIR" && tar -czf "${PKG_NAME}-${TS}.tar.gz" "$PKG_NAME")
sha256sum "$BUNDLE_DIR/${PKG_NAME}-${TS}.tar.gz" > "$BUNDLE_DIR/${PKG_NAME}-${TS}.tar.gz.sha256"

# ---- 清理 staging ----
rm -rf "$OUT_DIR"

log "完成: $BUNDLE_DIR/${PKG_NAME}-${TS}.tar.gz ($(du -h "$BUNDLE_DIR/${PKG_NAME}-${TS}.tar.gz" | cut -f1))"

#!/usr/bin/env bash
# pack_dify.sh - 在线机器执行：解析 dify 项目 docker-compose 中所有 image 字段，
#                 按架构拉取、导出、打包为离线包
#
# 设计原则:
#   - 不修改 dify 项目的任何文件 (包括 docker-compose.yaml)
#   - 通过 Python 解析 docker-compose.yaml 提取所有 image 字段
#   - 支持多架构 (linux/arm64 / linux/amd64)
#   - 镜像导出 docker-archive 格式，保留完整 RepoTags
#   - 自动过滤掉 build: 指令定义的本地构建镜像 (离线环境无源码)
#
# 用法:
#   ./pack_dify.sh                            # 默认参数 (core 模式)
#   DIFY_DIR=/path/to/dify ./pack_dify.sh     # 指定 dify 项目目录
#   FORCE_PULL=1 ./pack_dify.sh               # 强制重新拉取
#   VECTOR_STORE=qdrant ./pack_dify.sh        # 选择其他向量库 (weaviate|qdrant|...)
#   PROFILE=core ./pack_dify.sh               # core: 默认 (核心 12 个镜像)
#   PROFILE=full ./pack_dify.sh               # full: 全部 34 个镜像
#   CONF_FILE=/path/to/extra.conf ./pack_dify.sh   # 添加额外镜像
#
# 产出: bundle/${ARCH}/dify/offline-dify-${PKG_ARCH}-${TS}.tar.gz
#       包内: images/*.tar + images/images.list + images/sha256sum.txt
#             + scripts/load_dify.sh + scripts/install_dify.sh
#             + VERSION.txt

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 读取全局架构配置
for _p in "$ROOT_DIR/../arch.env" "$ROOT_DIR/arch.env"; do
  if [[ -f "$_p" ]]; then source "$_p"; break; fi
done
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64|aarch64) ARCH=arm64; OCI_PLATFORM="linux/arm64"; PKG_ARCH="aarch64" ;;
  amd64|x86_64)  ARCH=amd64; OCI_PLATFORM="linux/amd64"; PKG_ARCH="x86_64"  ;;
  *) echo "不支持的架构: $ARCH (可选: arm64, amd64)"; exit 1 ;;
esac

# 参数
DIFY_DIR="${DIFY_DIR:-$ROOT_DIR/../dify}"
COMPOSE_FILE="${COMPOSE_FILE:-$DIFY_DIR/docker/docker-compose.yaml}"
MIDDLEWARE_FILE="${MIDDLEWARE_FILE:-$DIFY_DIR/docker/docker-compose.middleware.yaml}"
CONF_FILE="${CONF_FILE:-$ROOT_DIR/extra-images.conf}"  # 可选: 用户自定义额外镜像
PROFILE="${PROFILE:-core}"  # core: 12 个核心镜像, full: 全部
VECTOR_STORE="${VECTOR_STORE:-weaviate}"
MAX_RETRIES=3
TS=$(date +%Y%m%d%H%M%S)

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }

command -v docker >/dev/null 2>&1 || fatal "缺少 docker 命令"
command -v python3 >/dev/null 2>&1 || fatal "缺少 python3 (解析 yaml 需要)"

IMAGES_DIR="$ROOT_DIR/images"
GLOBAL_BUNDLE_ROOT="$ROOT_DIR/../bundle"
BUNDLE_DIR="$GLOBAL_BUNDLE_ROOT/$ARCH/dify"
SCRIPTS_DIR="$ROOT_DIR/scripts"

[[ -f "$COMPOSE_FILE" ]] || fatal "缺少 dify compose 文件: $COMPOSE_FILE"

mkdir -p "$IMAGES_DIR" "$BUNDLE_DIR" "$SCRIPTS_DIR"

# 清理该架构下该包的历史 bundle
rm -rf "$BUNDLE_DIR"/offline-dify-${PKG_ARCH} \
       "$BUNDLE_DIR"/offline-dify-${PKG_ARCH}-*.tar.gz \
       "$BUNDLE_DIR"/offline-dify-${PKG_ARCH}-*.tar.gz.sha256

# 清理孤儿 .sha256
for sha in "$BUNDLE_DIR"/offline-dify-${PKG_ARCH}-*.tar.gz.sha256; do
  [[ -f "$sha" ]] || continue
  tar="${sha%.sha256}"
  if [[ ! -f "$tar" ]]; then
    warn "清理孤儿 .sha256: $(basename "$sha")"
    rm -f "$sha"
  fi
done

# ─── 解析 docker-compose 提取 image 列表 ───
log "========================================"
log "Dify 离线镜像打包"
log "========================================"
log "架构: ${ARCH} (${OCI_PLATFORM})"
log "Dify 项目: $DIFY_DIR"
log "主 compose: $COMPOSE_FILE"
[[ -f "$MIDDLEWARE_FILE" ]] && log "中间件 compose: $MIDDLEWARE_FILE"
[[ -f "$CONF_FILE" ]] && log "额外镜像清单: $CONF_FILE"
log "========================================"

log "解析 docker-compose.yaml 提取镜像列表..."

# 使用 Python 解析 yaml; 处理 profile (只取非空 profile 或默认的)
# 跳过 build: 指令的本地构建服务
EXTRACT_SCRIPT='
import sys, yaml, re

def extract_images(yml_path):
    with open(yml_path) as f:
        data = yaml.safe_load(f)
    services = (data or {}).get("services", {}) or {}
    images = set()
    build_services = set()
    for name, cfg in services.items():
        if not isinstance(cfg, dict):
            continue
        # 跳过有 build: 的服务 (本地构建, 离线环境无源码)
        if "build" in cfg:
            build_services.add(name)
            continue
        img = cfg.get("image")
        if img and isinstance(img, str) and not img.startswith("${"):
            images.add(img.strip())
    return images, build_services

all_images = set()
all_builds = set()
for f in sys.argv[1:]:
    try:
        imgs, builds = extract_images(f)
        all_images |= imgs
        all_builds |= builds
    except Exception as e:
        print(f"ERROR parsing {f}: {e}", file=sys.stderr)
        sys.exit(1)

# 解析 ${VAR:-default} 形式的镜像引用 (compose 里变量替换)
# 例如 ${NGINX_IMAGE:-nginx:latest} -> nginx:latest
def resolve_var(m):
    var, default = m.group(1), m.group(2)
    return default if default else var

resolved = set()
for img in all_images:
    m = re.match(r"^\$\{([A-Z_]+)(?::?-(.*))?\}$", img)
    if m:
        resolved.add(resolve_var(m))
    else:
        resolved.add(img)

# 展开 ${VAR} 引用
# 简单的 ${VAR} 不带默认值, 这里取变量名作为前缀提醒
for img in all_images:
    if "${" in img and not re.match(r"^\$\{[A-Z_]+(?::?-[^}]+)?\}$", img):
        print(f"WARN: image 字段含未解析的变量: {img}", file=sys.stderr)

print("# FROM_DOCKER_COMPOSE", file=sys.stderr)
for s in sorted(all_builds):
    print(f"# 跳过本地构建服务: {s}", file=sys.stderr)

for img in sorted(resolved):
    print(img)
'

mapfile -t COMPOSE_IMAGES < <(python3 -c "$EXTRACT_SCRIPT" "$COMPOSE_FILE" "$MIDDLEWARE_FILE" 2>&1 | grep -v "^#" | grep -v "FROM_DOCKER_COMPOSE")
mapfile -t COMPOSE_WARNINGS < <(python3 -c "$EXTRACT_SCRIPT" "$COMPOSE_FILE" "$MIDDLEWARE_FILE" 2>/dev/null | grep "^# 跳过")

# 输出 warnings
for w in "${COMPOSE_WARNINGS[@]:-}"; do
  [[ -n "$w" ]] && warn "$w"
done

# 合并额外镜像清单
EXTRA_IMAGES=()
if [[ -f "$CONF_FILE" ]]; then
  log "读取额外镜像清单: $CONF_FILE"
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/#.*//' | tr -d '[:space:]')
    [[ -z "$line" ]] && continue
    EXTRA_IMAGES+=("$line")
  done < "$CONF_FILE"
fi

# 合并去重
ALL_IMAGES=("${COMPOSE_IMAGES[@]:-}" "${EXTRA_IMAGES[@]}")
if [[ ${#ALL_IMAGES[@]} -eq 0 ]]; then
  fatal "未解析到任何镜像"
fi

# 合并去重
printf '%s\n' "${ALL_IMAGES[@]}" | sort -u > /tmp/dify_images_$$.txt
mapfile -t ALL_IMAGES < /tmp/dify_images_$$.txt
rm -f /tmp/dify_images_$$.txt

# ─── PROFILE 过滤 ───
# core 模式: 只保留核心服务 (Dify 必需 + 中间件)
# full 模式: 保留全部从 compose 解析的镜像
if [[ "$PROFILE" == "core" ]]; then
  log "PROFILE=core: 应用核心镜像过滤"
  declare -a KEEP_PATTERNS=(
    "langgenius/dify-api:"
    "langgenius/dify-web:"
    "langgenius/dify-sandbox:"
    "langgenius/dify-plugin-daemon:"
    "langgenius/dify-agent-backend:"
    "langgenius/dify-agent-local-sandbox:"
    "postgres:15-alpine"
    "redis:6-alpine"
    "semitechnologies/weaviate:"  # 默认向量库
    "ubuntu/squid:"                # SSRF proxy
    "nginx:latest"                 # 反向代理
    "certbot/certbot"              # SSL
  )
  declare -a FILTERED=()
  for img in "${ALL_IMAGES[@]}"; do
    for pat in "${KEEP_PATTERNS[@]}"; do
      if [[ "$img" == *"$pat"* ]]; then
        FILTERED+=("$img")
        break
      fi
    done
  done
  if [[ ${#FILTERED[@]} -gt 0 ]]; then
    ALL_IMAGES=("${FILTERED[@]}")
    log "  过滤后: ${#ALL_IMAGES[@]} 个核心镜像"
  fi
elif [[ "$PROFILE" == "full" ]]; then
  log "PROFILE=full: 保留全部 ${#ALL_IMAGES[@]} 个镜像"
else
  fatal "未知 PROFILE: $PROFILE (可选: core, full)"
fi

# 如果指定了其他向量库, 追加
case "$VECTOR_STORE" in
  weaviate) ;;  # 已在 core 中
  qdrant)    ALL_IMAGES+=("langgenius/qdrant:v1.8.3") ;;
  milvus)    ALL_IMAGES+=("milvusdb/milvus:v2.6.3" "quay.io/coreos/etcd:v3.5.5" "minio/minio:RELEASE.2023-03-20T20-16-18Z") ;;
  chroma)    ALL_IMAGES+=("ghcr.io/chroma-core/chroma:0.5.20") ;;
  pgvector)  ALL_IMAGES+=("pgvector/pgvector:pg16") ;;
  opensearch) ALL_IMAGES+=("opensearchproject/opensearch:latest" "opensearchproject/opensearch-dashboards:latest") ;;
  oceanbase) ALL_IMAGES+=("oceanbase/oceanbase-ce:4.3.5-lts") ;;
  *) warn "未知 VECTOR_STORE: $VECTOR_STORE, 不追加镜像" ;;
esac

# 再次去重
printf '%s\n' "${ALL_IMAGES[@]}" | sort -u > /tmp/dify_images_$$.txt
mapfile -t ALL_IMAGES < /tmp/dify_images_$$.txt
rm -f /tmp/dify_images_$$.txt

log "最终镜像列表 (${#ALL_IMAGES[@]} 个):"
for img in "${ALL_IMAGES[@]}"; do
  log "  - $img"
done

# ─── 拉取并导出 ───
log "========================================"
log "开始拉取并导出镜像"
log "========================================"

safe_name() { echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

# 检查 tar 内的 RepoTag 是否与预期镜像一致 (用于断点续传跳过判断)
tar_repotag() {
  local tar="$1"
  python3 -c "
import tarfile, json, sys
try:
    with tarfile.open('$tar') as t:
        m = json.load(t.extractfile('manifest.json'))
        print(m[0]['RepoTags'][0] if m and m[0].get('RepoTags') else '')
except Exception:
    sys.exit(1)
" 2>/dev/null
}

pulled=0 skipped=0 failed=0
declare -a FAILED_IMAGES=()

for image in "${ALL_IMAGES[@]}"; do
  safe=$(safe_name "$image")
  out="$IMAGES_DIR/${safe}.tar"

  # 已存在且 RepoTag 匹配则跳过 (除非 FORCE_PULL=1)
  if [[ "${FORCE_PULL:-0}" != "1" ]] && [[ -f "$out" ]] && [[ -s "$out" ]]; then
    if [[ "$(tar_repotag "$out")" == "$image" ]]; then
      log "[SKIP] $image (已存在: ${safe}.tar)"
      skipped=$((skipped + 1))
      continue
    fi
    warn "已存在但 RepoTag 不匹配，重新拉取: $image"
    rm -f "$out"
  fi

  # 拉取镜像 (带重试)
  log "[PULL] $image"
  pull_ok=false
  for attempt in $(seq 1 "$MAX_RETRIES"); do
    if docker pull --platform "$OCI_PLATFORM" "$image" 2>&1 | tail -3; then
      pull_ok=true
      break
    fi
    if [[ $attempt -lt $MAX_RETRIES ]]; then
      warn "拉取失败 (${attempt}/${MAX_RETRIES})，10 秒后重试: $image"
      sleep 10
    fi
  done

  if [[ "$pull_ok" != "true" ]]; then
    warn "[FAIL] 拉取失败 (已重试 ${MAX_RETRIES} 次): $image"
    failed=$((failed + 1))
    FAILED_IMAGES+=("$image")
    continue
  fi

  # 导出镜像 (保留完整 RepoTags)
  log "[SAVE] $image -> ${safe}.tar"
  if docker save -o "$out" "$image" 2>/dev/null && [[ -s "$out" ]]; then
    log "  [OK] $(du -h "$out" | cut -f1)"
    pulled=$((pulled + 1))
  else
    warn "[FAIL] 导出失败: $image"
    failed=$((failed + 1))
    FAILED_IMAGES+=("$image")
    rm -f "$out"
  fi
done

# ─── 生成校验文件与镜像清单 ───
log "生成 sha256sum.txt 与 images.list"
( cd "$IMAGES_DIR" && sha256sum *.tar > sha256sum.txt 2>/dev/null )
: > "$IMAGES_DIR/images.list"
for image in "${ALL_IMAGES[@]}"; do
  echo "$image" >> "$IMAGES_DIR/images.list"
done

echo ""
log "========================================"
log "下载完成汇总"
log "========================================"
log "  成功拉取: $pulled"
log "  跳过(已存在): $skipped"
log "  失败: $failed"
log "  镜像目录: $IMAGES_DIR"
log "  总大小: $(du -sh "$IMAGES_DIR" | cut -f1)"
if [[ "$failed" -gt 0 ]]; then
  warn "失败镜像:"
  for img in "${FAILED_IMAGES[@]}"; do warn "  - $img"; done
fi
log "========================================"

if [[ "$pulled" -eq 0 ]] && [[ "$skipped" -eq 0 ]]; then
  fatal "没有任何镜像被成功处理，终止打包"
fi

# ─── 组装离线包 staging 目录 ───
STAGING_NAME="offline-dify-${PKG_ARCH}"
STAGING_DIR="$BUNDLE_DIR/$STAGING_NAME"
log "组装离线包: $STAGING_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/images" "$STAGING_DIR/scripts"

# 仅复制成功导出的 tar
copied=0
while IFS= read -r image; do
  [[ -z "$image" ]] && continue
  safe=$(safe_name "$image")
  src="$IMAGES_DIR/${safe}.tar"
  if [[ -f "$src" ]] && [[ -s "$src" ]]; then
    cp -a "$src" "$STAGING_DIR/images/"
    copied=$((copied + 1))
  fi
done < "$IMAGES_DIR/images.list"

# 重新生成包内 sha256sum.txt
( cd "$STAGING_DIR/images" && sha256sum *.tar > sha256sum.txt )
cp "$IMAGES_DIR/images.list" "$STAGING_DIR/images/images.list"

# 复制 load 脚本和 install 脚本
cp "$SCRIPTS_DIR/load_dify.sh" "$STAGING_DIR/scripts/load_dify.sh"
cp "$SCRIPTS_DIR/install_dify.sh" "$STAGING_DIR/scripts/install_dify.sh"
chmod +x "$STAGING_DIR/scripts/"*.sh

# VERSION.txt
cat > "$STAGING_DIR/VERSION.txt" <<EOF
Dify 1.16.0-rc1 离线部署包
====================
构建时间: $(date '+%F %T')
架构: ${ARCH} (${PKG_ARCH})
镜像数量: ${copied}
来源: Dify 项目 docker-compose.yaml (${COMPOSE_FILE})
中间件 compose: ${MIDDLEWARE_FILE}

内容:
  images/*.tar           各镜像 tar 包 (docker-archive 格式，保留完整 registry 地址)
  images/images.list     镜像完整引用清单
  images/sha256sum.txt   tar 文件 sha256 校验
  scripts/load_dify.sh   离线导入脚本
  scripts/install_dify.sh 一键部署脚本

离线环境使用:
  1. 解压: tar -xzf ${STAGING_NAME}-*.tar.gz
  2. 导入镜像: cd ${STAGING_NAME} && bash scripts/load_dify.sh
  3. 部署: bash scripts/install_dify.sh
     (需要 dify 项目源码在 DIFY_DIR, 默认: /opt/install/dify)

注意:
  - 需要 Docker 和 Docker Compose 已安装
  - load_dify.sh 使用 docker load 导入镜像
  - install_dify.sh 直接用 dify 项目的 docker-compose.yaml 启动
  - 中间件数据持久化到 volumes/ 目录
EOF

# 全量 sha256
( cd "$STAGING_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum > sha256sum.txt )

# ─── 打包归档 ───
GZIP_CMD="gzip"
if command -v pigz >/dev/null 2>&1; then
  GZIP_CMD="pigz"
  log "检测到 pigz，启用并行压缩"
fi

ARCHIVE="$BUNDLE_DIR/${STAGING_NAME}-${TS}.tar.gz"
log "创建归档 (使用 $GZIP_CMD): $(basename "$ARCHIVE")"
( cd "$BUNDLE_DIR" && tar -cf - "$STAGING_NAME" | $GZIP_CMD -c > "$ARCHIVE" )
sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"

# 清理 staging
rm -rf "$STAGING_DIR"

echo ""
log "========================================"
log "离线包导出完成"
log "========================================"
log "归档: $ARCHIVE"
log "大小: $(du -h "$ARCHIVE" | cut -f1)"
log "校验: ${ARCHIVE}.sha256"
log "镜像数: ${copied} (失败 ${failed})"
echo ""
log "传输到离线环境后:"
log "  1. 解压: tar -xzf $(basename "$ARCHIVE")"
log "  2. 导入: cd ${STAGING_NAME} && bash scripts/load_dify.sh"
log "  3. 部署: bash scripts/install_dify.sh"
log "========================================"

if [[ "$failed" -gt 0 ]]; then
  warn "有 ${failed} 个镜像拉取/导出失败，离线包仅包含成功的镜像"
  warn "请检查失败镜像后重跑本脚本 (已成功的会自动跳过)"
  exit 1
fi

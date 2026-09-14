#!/usr/bin/env bash
# load_database_images.sh - 导入数据库/中间件 Docker 镜像
# 支持并行导入，自动验证加载结果

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 读取全局架构配置 (项目根目录 → bundle 根目录 → 包内 config)
for _p in "$ROOT_DIR/../arch.env" "$ROOT_DIR/arch.env" "$ROOT_DIR/config/arch.env"; do
  if [[ -f "$_p" ]]; then source "$_p"; break; fi
done
ARCH="${ARCH:-arm64}"
IMAGES_DIR="$ROOT_DIR/images/${ARCH}"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }

command -v docker >/dev/null 2>&1 || fatal "未安装 docker，请先安装 offline-docker 包"

[[ -d "$IMAGES_DIR" ]] || fatal "缺少镜像目录: $IMAGES_DIR，请先在在线机器执行 scripts/download_database_images.sh"

shopt -s nullglob
image_tars=("$IMAGES_DIR"/*.tar)
[[ ${#image_tars[@]} -gt 0 ]] || fatal "未找到数据库镜像 tar 包: $IMAGES_DIR/*.tar"

sha_file="$IMAGES_DIR/sha256sum.txt"
if [[ -f "$sha_file" ]]; then
  log "校验镜像 sha256: $sha_file"
  (cd "$IMAGES_DIR" && sha256sum -c sha256sum.txt) || fatal "镜像 sha256 校验失败，请重新下载或检查文件完整性"
fi

log "开始导入 ${#image_tars[@]} 个镜像 (并行导入)"

# 并行导入，每次最多 3 个
MAX_PARALLEL=3
loaded=0 failed=0
pid_list=()

load_one() {
  local tar_file="$1"
  local fname
  fname=$(basename "$tar_file")
  if docker load -i "$tar_file" >/dev/null 2>&1; then
    log "  [OK] $fname"
    return 0
  else
    warn "  [FAIL] $fname"
    return 1
  fi
}

for image_tar in "${image_tars[@]}"; do
  load_one "$image_tar" &
  pid=$!
  pid_list+=("$pid")

  # 控制并发数
  while [[ ${#pid_list[@]} -ge $MAX_PARALLEL ]]; do
    for i in "${!pid_list[@]}"; do
      if ! kill -0 "${pid_list[$i]}" 2>/dev/null; then
        wait "${pid_list[$i]}" && loaded=$((loaded + 1)) || failed=$((failed + 1))
        unset 'pid_list[$i]'
      fi
    done
    pid_list=("${pid_list[@]}")
    sleep 0.5
  done
done

# 等待所有剩余的并行任务完成
for pid in "${pid_list[@]}"; do
  wait "$pid" && loaded=$((loaded + 1)) || failed=$((failed + 1))
done

log "镜像导入完成: 成功 $loaded, 失败 $failed"

# 验证镜像已加载
log "验证已加载的镜像:"
docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}" | grep -iE "mysql|redis|kafka|nebula" || true

if [[ "$loaded" -eq 0 ]]; then
  fatal "没有任何镜像被成功加载"
fi

# 校验必要的镜像都存在
echo ""
log "校验关键镜像..."
MISSING=0
verify_image() {
  local img="$1"
  if docker image inspect "$img" >/dev/null 2>&1; then
    log "  [OK] $img"
  else
    warn "  [MISSING] $img"
    MISSING=$((MISSING + 1))
  fi
}

# 根据 tar 文件列表自动提取镜像名
for image_tar in "$IMAGES_DIR"/*.tar; do
  [[ -f "$image_tar" ]] || continue
  img_name=$(tar -xf "$image_tar" manifest.json -O 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data and data[0].get('RepoTags'):
    print(data[0]['RepoTags'][0])
" 2>/dev/null)
  if [[ -n "$img_name" ]]; then
    verify_image "$img_name"
  fi
done

if [[ "$MISSING" -gt 0 ]]; then
  fatal "有 $MISSING 个关键镜像加载失败，请检查后重试"
else
  log "所有关键镜像校验通过"
fi

if [[ "$failed" -gt 0 ]]; then
  warn "有 $failed 个镜像导入时出现错误，但必要的镜像已可用"
fi

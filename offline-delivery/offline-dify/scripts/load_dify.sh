#!/usr/bin/env bash
# load_dify.sh - 离线环境导入 Dify 镜像到 Docker
#
# 用法:
#   ./load_dify.sh                  # 导入全部镜像
#   FORCE_LOAD=1 ./load_dify.sh     # 强制重新导入
#
# 特性:
#   - 使用 docker load (Dify 是 docker-compose 部署, 不是 K8s)
#   - 自动校验 sha256
#   - 导入后逐个验证镜像可见
#   - 不依赖 sealos

set -euo pipefail

# 自动定位根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/images" ]]; then
  ROOT_DIR="$SCRIPT_DIR"
elif [[ -d "$SCRIPT_DIR/../images" ]]; then
  ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  echo "[FATAL] 找不到 images 目录 (脚本应位于 <bundle>/scripts/ 下)" >&2
  exit 1
fi

IMAGES_DIR="$ROOT_DIR/images"
LIST_FILE="$IMAGES_DIR/images.list"
SHA_FILE="$IMAGES_DIR/sha256sum.txt"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }

[[ -f "$LIST_FILE" ]] || fatal "缺少镜像清单: $LIST_FILE"
command -v docker >/dev/null 2>&1 || fatal "缺少 docker 命令"
docker info >/dev/null 2>&1 || fatal "docker daemon 未运行"

# 镜像名 ↔ tar 文件名映射 (与 pack_dify.sh 一致)
safe_name() { echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

# 读取 tar 内的 RepoTag (校验用)
tar_repotag() {
  python3 -c "
import tarfile, json, sys
try:
    with tarfile.open('$1') as t:
        m = json.load(t.extractfile('manifest.json'))
        print(m[0]['RepoTags'][0] if m and m[0].get('RepoTags') else '')
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# 镜像是否存在
image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

# 导入单个镜像
import_image() {
  local image="$1" tar="$2"
  if [[ "${FORCE_LOAD:-0}" != "1" ]] && image_exists "$image"; then
    log "  [SKIP] $image (已存在)"
    return 2
  fi

  if docker load -i "$tar" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ─── 主流程 ───
main() {
  log "========================================"
  log "Dify 镜像离线导入"
  log "========================================"
  log "镜像目录: $IMAGES_DIR"
  log "运行时: docker"
  log "========================================"

  # sha256 校验
  if [[ -f "$SHA_FILE" ]]; then
    log "校验 tar 文件 sha256: $SHA_FILE"
    if ! ( cd "$IMAGES_DIR" && sha256sum -c sha256sum.txt >/dev/null 2>&1 ); then
      fatal "sha256 校验失败，离线包可能损坏，请重新获取"
    fi
    log "sha256 校验通过"
  else
    warn "未找到 sha256sum.txt，跳过校验"
  fi

  # 统计
  local total=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    total=$((total + 1))
  done < "$LIST_FILE"
  log "待导入镜像: $total 个"
  echo ""

  local imported=0 skipped=0 failed=0
  declare -a FAILED=()

  while IFS= read -r image; do
    [[ -z "$image" ]] && continue
    local safe tar
    safe=$(safe_name "$image")
    tar="$IMAGES_DIR/${safe}.tar"

    if [[ ! -f "$tar" ]] || [[ ! -s "$tar" ]]; then
      warn "[MISSING] 缺少 tar 文件: ${safe}.tar ($image)"
      failed=$((failed + 1))
      FAILED+=("$image")
      continue
    fi

    # tar 内 RepoTag 与清单一致性检查
    local tag
    tag=$(tar_repotag "$tar") || true
    if [[ -n "$tag" ]] && [[ "$tag" != "$image" ]]; then
      warn "[WARN] tar 内 RepoTag($tag) 与清单($image) 不一致，仍尝试导入"
    fi

    log "[IMPORT] $image"
    if import_image "$image" "$tar"; then
      log "  [OK] $image"
      imported=$((imported + 1))
    else
      local rc=$?
      if [[ $rc -eq 2 ]]; then
        skipped=$((skipped + 1))
      else
        warn "  [FAIL] 导入失败: $image"
        failed=$((failed + 1))
        FAILED+=("$image")
      fi
    fi
  done < "$LIST_FILE"

  echo ""
  log "========================================"
  log "导入完成汇总"
  log "========================================"
  log "  成功导入: $imported"
  log "  跳过(已存在): $skipped"
  log "  失败: $failed"
  log "========================================"

  # 逐个校验
  log "校验 docker 中的镜像..."
  local verified=0 missing=0
  while IFS= read -r image; do
    [[ -z "$image" ]] && continue
    if image_exists "$image"; then
      log "  [OK] $image"
      verified=$((verified + 1))
    else
      warn "  [MISSING] $image"
      missing=$((missing + 1))
    fi
  done < "$LIST_FILE"
  log "校验结果: $verified 个存在, $missing 个缺失"

  if [[ "$failed" -gt 0 ]]; then
    warn "失败镜像:"
    for img in "${FAILED[@]}"; do warn "  - $img"; done
  fi

  if [[ "$missing" -gt 0 ]]; then
    warn "有 $missing 个镜像导入后仍不可见，请检查 docker daemon 状态"
    exit 1
  fi

  echo ""
  log "========================================"
  log "镜像就绪。后续操作:"
  log "  bash scripts/install_dify.sh   # 启动 Dify"
  log "========================================"
}

main "$@"

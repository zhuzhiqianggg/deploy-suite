#!/usr/bin/env bash
# ============================================================================
# app-load-images —— 将交付包内镜像导入目标机容器运行时（containerd 优先）
# ============================================================================
# 用法:
#   ./app-load-images.sh [images 目录]      # 默认: 脚本同级 ../images
#   FORCE_LOAD=1 ./app-load-images.sh       # 忽略已存在，强制重新导入
#   CONTAINERD_SOCK=/run/containerd/containerd.sock ./app-load-images.sh
#
# 特性:
#   - containerd 模式导入 k8s.io namespace（kubelet 可见），保留完整 registry 地址
#   - sha256 校验 → 逐个导入 → 导入后 crictl 校验可见性
#   - 预拉需加 --hosts-dir /etc/containerd/certs.d 时与本脚本无关（离线包场景无外网）
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${1:-}" ]]; then IMAGES_DIR="$1"
elif [[ -d "$SCRIPT_DIR/images" ]]; then IMAGES_DIR="$SCRIPT_DIR/images"
elif [[ -d "$SCRIPT_DIR/../images" ]]; then IMAGES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/images"
else echo "[FATAL] 找不到 images 目录，请传入: $0 <images目录>" >&2; exit 1; fi

LIST_FILE="$IMAGES_DIR/images.list"
[[ -f "$LIST_FILE" ]] || LIST_FILE="$IMAGES_DIR/../images.txt"
[[ -f "$LIST_FILE" ]] || { echo "[FATAL] 缺少镜像清单 (images.list / images.txt): $IMAGES_DIR" >&2; exit 1; }
SHA_FILE="$(dirname "$LIST_FILE")/images/app-images.tar.sha256"

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }
command -v python3 >/dev/null 2>&1 || fatal "缺少 python3"

CONTAINERD_SOCK="${CONTAINERD_SOCK:-/run/containerd/containerd.sock}"
CTR_BIN=""; RUNTIME=""

detect_runtime() {
  if [[ -S "$CONTAINERD_SOCK" ]]; then
    CTR_BIN="$(command -v ctr 2>/dev/null || true)"
    [[ -z "$CTR_BIN" ]] && for p in /usr/local/bin/ctr /usr/bin/ctr; do [[ -x "$p" ]] && CTR_BIN="$p" && break; done
    [[ -n "$CTR_BIN" ]] && { RUNTIME="containerd"; return 0; }
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then RUNTIME="docker"; return 0; fi
  fatal "未检测到可用容器运行时 (containerd sock: $CONTAINERD_SOCK)"
}

safe_name() { echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

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

image_exists() {
  local image="$1"
  if [[ "$RUNTIME" == "containerd" ]]; then
    if command -v crictl >/dev/null 2>&1; then
      crictl images -o json 2>/dev/null | python3 -c "
import sys, json
try: data = json.load(sys.stdin)
except Exception: sys.exit(1)
tags = set()
for img in data.get('images', []):
    for t in img.get('repoTags', []) or []: tags.add(t)
sys.exit(0 if '$image' in tags else 1)
" 2>/dev/null && return 0
    fi
    "$CTR_BIN" --address="$CONTAINERD_SOCK" -n k8s.io images ls 2>/dev/null | grep -qF "$image" && return 0
    return 1
  else
    docker image inspect "$image" >/dev/null 2>&1
  fi
}

import_image() {
  local image="$1" tar="$2"
  if [[ "${FORCE_LOAD:-0}" != "1" ]] && image_exists "$image"; then return 2; fi
  if [[ "$RUNTIME" == "containerd" ]]; then
    "$CTR_BIN" --address="$CONTAINERD_SOCK" -n k8s.io images import --no-unpack "$tar" >/dev/null 2>&1 && return 0
    "$CTR_BIN" --address="$CONTAINERD_SOCK" -n k8s.io images import "$tar" >/dev/null 2>&1 && return 0
    return 1
  else
    docker load -i "$tar" >/dev/null 2>&1 && return 0 || return 1
  fi
}

main() {
  log "========================================"
  log "业务应用镜像导入  目录: $IMAGES_DIR"
  detect_runtime
  if [[ "$RUNTIME" == "containerd" ]]; then
    log "运行时: containerd ($CONTAINERD_SOCK) → namespace k8s.io"
    TARS=("$IMAGES_DIR"/*.tar)
  else
    log "运行时: docker"
    TARS=("$IMAGES_DIR"/*.tar)
  fi
  log "========================================"

  # 兼容两种交付形态: 多个 per-image tar（safe_name 命名）或单个 app-images.tar
  local tar_files=()
  for t in "$IMAGES_DIR"/*.tar; do [[ -f "$t" && -s "$t" ]] && tar_files+=("$t"); done
  [[ ${#tar_files[@]} -eq 0 ]] && fatal "images 目录无 tar 文件"

  # sha256 校验（存在校验文件时）
  local sha_dir; sha_dir="$(dirname "${tar_files[0]}")"
  if [[ -f "$sha_dir/app-images.tar.sha256" ]]; then
    log "校验 sha256 ..."
    (cd "$sha_dir" && sha256sum -c app-images.tar.sha256 >/dev/null 2>&1) \
      && log "sha256 校验通过" || fatal "sha256 校验失败，离线包可能损坏"
  fi

  local imported=0 skipped=0 failed=0
  declare -a FAILED=()
  if [[ ${#tar_files[@]} -eq 1 && "$(basename "${tar_files[0]}")" == "app-images.tar" ]]; then
    # 单 tar 多镜像形态：ctr import 幂等（已存在镜像自动覆盖注册），不做逐镜像 SKIP
    log "[IMPORT] app-images.tar（全量导入）"
    if [[ "$RUNTIME" == "containerd" ]]; then
      "$CTR_BIN" --address="$CONTAINERD_SOCK" -n k8s.io images import --all-platforms "${tar_files[0]}" >/dev/null 2>&1 \
        || "$CTR_BIN" --address="$CONTAINERD_SOCK" -n k8s.io images import "${tar_files[0]}" >/dev/null 2>&1 \
        || failed=1
    else
      docker load -i "${tar_files[0]}" >/dev/null 2>&1 || failed=1
    fi
    [[ $failed -eq 0 ]] && imported=1 || { warn "  [FAIL] app-images.tar"; exit 1; }
  else
    # 多 tar（per-image）形态：按 RepoTag 去重导入
    for tar in "${tar_files[@]}"; do
      local tag=""; tag=$(tar_repotag "$tar") || true
      if [[ -z "$tag" ]]; then
        warn "[WARN] 无法从 tar 解析 RepoTag: $(basename "$tar")（尝试导入）"
        if import_image "__unknown__" "$tar"; then imported=$((imported+1)); else failed=$((failed+1)); FAILED+=("$(basename "$tar")"); fi
        continue
      fi
      log "[IMPORT] $tag"
      if import_image "$tag" "$tar"; then
        log "  [OK] $tag"; imported=$((imported+1))
      else
        rc=$?
        if [[ $rc -eq 2 ]]; then log "  [SKIP] 已存在"; skipped=$((skipped+1))
        else warn "  [FAIL] $tag"; failed=$((failed+1)); FAILED+=("$tag"); fi
      fi
    done
  fi

  echo ""
  log "汇总: 导入 $imported / 跳过 $skipped / 失败 $failed"
  if [[ "$failed" -gt 0 ]]; then
    warn "失败列表:"; for img in "${FAILED[@]}"; do warn "  - $img"; done
    exit 1
  fi

  # 导入后按清单校验可见性
  local images_txt="$IMAGES_DIR/images.list"
  [[ -f "$images_txt" ]] || images_txt="$IMAGES_DIR/../images.txt"
  if [[ -f "$images_txt" ]]; then
    log "校验镜像可见性 ..."
    local missing=0
    while IFS= read -r img; do
      [[ -z "$img" ]] && continue
      if image_exists "$img"; then log "  [OK] $img"
      else warn "  [MISSING] $img"; missing=$((missing+1)); fi
    done < "$images_txt"
    [[ $missing -gt 0 ]] && { warn "$missing 个镜像导入后不可见，检查运行时/sock 后重跑"; exit 1; }
  fi
  log "全部镜像就绪。确保清单 imagePullPolicy=IfNotPresent 或 Never。"
}

main "$@"

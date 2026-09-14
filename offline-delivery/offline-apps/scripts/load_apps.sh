#!/usr/bin/env bash
# load_apps.sh - 离线环境导入业务应用镜像到 K8s 节点
#
# 用法:
#   ./scripts/load_apps.sh              # 导入全部镜像
#   FORCE_LOAD=1 ./scripts/load_apps.sh # 强制重新导入(忽略已存在)
#   CONTAINERD_SOCK=/run/containerd/containerd.sock ./scripts/load_apps.sh
#
# 特性:
#   - 自动识别 containerd(ctr) 或 docker 运行时
#   - containerd 模式导入到 k8s.io namespace (kubelet 可见)
#   - 镜像保留完整 registry 地址，K8s 清单无需修改
#   - 导入后逐个校验镜像是否可被运行时识别
#   - 不依赖 sealos

set -euo pipefail

# 自动定位根目录 (脚本在 scripts/ 下，根目录为其父目录)
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
command -v python3 >/dev/null 2>&1 || fatal "缺少 python3 (校验镜像名需要)"

# ─── 运行时检测 ───
CONTAINERD_SOCK="${CONTAINERD_SOCK:-/run/containerd/containerd.sock}"
CTR_BIN=""
RUNTIME=""

detect_runtime() {
  # 优先 containerd (K8s 节点标准运行时)
  if [[ -S "$CONTAINERD_SOCK" ]]; then
    CTR_BIN="$(command -v ctr 2>/dev/null || true)"
    if [[ -z "$CTR_BIN" ]]; then
      for p in /usr/local/bin/ctr /usr/bin/ctr; do
        [[ -x "$p" ]] && CTR_BIN="$p" && break
      done
    fi
    if [[ -n "$CTR_BIN" ]]; then
      RUNTIME="containerd"
      return 0
    fi
  fi

  # 回退 docker
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      RUNTIME="docker"
      return 0
    fi
  fi

  fatal "未检测到可用的容器运行时 (containerd socket: $CONTAINERD_SOCK 或 docker)。K8s 节点请确认 containerd 已启动。"
}

# ─── 镜像名 ↔ tar 文件名映射 (与 pack 脚本一致) ───
safe_name() { echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

# 读取 tar 内的 RepoTag (校验导入结果)
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

# ─── 校验镜像是否在运行时中可见 ───
image_exists() {
  local image="$1"
  if [[ "$RUNTIME" == "containerd" ]]; then
    # crictl 是 CRI 视图 (kubelet 实际使用的)，优先用它校验
    if command -v crictl >/dev/null 2>&1; then
      if crictl images -o json 2>/dev/null \
          | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
tags = set()
for img in data.get('images', []):
    for t in img.get('repoTags', []) or []:
        tags.add(t)
sys.exit(0 if '$image' in tags else 1)
" 2>/dev/null; then
        return 0
      fi
    fi
    # 回退 ctr
    "$CTR_BIN" --address="$CONTAINERD_SOCK" -n k8s.io images ls 2>/dev/null \
      | grep -qF "$image" && return 0
    return 1
  else
    docker image inspect "$image" >/dev/null 2>&1
  fi
}

# ─── 导入单个镜像 ───
import_image() {
  local image="$1" tar="$2"
  if [[ "${FORCE_LOAD:-0}" != "1" ]] && image_exists "$image"; then
    log "  [SKIP] $image (已存在)"
    return 2
  fi

  if [[ "$RUNTIME" == "containerd" ]]; then
    # ctr import 保留原始 RepoTags；--no-unpack 交给 kubelet 按需 unpack，提速且避免无关层 unpack 报错
    if "$CTR_BIN" --address="$CONTAINERD_SOCK" -n k8s.io images import --no-unpack "$tar" >/dev/null 2>&1; then
      return 0
    fi
    # 重试一次 (不带 --no-unpack)，部分场景需要 unpack 才能注册
    if "$CTR_BIN" --address="$CONTAINERD_SOCK" -n k8s.io images import "$tar" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  else
    if docker load -i "$tar" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
}

# ─── 主流程 ───
main() {
  log "========================================"
  log "业务应用镜像离线导入"
  log "========================================"
  log "镜像目录: $IMAGES_DIR"

  detect_runtime
  if [[ "$RUNTIME" == "containerd" ]]; then
    log "运行时: containerd ($CONTAINERD_SOCK)"
    log "命名空间: k8s.io (kubelet 可见)"
  else
    log "运行时: docker"
  fi
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

  # 统计待导入
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
  log "校验运行时中的镜像..."
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

  # 列出运行时中相关镜像 (展示用)
  if [[ "$RUNTIME" == "containerd" ]] && command -v crictl >/dev/null 2>&1; then
    echo ""
    log "运行时镜像 (crictl):"
    crictl images 2>/dev/null | grep -iE 'swr.cn-east-3|beosin-develop|api-beosin' | head -50 || true
  fi

  if [[ "$failed" -gt 0 ]]; then
    warn "失败镜像:"
    for img in "${FAILED[@]}"; do warn "  - $img"; done
  fi

  if [[ "$missing" -gt 0 ]]; then
    warn "有 $missing 个镜像导入后仍不可见，可能需要: 1) 检查 containerd 是否运行 2) 确认 sock 路径 3) 重跑"
    exit 1
  fi

  log "全部镜像就绪。请确保 K8s 清单中 imagePullPolicy 设为 IfNotPresent 或 Never。"
}

main "$@"

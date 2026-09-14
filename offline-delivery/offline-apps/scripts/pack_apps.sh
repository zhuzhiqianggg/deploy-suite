#!/usr/bin/env bash
# pack_apps.sh - 在线机器执行：按镜像清单拉取、导出、打包业务镜像离线包
#
# 用法:
#   ./scripts/pack_apps.sh              # 读取 ../images.conf
#   CONF_FILE=/path/to/list.conf ./scripts/pack_apps.sh
#   FORCE_PULL=1 ./scripts/pack_apps.sh # 强制重新拉取(忽略已存在的 tar)
#
# 产出: bundle/offline-app-images-<arch>-<timestamp>.tar.gz
#       包内自带 load_apps.sh，传到离线节点解压后一键执行即可导入。
#
# 关键设计:
#   - 镜像保留完整 registry 地址 (docker save 的 RepoTags 不变)
#   - 离线侧用 ctr -n k8s.io images import / docker load 导入，地址不变
#   - K8s 清单里的 image 字段无需任何修改，配合 imagePullPolicy: IfNotPresent 即可本地命中

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 读取全局架构配置 (项目根目录 → 本目录)
for _p in "$ROOT_DIR/../arch.env" "$ROOT_DIR/arch.env"; do
  if [[ -f "$_p" ]]; then source "$_p"; break; fi
done
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64|aarch64) ARCH=arm64; OCI_PLATFORM="linux/arm64"; PKG_ARCH="aarch64" ;;
  amd64|x86_64)  ARCH=amd64; OCI_PLATFORM="linux/amd64"; PKG_ARCH="x86_64" ;;
  *) echo "不支持的架构: $ARCH (可选: arm64, amd64)"; exit 1 ;;
esac

CONF_FILE="${CONF_FILE:-$ROOT_DIR/images.conf}"
IMAGES_DIR="$ROOT_DIR/images"
# 全局 bundle 目录: /opt/install/bundle/${ARCH}/apps/
GLOBAL_BUNDLE_ROOT="$ROOT_DIR/../bundle"
BUNDLE_DIR="$GLOBAL_BUNDLE_ROOT/$ARCH/apps"
SCRIPTS_DIR="$ROOT_DIR/scripts"
MAX_RETRIES=3
TS=$(date +%Y%m%d%H%M%S)

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }

command -v docker >/dev/null 2>&1 || fatal "缺少 docker 命令"
[[ -f "$CONF_FILE" ]] || fatal "缺少镜像清单: $CONF_FILE"
[[ -f "$SCRIPTS_DIR/load_apps.sh" ]] || fatal "缺少 load_apps.sh: $SCRIPTS_DIR/load_apps.sh"

mkdir -p "$IMAGES_DIR" "$BUNDLE_DIR"

# 清理该架构下该类型的所有历史 bundle (保留当前正在生成的)
rm -rf "$BUNDLE_DIR"/offline-app-images-${PKG_ARCH} \
       "$BUNDLE_DIR"/offline-app-images-${PKG_ARCH}-*.tar.gz \
       "$BUNDLE_DIR"/offline-app-images-${PKG_ARCH}-*.tar.gz.sha256

# 清理孤儿 .sha256: 上一次异常中断可能留下没有对应 tar.gz 的 .sha256 文件
for sha in "$BUNDLE_DIR"/offline-app-images-${PKG_ARCH}-*.tar.gz.sha256; do
  [[ -f "$sha" ]] || continue
  tar="${sha%.sha256}"
  if [[ ! -f "$tar" ]]; then
    warn "清理孤儿 .sha256: $(basename "$sha")"
    rm -f "$sha"
  fi
done

# ─── 解析镜像清单 ───
# 去除注释 (# 之后内容) 后，正则提取所有 registry/path:tag (host 含 .)
mapfile -t IMAGES < <(sed 's/#.*//' "$CONF_FILE" \
  | grep -oE '[A-Za-z0-9._-]+\.[A-Za-z0-9._-]+/[A-Za-z0-9._/+~-]+:[A-Za-z0-9._+~-]+' \
  | sort -u)

[[ ${#IMAGES[@]} -gt 0 ]] || fatal "未从 $CONF_FILE 解析到任何镜像"

log "========================================"
log "业务应用镜像离线打包"
log "========================================"
log "架构: ${ARCH} (${OCI_PLATFORM})"
log "清单: $CONF_FILE"
log "镜像数: ${#IMAGES[@]}"
log "========================================"

# 生成安全文件名 (与 load 脚本及 offline-k8s 约定一致: 非字母数字._- 替换为 _)
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

for image in "${IMAGES[@]}"; do
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
    if docker pull --platform "$OCI_PLATFORM" "$image" 2>&1; then
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
for image in "${IMAGES[@]}"; do
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
STAGING_NAME="offline-app-images-${PKG_ARCH}"
STAGING_DIR="$BUNDLE_DIR/$STAGING_NAME"
log "组装离线包: $STAGING_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/images" "$STAGING_DIR/scripts"

# 仅复制成功导出的 tar (与 images.list 对齐，失败的不打包)
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

# 重新生成包内 sha256sum.txt (只含实际打包的 tar)
( cd "$STAGING_DIR/images" && sha256sum *.tar > sha256sum.txt )
cp "$IMAGES_DIR/images.list" "$STAGING_DIR/images/images.list"

# 复制 load 脚本
cp "$SCRIPTS_DIR/load_apps.sh" "$STAGING_DIR/scripts/load_apps.sh"
chmod +x "$STAGING_DIR/scripts/load_apps.sh"

# VERSION.txt
cat > "$STAGING_DIR/VERSION.txt" <<EOF
业务应用镜像离线包
==================
构建时间: $(date '+%F %T')
架构: ${ARCH} (${PKG_ARCH})
镜像数量: ${copied}
来源清单: ${CONF_FILE}

内容:
  images/*.tar           各镜像 tar 包 (docker-archive 格式，保留完整 registry 地址)
  images/images.list     镜像完整引用清单 (导入与校验依据)
  images/sha256sum.txt   tar 文件 sha256 校验
  scripts/load_apps.sh  离线导入脚本

离线环境使用:
  1. 解压: tar -xzf ${STAGING_NAME}-*.tar.gz
  2. 导入(每个 k8s 节点执行): cd ${STAGING_NAME} && ./scripts/load_apps.sh
  3. K8s 清单中 image 字段保持原样，设置 imagePullPolicy: IfNotPresent

注意:
  - 不依赖 sealos，直接导入 containerd(k8s.io namespace) 或 docker
  - 镜像地址不变，K8s 清单无需修改
  - 需在所有可能调度该 Pod 的节点上执行导入
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
log "  2. 导入: cd ${STAGING_NAME} && ./scripts/load_apps.sh"
log "========================================"

if [[ "$failed" -gt 0 ]]; then
  warn "有 ${failed} 个镜像拉取/导出失败，离线包仅包含成功的镜像"
  warn "请检查失败镜像后重跑本脚本 (已成功的会自动跳过)"
  exit 1
fi

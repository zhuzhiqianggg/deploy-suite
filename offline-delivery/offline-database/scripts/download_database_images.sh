#!/usr/bin/env bash
# download_database_images.sh - 在线机器执行，下载并导出数据库/中间件镜像
# 支持重试、每镜像错误独立处理、进度显示

set -euo pipefail
ROOT_DIR="${ROOT_DIR:-/opt/install/offline-database}"

# 读取全局架构配置 (项目根目录 → bundle 根目录 → 包内 config)
for _p in "$ROOT_DIR/../arch.env" "$ROOT_DIR/arch.env" "$ROOT_DIR/config/arch.env"; do
  if [[ -f "$_p" ]]; then source "$_p"; break; fi
done
ARCH="${ARCH:-arm64}"
case "$ARCH" in
  arm64) OCI_PLATFORM="linux/arm64" ;;
  amd64) OCI_PLATFORM="linux/amd64" ;;
  *) fatal "不支持的架构: $ARCH (可选: arm64, amd64)" ;;
esac

IMAGES_DIR="$ROOT_DIR/images/${ARCH}"

mkdir -p "$IMAGES_DIR"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }

command -v docker >/dev/null 2>&1 || fatal "缺少 docker 命令"

# 镜像列表: "image_name:tag"  (tag 固定到具体版本，避免 latest 在离线环境无法解析)
IMAGES=(
  "mysql:8.4"
  "redis:8.8"
  "apache/kafka:4.0.2"
  "provectuslabs/kafka-ui:latest"
  "vesoft/nebula-metad:v3.8.0"
  "vesoft/nebula-storaged:v3.8.0"
  "vesoft/nebula-graphd:v3.8.0"
  "vesoft/nebula-console:v3.8.0"
)

MAX_RETRIES=3
pulled=0 skipped=0 failed=0

for image in "${IMAGES[@]}"; do
  # 生成安全的文件名
  out="${image//\//_}"
  out="${out//:/_}.tar"
  out_path="$IMAGES_DIR/$out"

  # 如果文件已存在且 sha256 匹配则跳过
  if [[ -f "$out_path" ]]; then
    local_sha=$(sha256sum "$out_path" | awk '{print $1}')
    if [[ -f "$IMAGES_DIR/sha256sum.txt" ]]; then
      expected_sha=$(grep "$out" "$IMAGES_DIR/sha256sum.txt" | awk '{print $1}' || true)
      if [[ "$local_sha" == "$expected_sha" ]]; then
        log "[SKIP] $image (已存在且 sha256 匹配)"
        skipped=$((skipped + 1))
        continue
      fi
    fi
  fi

  # 拉取镜像（带重试）
  log "[PULL] $image"
  pull_ok=false
  for attempt in $(seq 1 $MAX_RETRIES); do
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
    continue
  fi

  # 导出镜像
  log "[SAVE] $image -> $out"
  docker save -o "$out_path" "$image"

  # 验证导出文件
  if [[ -f "$out_path" ]] && [[ -s "$out_path" ]]; then
    log "  [OK] $(du -h "$out_path" | cut -f1)"
    pulled=$((pulled + 1))
  else
    warn "[FAIL] 导出失败: $image"
    failed=$((failed + 1))
    rm -f "$out_path"
  fi
done

# 生成校验文件
log "生成 sha256sum.txt"
(cd "$IMAGES_DIR" && sha256sum *.tar > sha256sum.txt 2>/dev/null)

echo ""
log "========================================"
log "下载完成汇总"
log "========================================"
log "  成功拉取: $pulled"
log "  跳过(已存在): $skipped"
log "  失败: $failed"
log "  镜像目录: $IMAGES_DIR"
log "  总大小: $(du -sh "$IMAGES_DIR" | cut -f1)"
log "========================================"

if [[ "$failed" -gt 0 ]]; then
  fatal "有 $failed 个镜像下载失败，请检查网络后重试"
fi

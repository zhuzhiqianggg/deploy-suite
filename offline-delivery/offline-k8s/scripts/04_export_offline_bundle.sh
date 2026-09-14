#!/usr/bin/env bash
# 04_export_offline_bundle.sh - 导出离线部署包
# 将所有组件打包成单一压缩文件，便于传输到目标服务器

set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/opt/install/offline-k8s}"
CONFIG_DIR="$ROOT_DIR/config"
VERSIONS_LOCK="$CONFIG_DIR/versions.lock"

# 读取全局架构配置 (项目根目录 → bundle 根目录)
for _p in "$ROOT_DIR/../arch.env" "$ROOT_DIR/arch.env"; do
  if [[ -f "$_p" ]]; then source "$_p"; break; fi
done
ARCH="${ARCH:-arm64}"
# 全局 bundle 目录: /opt/install/bundle/${ARCH}/k8s/
GLOBAL_BUNDLE_ROOT="$ROOT_DIR/../bundle"
BUNDLE_DIR="$GLOBAL_BUNDLE_ROOT/$ARCH/k8s"
TIMESTAMP=$(date +%Y%m%d%H%M%S)

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal() { log "ERROR: $*"; exit 1; }

# 加载版本锁定 (保存 arch.env 的 ARCH，防止 versions.lock 覆盖)
[[ -f "$VERSIONS_LOCK" ]] || fatal "缺少版本锁定文件: $VERSIONS_LOCK"
_ARCH_FROM_ENV="${ARCH:-}"
# shellcheck disable=SC1090
source "$VERSIONS_LOCK"
[[ -n "$_ARCH_FROM_ENV" ]] && ARCH="$_ARCH_FROM_ENV"
# 根据 ARCH 重新推导 RPM_ARCH (不信任 versions.lock 中的硬编码值)
case "$ARCH" in
  arm64) RPM_ARCH="aarch64" ;;
  amd64) RPM_ARCH="x86_64" ;;
  *) fatal "不支持的架构: $ARCH" ;;
esac

STAGING_NAME="k8s-offline-openEuler-${RPM_ARCH}"
STAGING_DIR="$BUNDLE_DIR/$STAGING_NAME"

# 清理该架构下该类型的所有历史 bundle
rm -rf "$STAGING_DIR" \
       "$BUNDLE_DIR"/k8s-offline-openEuler-${RPM_ARCH}-*.tar.gz \
       "$BUNDLE_DIR"/k8s-offline-openEuler-${RPM_ARCH}-*.tar.gz.sha256
mkdir -p "$BUNDLE_DIR"

# 清理孤儿 .sha256: 上一次异常中断可能留下没有对应 tar.gz 的 .sha256 文件
for sha in "$BUNDLE_DIR"/k8s-offline-openEuler-${RPM_ARCH}-*.tar.gz.sha256; do
  [[ -f "$sha" ]] || continue
  tar="${sha%.sha256}"
  if [[ ! -f "$tar" ]]; then
    warn "清理孤儿 .sha256: $(basename "$sha")"
    rm -f "$sha"
  fi
done

# 使用 pigz 并行压缩（如可用）
GZIP_CMD="gzip"
if command -v pigz >/dev/null 2>&1; then
  GZIP_CMD="pigz"
  log "检测到 pigz，将启用并行压缩"
fi

prepare_bundle_dir() {
  log "准备 staging 目录: $STAGING_DIR"

  # 使用临时 staging 目录，避免 rm -rf 后残留
  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR"

  # 架构相关目录（只复制当前架构）
  local arch_items=(
    "bin/${ARCH}:可执行文件 (sealos, helm)"
    "images/${ARCH}:应用镜像 tar 包"
    "sealos-images/${ARCH}:K8s cluster images"
    "pkgs/${ARCH}:RPM 系统依赖包"
  )

  # 架构无关目录
  local common_items=(
    "config:配置文件和版本锁定"
    "manifests:K8s manifest 文件"
  )

  # 复制架构相关目录
  for item in "${arch_items[@]}"; do
    local dir="${item%%:*}"
    local label="${item#*:}"
    local src="${ROOT_DIR}/${dir}"
    if [[ -d "$src" ]] && [[ -n "$(ls -A "$src" 2>/dev/null)" ]]; then
      # 创建父目录后复制，保持架构子目录
      mkdir -p "$STAGING_DIR/$(dirname "$dir")"
      cp -a "$src" "$STAGING_DIR/${dir}"
      log "  [OK] $dir ($label)"
    else
      log "  [SKIP] $dir ($label) - 目录为空或不存在"
    fi
  done

  # 复制架构无关目录
  for item in "${common_items[@]}"; do
    local dir="${item%%:*}"
    local label="${item#*:}"
    local src="${ROOT_DIR}/${dir}"
    if [[ -d "$src" ]] && [[ -n "$(ls -A "$src" 2>/dev/null)" ]]; then
      cp -a "$src" "$STAGING_DIR/"
      log "  [OK] $dir ($label)"
    else
      log "  [SKIP] $dir ($label) - 目录为空或不存在"
    fi
  done

  # 验证关键文件存在
  local required=(
    "bin/${ARCH}/sealos"
    "bin/${ARCH}/helm"
    "config/versions.lock"
    "manifests/ingress-nginx/deploy.yaml"
  )
  local optional_arch=(
    "sealos-images/${ARCH}/kubernetes-${KUBERNETES_VERSION}-${ARCH}.tar"
    "sealos-images/${ARCH}/calico-${CALICO_VERSION}-${ARCH}.tar"
  )
  local missing=0
  for f in "${required[@]}"; do
    if [[ ! -f "$STAGING_DIR/$f" ]]; then
      warn "缺失关键文件: $f"
      missing=$((missing + 1))
    fi
  done
  # sealos cluster image 跨架构场景下可能缺失 (在 amd64 主机上重新执行 01_download 可补全)
  for f in "${optional_arch[@]}"; do
    if [[ ! -f "$STAGING_DIR/$f" ]]; then
      warn "缺失非必要文件: $f (跨架构下载 sealos cluster image 受限，需在 ${ARCH} 主机上补全)"
    fi
  done
  if [[ $missing -gt 0 ]]; then
    fatal "缺少 $missing 个关键文件，无法打包"
  fi
}

copy_scripts() {
  log "复制安装脚本"
  mkdir -p "$STAGING_DIR/scripts"

  cp "${ROOT_DIR}/scripts/install_offline.sh" "$STAGING_DIR/install_offline.sh"
  chmod +x "$STAGING_DIR/install_offline.sh"
  log "  [OK] install_offline.sh"

  if [[ -d "${ROOT_DIR}/scripts" ]]; then
    # 排除 __pycache__ 和 .pyc 文件
    (cd "${ROOT_DIR}/scripts" && find . -type f -not -path '*/__pycache__/*' -not -name '*.pyc' -print0 | \
      tar --null -cf - -T - | tar -xf - -C "$STAGING_DIR/scripts/")
    chmod +x "$STAGING_DIR/scripts/"*.sh 2>/dev/null || true
    log "  [OK] scripts/ 目录"
  fi

  # 复制全局架构配置到 bundle 根目录
  if [[ -f "$ROOT_DIR/../arch.env" ]]; then
    cp "$ROOT_DIR/../arch.env" "$STAGING_DIR/arch.env"
    log "  [OK] arch.env"
  fi
}

create_version_info() {
  cat > "$STAGING_DIR/VERSION.txt" <<EOF
Kubernetes Offline Deployment Package
=====================================
构建时间: $(date '+%Y-%m-%d %H:%M:%S')
架构: ${ARCH} (${RPM_ARCH})
目标系统: openEuler 22.03 LTS

组件版本:
---------
Kubernetes: ${KUBERNETES_VERSION}
Calico: ${CALICO_VERSION}
ingress-nginx: ${INGRESS_NGINX_VERSION}
Sealos: ${SEALOS_VERSION}
Helm: ${HELM_VERSION}
Prometheus: v3.12.0
Grafana: 13.0.2

版本策略: ${VERSION_POLICY}
${VERSION_NOTES}

使用方法:
---------
1. 解压包: tar -xzf k8s-offline-*.tar.gz
2. 执行安装: ./install_offline.sh

EOF
  log "VERSION.txt 已创建"
}

generate_checksums() {
  log "生成 sha256 校验文件"
  (cd "$STAGING_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum > sha256sum.txt)
  log "sha256sum.txt 已生成 ($(wc -l < "$STAGING_DIR/sha256sum.txt") 个文件)"
}

create_archive() {
  local archive_name="k8s-offline-openEuler-${RPM_ARCH}-${TIMESTAMP}.tar.gz"
  local archive_path="$BUNDLE_DIR/$archive_name"

  log "创建归档 (使用 $GZIP_CMD): $archive_name"

  # 使用 tar + 选择的压缩工具
  (cd "$BUNDLE_DIR" && tar -cf - "$STAGING_NAME" | $GZIP_CMD -c > "$archive_path")

  local size
  size=$(du -h "$archive_path" | cut -f1)
  log "归档完成: $archive_path (${size})"

  sha256sum "$archive_path" > "${archive_path}.sha256"
  log "sha256 校验码: ${archive_path}.sha256"
}

print_summary() {
  log "========================================"
  log "离线包导出完成"
  log "========================================"
  log "归档文件: $BUNDLE_DIR/k8s-offline-openEuler-${RPM_ARCH}-${TIMESTAMP}.tar.gz"
  log "文件大小: $(du -h "$BUNDLE_DIR/k8s-offline-openEuler-${RPM_ARCH}-${TIMESTAMP}.tar.gz" | cut -f1)"
  log ""
  log "传输到目标服务器后:"
  log "  1. 解压: tar -xzf k8s-offline-openEuler-${RPM_ARCH}-*.tar.gz"
  log "  2. 安装: sudo ./install_offline.sh"
  log ""
  log "注意: 安装脚本需 root 权限运行"
  log "========================================"
}

main() {
  log "开始导出离线部署包"

  prepare_bundle_dir
  copy_scripts
  create_version_info
  generate_checksums
  create_archive
  rm -rf "$STAGING_DIR"
  print_summary

  log "完成"
}

main "$@"

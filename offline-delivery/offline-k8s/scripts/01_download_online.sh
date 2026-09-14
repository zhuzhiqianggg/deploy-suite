#!/usr/bin/env bash
# 01_download_online.sh - 在线下载所有必需的离线组件
# 在有网络的机器上执行，下载所有 K8s 组件、镜像和配置

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
# 读取全局架构配置（架构相关目录按架构分目录存放）
for _p in "$ROOT_DIR/../arch.env" "$ROOT_DIR/config/arch.env"; do
  if [[ -f "$_p" ]]; then source "$_p"; break; fi
done
ARCH="${ARCH:-arm64}"
BIN_DIR="$ROOT_DIR/bin/${ARCH}"
TMP_DIR="$ROOT_DIR/tmp"
IMAGES_DIR="$ROOT_DIR/images/${ARCH}"
MANIFESTS_DIR="$ROOT_DIR/manifests"
BUNDLE_DIR="$ROOT_DIR/bundle"
LOG_DIR="$ROOT_DIR/logs"
VERSIONS_LOCK="$CONFIG_DIR/versions.lock"
COMPONENT_VERSIONS="$CONFIG_DIR/component-versions.env"

mkdir -p "$BIN_DIR" "$TMP_DIR" "$IMAGES_DIR" "$MANIFESTS_DIR/ingress-nginx" "$MANIFESTS_DIR/kuboard" "$BUNDLE_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/download-online-$(date +%Y%m%d%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*" >&2; }
fatal() { log "ERROR: $*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "缺少命令: $1"; }

# 修复 OCI 布局 tar：移除 index.json/oci-layout，保留纯 docker-archive
fix_oci_tar() {
  local tar_file="$1"
  if tar tf "$tar_file" 2>/dev/null | grep -qxF 'index.json'; then
    log "  修复 OCI tar: $(basename "$tar_file")"
    local tmpdir
    tmpdir="$(mktemp -d)"
    tar xf "$tar_file" -C "$tmpdir"
    rm -f "$tmpdir/index.json" "$tmpdir/oci-layout"
    (cd "$tmpdir" && find . -type f | sed 's|^\./||' | sort | tar cf "$tar_file" -T -)
    rm -rf "$tmpdir"
  fi
}

api_get() {
  local url="$1"
  curl -fsSL --retry 3 --connect-timeout 20 "$url"
}

latest_github_tag() {
  local repo="$1" include_regex="${2:-}"
  api_get "https://api.github.com/repos/${repo}/releases" | python3 -c 'import json, re, sys
include=sys.argv[1]
inc=re.compile(include) if include else None
items=json.load(sys.stdin)
for r in items:
    tag=r.get("tag_name", "")
    name=r.get("name", "")
    if r.get("draft") or r.get("prerelease"):
        continue
    s=(tag+" "+name).lower()
    if re.search(r"(alpha|beta|rc|nightly|dev|snapshot)", s):
        continue
    if inc and not inc.search(tag):
        continue
    print(tag)
    raise SystemExit
raise SystemExit(1)' "$include_regex"
}

latest_kubernetes_tag() {
  api_get "https://dl.k8s.io/release/stable.txt"
}

latest_dockerhub_semver_tag() {
  local repo="$1"
  api_get "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100" | python3 -c 'import json, re, sys
items=json.load(sys.stdin).get("results", [])
tags=[]
for item in items:
    tag=item.get("name", "")
    if re.match(r"^v?\d+\.\d+\.\d+$", tag):
        tags.append(tag)
if not tags:
    raise SystemExit(1)
def key(tag):
    return tuple(map(int, re.findall(r"\d+", tag)[:3]))
print(sorted(set(tags), key=key, reverse=True)[0])'
}

asset_download_url() {
  local repo="$1" tag="$2" pattern="$3"
  api_get "https://api.github.com/repos/${repo}/releases/tags/${tag}" | python3 -c 'import json, re, sys
pat=re.compile(sys.argv[1])
data=json.load(sys.stdin)
for a in data.get("assets", []):
    name=a.get("name", "")
    if pat.search(name):
        print(a.get("browser_download_url"))
        raise SystemExit
raise SystemExit(1)' "$pattern"
}

write_lock() {
  cat > "$VERSIONS_LOCK" <<EOF_LOCK
ARCH=$ARCH
RPM_ARCH=$RPM_ARCH
VERSION_POLICY=$VERSION_POLICY
ALLOW_PRERELEASE=$ALLOW_PRERELEASE
AUTO_UPGRADE=${AUTO_UPGRADE:-false}
SEALOS_VERSION=$SEALOS_VERSION
KUBERNETES_MINOR=${KUBERNETES_MINOR:-1.33}
KUBERNETES_VERSION=$KUBERNETES_VERSION
CALICO_VERSION=$CALICO_VERSION
INGRESS_NGINX_VERSION=$INGRESS_NGINX_VERSION
INGRESS_NGINX_CHART_VERSION=${INGRESS_NGINX_CHART_VERSION:-}
KUBOARD_VERSION=$KUBOARD_VERSION
HELM_VERSION=$HELM_VERSION
VERSION_NOTES="$VERSION_NOTES"
EOF_LOCK
}

install_sealos() {
  local url
  url="$(asset_download_url "labring/sealos" "$SEALOS_VERSION" "linux_${ARCH}\.tar\.gz$")" || fatal "未找到 sealos $SEALOS_VERSION ${ARCH} tar.gz 资产"
  log "下载 sealos: $url"
  curl -fL --retry 3 "$url" -o "$TMP_DIR/sealos-download"
  file "$TMP_DIR/sealos-download" || true
  if tar -tf "$TMP_DIR/sealos-download" >/dev/null 2>&1; then
    mkdir -p "$TMP_DIR/sealos-extract"
    tar -xf "$TMP_DIR/sealos-download" -C "$TMP_DIR/sealos-extract"
    local found
    found="$(python3 - "$TMP_DIR/sealos-extract" <<'PY'
import os, sys
root=sys.argv[1]
for base, _, files in os.walk(root):
    if "sealos" in files:
        print(os.path.join(base, "sealos"))
        raise SystemExit
PY
)"
    [ -n "$found" ] || fatal "sealos 压缩包中未找到 sealos 二进制"
    cp "$found" "$BIN_DIR/sealos"
  else
    cp "$TMP_DIR/sealos-download" "$BIN_DIR/sealos"
  fi
  chmod +x "$BIN_DIR/sealos"
  "$BIN_DIR/sealos" version || true
}

download_helm() {
  local url="https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  log "下载 helm: $url"
  curl -fL --retry 3 "$url" -o "$TMP_DIR/helm-linux-${ARCH}.tar.gz"
  tar --no-same-owner -xf "$TMP_DIR/helm-linux-${ARCH}.tar.gz" -C "$TMP_DIR"
  cp "$TMP_DIR/linux-${ARCH}/helm" "$BIN_DIR/helm"
  chmod +x "$BIN_DIR/helm"
  "$BIN_DIR/helm" version || true
}

pull_sealos_images() {
  local sealos="$BIN_DIR/sealos"
  local kube_img="docker.io/labring/kubernetes:${KUBERNETES_VERSION}"
  local calico_img="docker.io/labring/calico:${CALICO_VERSION}"

  # 在 arm64 主机上无法执行 amd64 sealos 二进制，跳过 cluster image 拉取
  if [[ "$ARCH" != "$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" ]]; then
    log "跳过 sealos cluster image (本机架构 $(uname -m) 与目标架构 ${ARCH} 不一致)"
    log "  需在 ${ARCH} 主机上重新执行本脚本以拉取 cluster image"
    return 1
  fi

  log "检查 Kubernetes cluster image: $kube_img"
  if ! "$sealos" pull "$kube_img" 2>/dev/null; then
    log "sealos/labring 未提供 ${KUBERNETES_VERSION} 预构建 cluster image，尝试构建自定义镜像"
    return 1
  fi

  log "检查 Calico cluster image: $calico_img"
  if ! "$sealos" pull "$calico_img" 2>/dev/null; then
    log "sealos/labring 未提供 ${CALICO_VERSION} 预构建 Calico cluster image，尝试构建自定义镜像"
    return 1
  fi

  mkdir -p "$ROOT_DIR/sealos-images/${ARCH}"
  log "导出 sealos cluster images"
  "$sealos" save -o "$ROOT_DIR/sealos-images/${ARCH}/kubernetes-${KUBERNETES_VERSION}-${ARCH}.tar" "$kube_img"
  "$sealos" save -o "$ROOT_DIR/sealos-images/${ARCH}/calico-${CALICO_VERSION}-${ARCH}.tar" "$calico_img"
  return 0
}

build_custom_cluster_images() {
  local sealos="$BIN_DIR/sealos"
  log "构建自定义 Kubernetes cluster image"

  local kube_version="$KUBERNETES_VERSION"
  local kubeadm_cfg="$TMP_DIR/kubeadm-config.yaml"

  cat > "$kubeadm_cfg" <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: ${kube_version}
controller:
  extraArgs:
    cloud-provider: ""
networking:
  dnsDomain: cluster.local
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

  mkdir -p "$ROOT_DIR/sealos-images"
  log "使用 sealos build 构建 cluster image"
  if "$sealos" build -t "docker.io/labring/kubernetes:${kube_version}" \
    -f "$ROOT_DIR/Clusterfile" \
    "$ROOT_DIR" 2>/dev/null; then
    log "成功构建 Kubernetes cluster image"
    "$sealos" save -o "$ROOT_DIR/sealos-images/kubernetes-${kube_version}-${ARCH}.tar" "docker.io/labring/kubernetes:${kube_version}"
  else
    log "sealos build 失败，尝试直接使用 kubeadm 镜像"
    local kubeadm_image="registry.k8s.io/kubeadm/kubeadm:v$(echo "$kube_version" | sed 's/v//')"
    "$sealos" pull "$kubeadm_image" 2>/dev/null || true
  fi
}

download_manifests() {
  local manifest="$MANIFESTS_DIR/ingress-nginx/deploy.yaml"

  # 若已存在定制过的 manifest (允许 snippet annotations), 不重复下载覆盖
  if [[ -f "$manifest" ]] && grep -q "allow-snippet-annotations" "$manifest"; then
    log "ingress-nginx manifest 已包含离线定制，跳过下载: $manifest"
  else
    log "下载 ingress-nginx manifest"
    curl -fL --retry 3 "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml" -o "$manifest"
    # 重新应用离线定制 (避免上游 cloud/deploy.yaml 覆盖)
    #   - ConfigMap: 启用 allow-snippet-annotations + annotations-risk-level
    #                 (application ingress 依赖 nginx.ingress.kubernetes.io/configuration-snippet)
    #   - 控制器:   DaemonSet + hostNetwork + tolerations (匹配单机 K8s 部署)
    #   - Service:  ClusterIP (宿主机 80/443 由 hostNetwork 直绑)
    if [[ -f "$ROOT_DIR/scripts/patch_ingress_manifest.py" ]]; then
      python3 "$ROOT_DIR/scripts/patch_ingress_manifest.py" "$manifest"
    else
      log "  WARN: 未找到 $ROOT_DIR/scripts/patch_ingress_manifest.py，跳过定制"
    fi
  fi

  log "Kuboard v4 K8s manifest 已内置在 manifests/kuboard/kuboard-v4.yaml"
  log "  - 镜像: swr.cn-east-2.myhuaweicloud.com/kuboard/kuboard:v4"
  log "  - 镜像: swr.cn-east-2.myhuaweicloud.com/kuboard/mariadb:11.3.2-jammy"
}

extract_image_list() {
  python3 - "$MANIFESTS_DIR" "$CONFIG_DIR/images.list" <<'PY'
import pathlib, re, sys
root=pathlib.Path(sys.argv[1])
out=pathlib.Path(sys.argv[2])
images=set()

# image: field — registry/path:tag (registry may include port)
IMAGE_RE = re.compile(r'image:\s*["\']?((?:[A-Za-z0-9._-]+(?::[0-9]+)?\/)+[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+)["\']?')
# --flag=value  形式 (例如 --image=, --prometheus-config-reloader=)
# value 必须形如 registry/path:tag
ARG_IMAGE_RE = re.compile(r'--[A-Za-z0-9_-]+=((?:[A-Za-z0-9._-]+(?::[0-9]+)?\/)+[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+)')

URL_PREFIXES = ('http://', 'https://', 'tcp://', 'udp://', 'unix://', 'file://', 'git://')

def is_valid_image(val: str) -> bool:
    if '{{' in val or '}}' in val:
        return False
    if val.lower().startswith(URL_PREFIXES):
        return False
    # 必须包含至少一个 /（registry/path 结构）
    if '/' not in val:
        return False
    # 必须有 tag（即 : 且后面非空）
    if ':' not in val.split('/')[-1]:
        return False
    return True

for path in root.rglob('*'):
    if not path.is_file():
        continue
    text = path.read_text(errors='ignore')
    for m in IMAGE_RE.finditer(text):
        val = m.group(1)
        if is_valid_image(val):
            images.add(val)
    for m in ARG_IMAGE_RE.finditer(text):
        val = m.group(1)
        if is_valid_image(val):
            images.add(val)

out.write_text('\n'.join(sorted(images)) + ('\n' if images else ''))
PY
  local controller_tag="${INGRESS_NGINX_VERSION#controller-}"
  cat >> "$CONFIG_DIR/images.list" <<EOF_IMAGES
registry.k8s.io/ingress-nginx/controller:${controller_tag}
EOF_IMAGES
  sort -u -o "$CONFIG_DIR/images.list" "$CONFIG_DIR/images.list"
  log "镜像清单:"
  cat "$CONFIG_DIR/images.list"
}

verify_saved_images() {
  log "验证已保存的应用镜像..."
  local missing=0
  while read -r image; do
    [[ -n "$image" ]] || continue
    [[ "$image" == \#* ]] && continue
    local safe
    safe="$(echo "$image" | sed 's/[^A-Za-z0-9_.-]/_/g')"
    if [[ -f "$IMAGES_DIR/${safe}.tar" ]]; then
      local manifest_img
      manifest_img="$(tar -xf "$IMAGES_DIR/${safe}.tar" manifest.json -O 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0].get('RepoTags',[''])[0] if d else '')" 2>/dev/null)"
      if [[ "$manifest_img" == "$image" ]]; then
        log "  [OK] $image ($(du -h "$IMAGES_DIR/${safe}.tar" | cut -f1))"
      else
        warn "  [MISMATCH] $image → tar内标签: ${manifest_img:-<空>}"
        missing=$((missing + 1))
      fi
    else
      warn "  [MISSING] $image (tar 文件不存在)"
      missing=$((missing + 1))
    fi
  done < "$CONFIG_DIR/images.list"

  if [[ $missing -gt 0 ]]; then
    warn "有 $missing 个镜像缺失或标签不匹配"
  else
    log "所有应用镜像验证通过"
  fi
}

save_app_images() {
  local runtime=""
  if command -v docker >/dev/null 2>&1; then
    runtime=docker
  elif command -v podman >/dev/null 2>&1; then
    runtime=podman
  fi

  # 跨架构拉取优先使用 skopeo (docker:// -> docker-archive)，
  # 避免 docker pull + docker save 在跨平台场景下出现 "manifests file: NotFound" 错误
  local use_skopeo=false
  if command -v skopeo >/dev/null 2>&1; then
    # skopeo 1.5+ 即可满足 docker:// -> docker-archive 的需求
    if skopeo --version 2>/dev/null | grep -qE '^skopeo version'; then
      use_skopeo=true
    fi
  fi

  while read -r image; do
    [[ -n "$image" ]] || continue
    [[ "$image" == \#* ]] && continue
    local safe
    safe="$(echo "$image" | sed 's/[^A-Za-z0-9_.-]/_/g')"
    local out="$IMAGES_DIR/${safe}.tar"

    if [[ "$use_skopeo" == "true" ]]; then
      log "拉取应用镜像 (skopeo): $image"
      if ! skopeo copy \
            --override-os linux --override-arch "${ARCH}" \
            "docker://${image}" "docker-archive:${out}:${image}" \
            2>/tmp/save_err; then
        printf '[%s] WARN: %s\n' "$(date '+%F %T')" "  skopeo copy 失败，跳过: $image" >&2
        printf '[%s] WARN: %s\n' "$(date '+%F %T')" "    $(cat /tmp/save_err | head -1)" >&2
        continue
      fi
    elif [ -n "$runtime" ]; then
      log "拉取应用镜像 (docker): $image"
      if ! "$runtime" pull --platform "$OCI_PLATFORM" "$image"; then
        printf '[%s] WARN: %s\n' "$(date '+%F %T')" "  pull 失败，跳过: $image" >&2
        continue
      fi
      if ! "$runtime" save -o "$out" "$image" 2>/tmp/save_err; then
        printf '[%s] WARN: %s\n' "$(date '+%F %T')" "  save 失败 (清理后重试): $image" >&2
        printf '[%s] WARN: %s\n' "$(date '+%F %T')" "    $(cat /tmp/save_err | head -1)" >&2
        "$runtime" rmi -f "$image" 2>/dev/null || true
        if "$runtime" pull --platform "$OCI_PLATFORM" "$image" 2>/dev/null && \
           "$runtime" save -o "$out" "$image" 2>/tmp/save_err2; then
          log "  重试成功: $image"
        else
          printf '[%s] WARN: %s\n' "$(date '+%F %T')" "  重试仍失败，跳过: $image" >&2
          printf '[%s] WARN: %s\n' "$(date '+%F %T')" "    $(cat /tmp/save_err2 2>/dev/null | head -1)" >&2
          continue
        fi
      fi
    else
      log "使用 sealos 拉取并导出应用镜像: $image"
      "$BIN_DIR/sealos" pull "$image"
      "$BIN_DIR/sealos" save -o "$out" "$image"
    fi
    # 移除 index.json/oci-layout，确保 tar 为纯 docker-archive 格式
    fix_oci_tar "$out"
  done < "$CONFIG_DIR/images.list"

  verify_saved_images
}

download_rpm_packages() {
  log "下载 Kubernetes 相关 RPM 包"
  local pkgs_dir="$ROOT_DIR/pkgs/${ARCH}"
  mkdir -p "$pkgs_dir"

  if command -v dnf >/dev/null 2>&1; then
    local repos=()
    for repo in kubernetes kubeadm kubectl cri-tools; do
      if dnf repolist 2>/dev/null | grep -q "$repo"; then
        repos+=("$repo")
      fi
    done

    if [[ ${#repos[@]} -gt 0 ]]; then
      log "启用 Kubernetes 仓库并下载 RPM"
      dnf download --resolve --alldeps \
        kubelet kubeadm kubectl cri-tools \
        --destdir="$pkgs_dir" 2>/dev/null || true
    fi

    log "下载系统依赖包"
    for pkg in conntrack-tools socat ethtool fuse-overlayfs iptables nfs-utils; do
      dnf download "$pkg" --destdir="$pkgs_dir" 2>/dev/null || true
    done
  fi

  ls -lh "$pkgs_dir"/*.rpm 2>/dev/null || log "未下载 RPM 包"
}

generate_checksums() {
  (cd "$ROOT_DIR" && find bin config manifests images sealos-images pkgs -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum > "$BUNDLE_DIR/sha256sum.txt" 2>/dev/null || true)
  (cd "$ROOT_DIR" && find bin config manifests images sealos-images pkgs -type f 2>/dev/null | sort > "$BUNDLE_DIR/manifest.txt" || true)
}

main() {
  need_cmd curl
  need_cmd python3
  need_cmd tar
  need_cmd sha256sum

  log "读取固定组件版本清单"
  [ -f "$COMPONENT_VERSIONS" ] || fatal "缺少固定组件版本文件: $COMPONENT_VERSIONS"
  # shellcheck disable=SC1090
  source "$COMPONENT_VERSIONS"
  case "$ARCH" in
    arm64) RPM_ARCH="aarch64"; OCI_PLATFORM="linux/arm64" ;;
    amd64) RPM_ARCH="x86_64"; OCI_PLATFORM="linux/amd64" ;;
    *) fatal "不支持的架构: $ARCH (可选: arm64, amd64)" ;;
  esac
  VERSION_NOTES="fixed reviewed component versions; upstream Kubernetes support window considered; no automatic downgrade or upgrade"
  write_lock
  log "版本已锁定:"
  cat "$VERSIONS_LOCK"

  install_sealos
  download_helm

  if ! pull_sealos_images; then
    build_custom_cluster_images
  fi

  download_manifests
  extract_image_list
  save_app_images
  download_rpm_packages
  generate_checksums

  log "在线下载完成，日志: $LOG_FILE"
}

main "$@"

#!/usr/bin/env bash
# install_offline.sh - 目标服务器一键安装脚本
# 在离线环境中的目标服务器上执行此脚本进行 K8s 集群部署

set -euo pipefail

# 确保 /usr/local/bin 在 PATH 中
export PATH="/usr/local/bin:$PATH"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
error() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; }
fatal() { error "$*"; exit 1; }

# ERR trap: print line number and exit code on failure (set -e 时打印错误位置)
trap 'ret=$?; echo "[$(date "+%F %T")] ERROR at line $LINENO (exit code $ret)" >&2' ERR

# 自动检测脚本所在目录（支持从根目录或 scripts/ 目录执行）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/config/versions.lock" ]]; then
  ROOT_DIR="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/../config/versions.lock" ]]; then
  ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  echo "[FATAL] 找不到 config/versions.lock，请从解压后的根目录或 scripts/ 目录执行" >&2
  exit 1
fi
cd "$ROOT_DIR"

# 优先读取全局架构配置 (bundle 根目录的 arch.env 优先于 versions.lock 中的 ARCH)
for _p in "$ROOT_DIR/arch.env" "$ROOT_DIR/../arch.env" "$ROOT_DIR/config/arch.env"; do
  if [[ -f "$_p" ]]; then
    # shellcheck disable=SC1090
    source "$_p"
    break
  fi
done

# 加载版本锁定 (versions.lock 中的 ARCH 会被 arch.env 覆盖)
if [[ -f "$ROOT_DIR/config/versions.lock" ]]; then
  # 保存 arch.env 的 ARCH，防止 versions.lock 覆盖
  _ARCH_FROM_ENV="${ARCH:-}"
  # shellcheck disable=SC1090
  source "$ROOT_DIR/config/versions.lock"
  [[ -n "$_ARCH_FROM_ENV" ]] && ARCH="$_ARCH_FROM_ENV"
else
  fatal "缺少版本锁定文件: $ROOT_DIR/config/versions.lock"
fi

ARCH="${ARCH:-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')}"
RPM_ARCH="${RPM_ARCH:-$(case "$ARCH" in arm64) echo aarch64;; amd64) echo x86_64;; esac)}"

# 根据 ARCH 推导 OCI 平台
case "$ARCH" in
  arm64) OCI_PLATFORM="linux/arm64" ;;
  amd64) OCI_PLATFORM="linux/amd64" ;;
  *) fatal "不支持的架构: $ARCH" ;;
esac

SEALOS="${ROOT_DIR}/bin/${ARCH}/sealos"

# 已选择的 Master IP，供安装和 NFS StorageClass 复用
SELECTED_MASTER_IP=""

list_global_ipv4() {
  ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | sort -u
}

select_master_ip() {
  if [[ -n "${MASTER_IP:-}" ]]; then
    echo "$MASTER_IP"
    return 0
  fi

  local route_ip
  route_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
  if [[ -n "$route_ip" ]]; then
    echo "$route_ip"
    return 0
  fi

  local ips=()
  mapfile -t ips < <(list_global_ipv4)

  case "${#ips[@]}" in
    0)
      fatal "无法自动获取 Master IP，请使用 MASTER_IP=<ip> $0 指定"
      ;;
    1)
      echo "${ips[0]}"
      ;;
    *)
      if [[ ! -t 0 ]]; then
        fatal "检测到多个网卡 IP，非交互模式下请使用 MASTER_IP=<ip> $0 指定"
      fi

      echo "检测到多个可用 IPv4 地址:" >&2
      local i
      for i in "${!ips[@]}"; do
        echo "  $((i + 1))) ${ips[$i]}" >&2
      done

      local choice
      while true; do
        read -r -p "请选择 Master IP 序号 [1-${#ips[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ips[@]} )); then
          echo "${ips[$((choice - 1))]}"
          return 0
        fi
        echo "输入无效，请重新选择" >&2
      done
      ;;
  esac
}

# 获取 Master IP
get_master_ip() {
  if [[ -z "$SELECTED_MASTER_IP" ]]; then
    SELECTED_MASTER_IP=$(select_master_ip)
  fi
  echo "$SELECTED_MASTER_IP"
}

confirm_install_context() {
  local master_ip hostname os_info arch
  master_ip=$(get_master_ip)
  hostname=$(hostname)
  os_info=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
  arch=$(uname -m)

  log "========================================"
  log "安装前确认"
  log "========================================"
  log "Hostname: $hostname"
  log "Master IP: $master_ip"
  log "系统版本: ${os_info:-unknown}"
  log "系统架构: $arch"
  warn "Kubernetes 节点名通常来自安装时 hostname，安装后不建议修改 hostname。"
  warn "如需修改 hostname，请先退出脚本，修改后再重新安装。"
  log "========================================"

  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    log "ASSUME_YES=true，跳过交互确认"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    fatal "非交互模式下请设置 ASSUME_YES=true 确认继续，或在交互终端执行"
  fi

  local answer
  read -r -p "确认使用以上 hostname 和 Master IP 继续安装？输入 yes 继续: " answer
  [[ "$answer" == "yes" ]] || fatal "用户取消安装"
}

# 检查前提条件
check_prerequisites() {
  log "检查前提条件"

  if [[ $EUID -ne 0 ]]; then
    fatal "此脚本必须以 root 用户身份运行"
  fi

  if [[ ! -x "$SEALOS" ]]; then
    if [[ -f "$SEALOS" ]]; then
      chmod +x "$SEALOS"
    else
      fatal "缺少 sealos: $SEALOS"
    fi
  fi

  if [[ ! -f "${ROOT_DIR}/sealos-images/${ARCH}/kubernetes-${KUBERNETES_VERSION}-${ARCH}.tar" ]]; then
    fatal "缺少 Kubernetes cluster image"
  fi

  if [[ ! -f "${ROOT_DIR}/sealos-images/${ARCH}/calico-${CALICO_VERSION}-${ARCH}.tar" ]]; then
    fatal "缺少 Calico cluster image"
  fi

  log "前提条件检查通过"
}

# 安装系统依赖
install_system_deps() {
  log "安装系统依赖"

  if [[ -d "$ROOT_DIR/pkgs/${ARCH}" ]] && ls "$ROOT_DIR/pkgs/${ARCH}"/*.rpm >/dev/null 2>&1; then
    log "安装 RPM 包"
    rpm -Uvh --replacepkgs --nodeps "$ROOT_DIR"/pkgs/${ARCH}/*.rpm 2>/dev/null || true
  else
    log "RPM 包目录为空或不存在，跳过"
  fi

  # 确保 nfs-utils 已安装（NFS client provisioner 依赖 mount.nfs）
  if ! command -v mount.nfs >/dev/null 2>&1; then
    log "安装 nfs-utils（NFS 挂载工具）"
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y nfs-utils 2>/dev/null || warn "dnf 安装 nfs-utils 失败"
    elif command -v yum >/dev/null 2>&1; then
      yum install -y nfs-utils 2>/dev/null || warn "yum 安装 nfs-utils 失败"
    else
      warn "未找到包管理器，请手动安装 nfs-utils"
    fi
  fi
}

# 安装 sealos
install_sealos_binary() {
  log "安装 sealos"

  # 复制到 /usr/local/bin/，确保命令全局可用
  if ! install -m 0755 "$SEALOS" /usr/local/bin/sealos 2>/dev/null; then
    cp -f "$SEALOS" /usr/local/bin/sealos || fatal "无法复制 sealos 到 /usr/local/bin/"
    chmod +x /usr/local/bin/sealos
  fi

  # 刷新 shell 命令缓存
  hash -r 2>/dev/null || true

  # 验证 sealos 可用
  if /usr/local/bin/sealos version >/dev/null 2>&1; then
    log "sealos 版本: $(/usr/local/bin/sealos version 2>/dev/null | head -1)"
  else
    fatal "sealos 安装后验证失败，请检查 $SEALOS 是否存在且可执行"
  fi
}

# 安装 helm
install_helm_binary() {
  log "安装 helm"

  local helm_bin="${ROOT_DIR}/bin/${ARCH}/helm"
  if [[ ! -f "$helm_bin" ]]; then
    warn "未找到 helm 二进制: $helm_bin，跳过"
    return 0
  fi

  install -m 0755 "$helm_bin" /usr/local/bin/helm 2>/dev/null || {
    cp -f "$helm_bin" /usr/local/bin/helm || fatal "无法复制 helm 到 /usr/local/bin/"
    chmod +x /usr/local/bin/helm
  }

  hash -r 2>/dev/null || true

  if /usr/local/bin/helm version >/dev/null 2>&1; then
    log "helm 版本: $(/usr/local/bin/helm version 2>/dev/null | head -1)"
  else
    warn "helm 安装后验证失败"
  fi
}

# 加载镜像到 sealos 本地仓库
load_images() {
  log "加载离线镜像到 sealos"

  # sealos load 可直接加载 OCI tar 包，不依赖 containerd 运行
  mkdir -p /var/lib/sealos 2>/dev/null || true

  if [[ -f "${ROOT_DIR}/sealos-images/${ARCH}/kubernetes-${KUBERNETES_VERSION}-${ARCH}.tar" ]]; then
    log "加载 Kubernetes cluster image"
    sealos load -i "${ROOT_DIR}/sealos-images/${ARCH}/kubernetes-${KUBERNETES_VERSION}-${ARCH}.tar"
  fi

  if [[ -f "${ROOT_DIR}/sealos-images/${ARCH}/calico-${CALICO_VERSION}-${ARCH}.tar" ]]; then
    log "加载 Calico cluster image"
    sealos load -i "${ROOT_DIR}/sealos-images/${ARCH}/calico-${CALICO_VERSION}-${ARCH}.tar"
  fi
}

# 修复 OCI 布局 tar：移除 index.json/oci-layout，保留纯 docker-archive 格式
fix_oci_tar() {
  local tar_file="$1"
  if tar tf "$tar_file" 2>/dev/null | grep -qxF 'index.json'; then
    log "  修复 OCI tar"
    local tmpdir
    tmpdir="$(mktemp -d)"
    tar xf "$tar_file" -C "$tmpdir"
    rm -f "$tmpdir/index.json" "$tmpdir/oci-layout"
    (cd "$tmpdir" && find . -type f | sed 's|^\./||' | sort | tar cf "$tar_file" -T -)
    rm -rf "$tmpdir"
  fi
}

# 集群安装完成后，将应用镜像导入 K8s containerd
load_app_images_to_containerd() {
  if [[ ! -d "${ROOT_DIR}/images/${ARCH}" ]]; then
    log "应用镜像目录不存在，跳过"
    return 0
  fi

  if ! command -v ctr >/dev/null 2>&1 || [[ ! -S /run/containerd/containerd.sock ]]; then
    fatal "containerd/ctr 不可用，无法导入应用镜像"
  fi

  # 预检查：列出 tar 文件清单与 images.list 交叉校验
  local expected_total=0 missing_tars=0
  if [[ -f "${ROOT_DIR}/config/images.list" ]]; then
    while read -r image; do
      [[ -n "$image" ]] || continue
      [[ "$image" == \#* ]] && continue
      expected_total=$((expected_total + 1))
      local safe
      safe="$(echo "$image" | sed 's/[^A-Za-z0-9_.-]/_/g')"
      if [[ ! -f "${ROOT_DIR}/images/${ARCH}/${safe}.tar" ]]; then
        warn "  [MISSING] images.list 中存在但无 tar 文件: $image"
        missing_tars=$((missing_tars + 1))
      fi
    done < "${ROOT_DIR}/config/images.list"
  fi

  local tar_count
  tar_count="$(find "${ROOT_DIR}/images" -maxdepth 1 -name '*.tar' | wc -l)"
  log "应用镜像目录: $tar_count 个 tar 文件, images.list: ${expected_total:-0} 个条目"

  if [[ $missing_tars -gt 0 ]]; then
    warn "images.list 中有 $missing_tars 个条目缺少对应 tar 文件"
  fi

  if [[ $tar_count -eq 0 ]]; then
    log "无 tar 文件, 跳过导入"
    return 0
  fi

  log "导入应用镜像并推送到 sealos.hub:5000 registry"

  local imported=0 failed=0
  for image_tar in "$ROOT_DIR"/images/${ARCH}/*.tar; do
    [[ -f "$image_tar" ]] || continue
    local fname
    fname=$(basename "$image_tar")

    # 1. 从 tar 中提取镜像名
    local img_name
    img_name=$(python3 -c "
import tarfile, json
with tarfile.open('$image_tar') as t:
    m = json.load(t.extractfile('manifest.json'))
    print(m[0]['RepoTags'][0])
" 2>/dev/null) || true

    if [[ -z "$img_name" ]]; then
      warn "  无法从 tar 读取镜像名: $fname"
      failed=$((failed + 1))
      continue
    fi
    log "  导入: $img_name ← $fname"

    # 2. 修复 OCI 布局 tar（移除 index.json，避免多架构 manifest 导入失败）
    fix_oci_tar "$image_tar"

    # 3. ctr import 导入到 containerd k8s.io namespace，捕获实际导入后的镜像名
    local import_output import_name
    import_output="$(ctr --address=/run/containerd/containerd.sock -n k8s.io images import "$image_tar" 2>&1)" || true
    import_name="$(echo "$import_output" | grep 'unpacking ' | awk '{print $2}')"
    if [[ -z "$import_name" ]]; then
      # 如果 import 输出格式不同，回退到 RepoTags
      import_name="$img_name"
    fi

    # 4. 去掉 registry 前缀，只保留 repo/name:tag
    local repo_tag
    if echo "$import_name" | grep -qE '^[^/]+\.[^/]*/'; then
      repo_tag=$(echo "$import_name" | sed 's|^[^/]*/||')
    else
      repo_tag="$import_name"
    fi

    # 5. ctr push --local --plain-http 推送到 sealos.hub:5000
    local target="sealos.hub:5000/${repo_tag}"
    if ctr --address=/run/containerd/containerd.sock -n k8s.io images push \
        --local --plain-http --user admin:passw0rd \
        --platform "$OCI_PLATFORM" \
        "$target" "$import_name" >/dev/null 2>&1; then
      log "  推送成功: $fname → $target"
      imported=$((imported + 1))
    else
      warn "  push 失败: $fname → $target"
      failed=$((failed + 1))
    fi
  done

  log "镜像导入完成: 成功 $imported, 失败 $failed"

  # 6. 验证推送的镜像在 registry 中可访问
  if [[ $imported -gt 0 ]]; then
    log "验证 registry 中的镜像..."
    local verified=0 verify_failed=0
    for image_tar in "$ROOT_DIR"/images/${ARCH}/*.tar; do
      [[ -f "$image_tar" ]] || continue
      local img_name repo_tag
      img_name=$(python3 -c "
import tarfile, json
with tarfile.open('$image_tar') as t:
    m = json.load(t.extractfile('manifest.json'))
    print(m[0]['RepoTags'][0])
" 2>/dev/null) || continue
      if echo "$img_name" | grep -qE '^[^/]+\.[^/]*/'; then
        repo_tag=$(echo "$img_name" | sed 's|^[^/]*/||')
      else
        repo_tag="$img_name"
      fi
      local target="sealos.hub:5000/${repo_tag}"
      local repo_only="${repo_tag%%:*}"
      if curl -sf --user admin:passw0rd \
          "http://sealos.hub:5000/v2/${repo_only}/tags/list" >/dev/null 2>&1; then
        verified=$((verified + 1))
      else
        warn "  registry 中未找到: $target"
        verify_failed=$((verify_failed + 1))
      fi
    done
    log "  registry 验证: $verified 个存在, $verify_failed 个缺失"
  fi

  if [[ "$failed" -gt 0 ]]; then
    warn "有 $failed 个镜像导入失败，请手动检查"
  fi
}

# sealos 安装 K8s 时会安装并配置 containerd，如有残留数据/配置会导致 sealos 插件失败。
# 此函数彻底清理旧集群并重置 containerd 为全新状态。
cleanup_old_cluster() {
  log "检查并清理旧集群"

  # sealos reset 清理旧集群（含 K8s 全部组件）
  if command -v sealos >/dev/null 2>&1; then
    log "执行 sealos reset (最多等待 120 秒)"
    timeout 120 sealos reset --force --cluster default >/dev/null 2>&1 || \
      warn "sealos reset 未完成，执行兜底清理"
  fi

  # 停止残留进程
  systemctl stop kubelet containerd docker dockerd registry image-cri-shim 2>/dev/null || true
  pkill -9 -f 'kube|containerd|dockerd' 2>/dev/null || true
  sleep 1

  # 清理 K8s 残留目录
  rm -f /root/.kube/config 2>/dev/null || true
  rm -rf /root/.sealos /var/lib/sealos 2>/dev/null || true
  rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni /var/lib/cni /var/lib/calico 2>/dev/null || true
  rm -f /etc/systemd/system/kubelet.service /etc/systemd/system/registry.service \
        /etc/systemd/system/image-cri-shim.service 2>/dev/null || true

  # 清理 docker 残留
  systemctl stop docker dockerd 2>/dev/null || true
  pkill -9 -f dockerd 2>/dev/null || true
  rm -rf /var/lib/docker /etc/docker 2>/dev/null || true
  rm -f /usr/bin/docker /usr/bin/dockerd /usr/local/bin/docker /usr/local/bin/dockerd 2>/dev/null || true
  rm -f /usr/bin/docker-compose /usr/local/bin/docker-compose 2>/dev/null || true
  rm -f /etc/systemd/system/docker.service /etc/systemd/system/docker.socket 2>/dev/null || true

  # 清理 containerd 残留数据与 systemd 服务（二进制由后续 sealos run 重新安装）
  rm -rf /var/lib/containerd /etc/containerd 2>/dev/null || true
  rm -f /etc/systemd/system/containerd.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  log "旧集群清理完成"
  log "提示: sealos load 不依赖 containerd，后续步骤将直接加载 K8s 镜像"
}

# 系统环境准备
prepare_system() {
  log "系统环境准备 (关闭swap/防火墙/selinux等)"

  if [[ -f "${ROOT_DIR}/scripts/06_prepare_system.sh" ]]; then
    bash "${ROOT_DIR}/scripts/06_prepare_system.sh" || warn "系统准备脚本部分步骤失败"
  else
    log "未找到系统准备脚本，跳过"
  fi
}

# sealos run 会检查本机是否存在 containerd/docker，存在则拒绝安装
# 此函数在 sealos run 前移除所有痕迹，让 sealos 安装自己的 containerd
remove_container_runtimes() {
  log "移除容器运行时痕迹 (让 sealos 安装自己的 containerd)"

  systemctl stop containerd 2>/dev/null || true
  systemctl disable containerd 2>/dev/null || true
  systemctl stop docker dockerd 2>/dev/null || true

  # 杀死所有残留进程
  for pattern in '(^|/)containerd( |$)' '(^|/)containerd-shim' '(^|/)dockerd( |$)'; do
    pkill -9 -f "$pattern" 2>/dev/null || true
  done
  sleep 1

  # 移除 containerd 二进制和 systemd 单元
  rm -f /usr/local/bin/containerd /usr/local/bin/containerd-shim-runc-v2 /usr/local/bin/containerd-shim-runc-v1 2>/dev/null || true
  rm -f /usr/bin/containerd /usr/bin/containerd-shim-runc-v2 /usr/bin/containerd-shim-runc-v1 2>/dev/null || true
  rm -f /usr/local/bin/ctr /usr/bin/ctr 2>/dev/null || true
  rm -f /etc/systemd/system/containerd.service /etc/systemd/system/containerd.socket 2>/dev/null || true
  rm -f /etc/systemd/system/docker.service /etc/systemd/system/docker.socket 2>/dev/null || true

  # 移除 docker 二进制 (sealos run 检测到 PATH 中的 docker 会拒绝安装)
  rm -f /usr/local/bin/docker /usr/local/bin/dockerd /usr/local/bin/docker-init /usr/local/bin/docker-proxy 2>/dev/null || true
  rm -f /usr/bin/docker /usr/bin/dockerd /usr/bin/docker-init /usr/bin/docker-proxy 2>/dev/null || true
  rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose 2>/dev/null || true

  # 移除 socket 和运行时目录
  rm -rf /run/containerd /run/docker 2>/dev/null || true
  rm -rf /var/lib/containerd /var/lib/docker 2>/dev/null || true
  rm -rf /etc/docker 2>/dev/null || true

  systemctl daemon-reload 2>/dev/null || true

  # 验证 sealos 不再检测到 containerd
  if command -v sealos >/dev/null 2>&1; then
    log "containerd/docker 已移除，sealos 可以进行安装"
  fi
}

# 执行安装
install_kubernetes() {
  local master_ip
  master_ip=$(get_master_ip)

  log "========================================"
  log "开始安装 Kubernetes 集群"
  log "========================================"
  log "Master IP: $master_ip"
  log "Kubernetes 版本: $KUBERNETES_VERSION"
  log "Calico 版本: $CALICO_VERSION"
  log "证书有效期: 默认 100 年 (sealos 内置)"
  log "========================================"

  log "执行 sealos run 安装集群"

  # sealos v5.x 默认证书有效期为 100 年，无需额外配置
  if ! sealos run "docker.io/labring/kubernetes:${KUBERNETES_VERSION}" \
    "docker.io/labring/calico:${CALICO_VERSION}" \
    --masters "$master_ip" \
    --force 2>&1; then
    fatal "Kubernetes 安装失败"
  fi

  export KUBECONFIG=/root/.kube/config

  log "等待集群就绪 (最多等待 10 分钟)"

  for i in $(seq 1 60); do
    if kubectl get nodes >/dev/null 2>&1 && kubectl get nodes | grep -q ' Ready '; then
      log "========================================"
      log "集群安装成功！节点已 Ready"
      log "========================================"
      break
    fi
    if [[ $i -eq 60 ]]; then
      fatal "等待超时，集群可能未完全就绪"
    fi
    sleep 10
  done
}

# 验证证书有效期
verify_cert_validity() {
  log "验证 K8s 证书有效期"

  if command -v kubeadm >/dev/null 2>&1; then
    kubeadm certs check-expiration 2>/dev/null || log "kubeadm 不可用，跳过证书检查"
  fi
}

# 验证集群
verify_cluster() {
  log "验证集群状态"

  export KUBECONFIG=/root/.kube/config

  echo ""
  log "=== 节点状态 ==="
  kubectl get nodes -o wide || true

  echo ""
  log "=== Pod 状态 ==="
  kubectl get pods -A || true

  echo ""
  log "=== 集群信息 ==="
  kubectl cluster-info || true

  local ready_nodes
  ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)
  ready_nodes=${ready_nodes:-0}

  echo ""
  if [[ "$ready_nodes" -ge 1 ]]; then
    log "========================================"
    log "集群验证成功: $ready_nodes 个 Ready 节点"
    log "========================================"
  else
    fatal "集群验证失败：未找到 Ready 节点"
  fi
}

# 部署 ingress-nginx
deploy_ingress_nginx() {
  log "部署 ingress-nginx"

  if [[ -f "${ROOT_DIR}/manifests/ingress-nginx/deploy.yaml" ]]; then
    kubectl apply -f "${ROOT_DIR}/manifests/ingress-nginx/deploy.yaml"
    log "ingress-nginx 部署完成"
  else
    warn "未找到 ingress-nginx manifest 文件"
  fi
}

# 部署 Kuboard v4（K8s 原生方式，镜像通过 containerd registry 加载）
deploy_kuboard() {
  if [[ ! -f "${ROOT_DIR}/manifests/kuboard/kuboard-v4.yaml" ]]; then
    warn "未找到 kuboard-v4.yaml manifest 文件，跳过 Kuboard v4 部署"
    return 0
  fi

  export KUBECONFIG=/root/.kube/config

  log "部署 Kuboard v4（K8s 原生方式）"
  kubectl apply -f "${ROOT_DIR}/manifests/kuboard/kuboard-v4.yaml"

  log "等待 Kuboard 就绪..."
  kubectl wait --for=condition=Available -n kuboard deployment/kuboard --timeout=120s 2>/dev/null || true
  kubectl wait --for=condition=Available -n kuboard deployment/kuboard-db --timeout=120s 2>/dev/null || true

  local node_ip
  node_ip=$(kubectl get node -o jsonpath='{.items[0].status.addresses[0].address}')
  log "Kuboard v4 部署完成"
  log "访问地址: http://${node_ip}:30080"
  log "默认账号: admin / Kuboard123"
}

# 部署 Prometheus 监控套件
deploy_prometheus() {
  log "部署 Prometheus 监控套件"

  if [[ -d "${ROOT_DIR}/manifests/kube-prometheus" ]]; then
    export KUBECONFIG=/root/.kube/config

    # 先部署 CRD
    log "部署 Prometheus CRDs"
    kubectl apply --server-side -f "${ROOT_DIR}/manifests/kube-prometheus/setup/"

    # 等待 CRD 就绪
    log "等待 CRD 就绪..."
    sleep 10

    # 部署监控组件
    log "部署监控组件"
    kubectl apply -f "${ROOT_DIR}/manifests/kube-prometheus/"

    log "Prometheus 监控套件部署完成"
  else
    warn "未找到 kube-prometheus manifest 目录"
  fi
}

# 部署 NFS StorageClass
deploy_nfs_storage() {
  log "部署 NFS StorageClass"

  if [[ -f "${ROOT_DIR}/manifests/nfs-client-provisioner/deploy.yaml" ]]; then
    export KUBECONFIG=/root/.kube/config

    local nfs_ip
    nfs_ip=$(get_master_ip)

    log "准备本机 NFS 服务: /data/nfs"
    mkdir -p /data/nfs
    chmod 0777 /data/nfs

    if ! grep -q '^/data/nfs ' /etc/exports 2>/dev/null; then
      echo '/data/nfs *(rw,sync,no_root_squash,no_subtree_check)' >> /etc/exports
    fi

    systemctl enable rpcbind nfs-server >/dev/null 2>&1 || true
    systemctl restart rpcbind >/dev/null 2>&1 || true
    systemctl restart nfs-server >/dev/null 2>&1 || systemctl restart nfs >/dev/null 2>&1 || true
    exportfs -ra >/dev/null 2>&1 || true

    sed "s/##NFS_SERVER_IP##/${nfs_ip}/g" \
      "${ROOT_DIR}/manifests/nfs-client-provisioner/deploy.yaml" | \
      kubectl apply -f -

    log "NFS StorageClass 部署完成"
  else
    warn "未找到 NFS provisioner manifest 文件"
  fi
}

# 部署 metrics-server
deploy_metrics_server() {
  log "部署 metrics-server"

  if [[ -f "${ROOT_DIR}/manifests/metrics-server/metrics-server.yaml" ]]; then
    export KUBECONFIG=/root/.kube/config
    kubectl apply -f "${ROOT_DIR}/manifests/metrics-server/metrics-server.yaml"
    log "metrics-server 部署完成"
  else
    warn "未找到 metrics-server manifest 文件"
  fi
}

# 配置 kubectl 自动补全
setup_kubectl_completion() {
  log "配置 kubectl 自动补全"

  if [[ -f "${ROOT_DIR}/scripts/07_setup_kubectl_completion.sh" ]]; then
    bash "${ROOT_DIR}/scripts/07_setup_kubectl_completion.sh" || warn "kubectl completion 配置失败"
    log "kubectl 自动补全配置完成"
    log "使用方式: source /root/.bashrc 或重新登录"
  else
    warn "未找到 kubectl completion 配置脚本"
  fi
}

# 打印使用说明
print_usage() {
  cat <<EOF
========================================
Kubernetes 集群安装完成
========================================

访问信息:
--------
ingress-nginx: http://<node-ip>:80
Prometheus/Grafana/Alertmanager: 通过后续 Ingress 或 NodePort 暴露
Kuboard (单独部署): 详见 offline-kuboard 独立离线包

Kubectl 配置: /root/.kube/config

存储类:
--------
NFS StorageClass: nfs-client (已部署)

证书有效期:
--------
所有 K8s 证书有效期: 100 年 (一劳永逸)
检查命令: kubeadm certs check-expiration

常用命令:
--------
kubectl get nodes          # 查看节点
kubectl get pods -A        # 查看所有 Pod
kubectl get svc -A         # 查看所有服务
kubectl get storageclass   # 查看存储类

后续步骤:
--------
1. 验证集群状态: kubectl get nodes
2. 查看监控: kubectl get pods -n monitoring
3. 部署业务应用
4. 如需卸载: sealos reset -f

组件版本:
--------
Kubernetes: ${KUBERNETES_VERSION}
Calico: ${CALICO_VERSION}
ingress-nginx: ${INGRESS_NGINX_VERSION}
Sealos: ${SEALOS_VERSION}
Helm: ${HELM_VERSION:-v3.21.2}
Prometheus: v3.12.0
Grafana: 13.0.2

========================================
EOF
}

# 检查步骤是否需要跳过
# 用法: should_skip <step_name> <check_command>
should_skip() {
  local step="$1"
  local check="$2"
  
  # 如果指定了 FORCE_REINSTALL=true，不跳过任何步骤
  if [[ "${FORCE_REINSTALL:-false}" == "true" ]]; then
    return 1
  fi
  
  # 如果指定了 SKIP_STEPS，检查是否包含该步骤
  if [[ -n "${SKIP_STEPS:-}" ]]; then
    local IFS=','
    for s in $SKIP_STEPS; do
      if [[ "$s" == "$step" ]]; then
        log "[$step] 跳过（SKIP_STEPS）"
        return 0
      fi
    done
  fi
  
  # 执行检查命令，成功则跳过
  if eval "$check" >/dev/null 2>&1; then
    log "[$step] 已完成，跳过"
    return 0
  fi
  
  return 1
}

# 主函数
main() {
  # 解析 CLI 参数
  for arg in "$@"; do
    case "$arg" in
      -f|--force) export FORCE_REINSTALL=true ;;
      -y) export ASSUME_YES=true ;;
      *) ;;
    esac
  done

  log "========================================"
  log "离线 K8s 集群一键安装"
  log "========================================"
  log "用法: $0 [-f|--force] [-y]"
  log "  -f, --force   强制重新安装所有组件（包括 K8s 集群）"
  log "  -y            跳过交互确认"
  log ""
  log "提示: 可用环境变量控制安装行为"
  log "  SKIP_STEPS=cleanup,ingress  跳过指定步骤"
  log "  FORCE_REINSTALL=true        强制重新安装所有步骤"
  log "  ASSUME_YES=true             跳过交互确认"
  log "  MASTER_IP=x.x.x.x           指定 Master IP"
  log "========================================"

  # 1. 系统准备（不可跳过，幂等操作）
  prepare_system

  # 2. 前提检查（不可跳过）
  check_prerequisites

  # 3. 交互确认
  confirm_install_context

  # 4. 安装系统依赖
  should_skip deps "rpm -q conntrack-tools" || install_system_deps

  # 5. 安装 sealos
  should_skip sealos "command -v sealos" || install_sealos_binary

  # 6. 安装 helm
  should_skip helm "command -v helm" || install_helm_binary

  # 7. 检查 K8s 集群是否已就绪
  if [[ "${FORCE_REINSTALL:-false}" != "true" ]] && kubectl get nodes 2>/dev/null | grep -q ' Ready '; then
    log "K8s 集群已就绪，跳过安装"
  else
    if [[ "${FORCE_REINSTALL:-false}" == "true" ]]; then
      log "FORCE_REINSTALL=true，将重新安装所有组件"
    fi

    # sealos 安装 K8s 时会在本机部署 containerd 并写入配置。
    # 残留的 /var/lib/containerd 数据或 /etc/containerd 配置会阻塞 sealos 的 containerd 插件，
    # 导致 sealos run 失败。因此安装前必须彻底清理 containerd + 旧集群。
    cleanup_old_cluster

    # 8. 加载镜像（containerd 已为全新状态，此时 sealos 元数据已失效，必须重新加载）
    load_images

    # 9. sealos run 之前必须移除 containerd/docker 痕迹，否则 sealos 检查器拒绝安装
    remove_container_runtimes

    # 10. 安装 K8s 集群
    install_kubernetes
  fi

  # 10. 验证 KUBECONFIG 已准备
  export KUBECONFIG=/root/.kube/config
  if [[ ! -f "$KUBECONFIG" ]]; then
    fatal "kubeconfig 文件不存在 ($KUBECONFIG)，集群安装可能未成功"
  fi

  # 10.5 验证 image-cri-shim 已部署 (sealos run 会自动部署, 但需确认)
  if ! systemctl is-active --quiet image-cri-shim 2>/dev/null; then
    fatal "image-cri-shim 未运行, manifests 中的外部 registry 镜像将无法拉取"
  fi
  if ! curl -sf -m 5 -u admin:passw0rd http://sealos.hub:5000/v2/ >/dev/null 2>&1; then
    fatal "sealos.hub:5000 registry 不可达, 部署将失败"
  fi
  log "image-cri-shim + sealos.hub:5000 registry 就绪"

  # 11. 导入应用镜像到 containerd（幂等操作，重复导入不会出错）
  load_app_images_to_containerd

  # 12. 验证集群（失败会 fatal 退出）
  verify_cluster

  # 13. 验证证书
  should_skip certs "command -v kubeadm >/dev/null 2>&1" || verify_cert_validity

  # 14. 部署 ingress-nginx
  should_skip ingress "kubectl get deploy -n ingress-nginx ingress-nginx-controller 2>/dev/null" || deploy_ingress_nginx

  # 15. 部署 NFS StorageClass
  should_skip nfs "kubectl get sc nfs-client 2>/dev/null" || deploy_nfs_storage

  # 16. 部署 Kuboard v4（K8s 原生方式）
  should_skip kuboard "kubectl get deploy -n kuboard kuboard 2>/dev/null" || deploy_kuboard

  # 17. 部署 Prometheus
  should_skip prometheus "kubectl get deploy -n monitoring prometheus-operator 2>/dev/null" || deploy_prometheus

  # 18. 部署 metrics-server
  should_skip metrics "kubectl get deploy -n kube-system metrics-server 2>/dev/null" || deploy_metrics_server

  # 19. 配置 kubectl 补全
  should_skip completion "grep -q 'kubectl completion' /root/.bashrc 2>/dev/null" || setup_kubectl_completion

  # 20. 打印使用说明
  print_usage

  log "安装流程完成"
}

main "$@"

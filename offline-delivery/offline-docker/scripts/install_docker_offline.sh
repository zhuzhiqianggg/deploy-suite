#!/usr/bin/env bash
# install_docker_offline.sh - 独立 Docker 离线安装脚本
# 只负责 Docker Engine / Docker Compose，不包含数据库或 K8s 内容。

set -euo pipefail

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# 读取全局架构配置 (bundle 根目录 → 项目根目录 → 包内 config)
for _p in "$ROOT_DIR/arch.env" "$ROOT_DIR/../arch.env" "$ROOT_DIR/config/arch.env"; do
  if [[ -f "$_p" ]]; then source "$_p"; break; fi
done
ARCH="${ARCH:-arm64}"
case "$ARCH" in
  arm64) COMPOSE_ARCH="aarch64" ;;
  amd64) COMPOSE_ARCH="x86_64" ;;
  *) fatal "不支持的架构: $ARCH (可选: arm64, amd64)" ;;
esac

install_docker_binary() {
  log "安装 Docker 二进制"

  local docker_pkg=""
  docker_pkg=$(ls "$ROOT_DIR"/pkgs/${ARCH}/docker-*.tgz "$ROOT_DIR"/pkgs/${ARCH}/docker-*.tar 2>/dev/null | head -1 || true)
  [[ -n "$docker_pkg" ]] || fatal "未找到 Docker 安装包，请放到 $ROOT_DIR/pkgs/，例如 docker-29.6.0.tgz"

  rm -rf /tmp/docker-offline-install
  mkdir -p /tmp/docker-offline-install
  tar -xf "$docker_pkg" -C /tmp/docker-offline-install

  # K8s 节点已有 containerd（通常 v1.7.x），Docker tgz 中的 containerd v2.x
  # 会覆盖 K8s 版本导致 shim API 不兼容（unsupported shim version 3）。
  # 只安装 Docker 自身需要的二进制，跳过 containerd/ctr/shim/runc。
  local k8s_mode=false
  if systemctl is-active --quiet kubelet 2>/dev/null; then
    k8s_mode=true
    log "检测到 kubelet 运行中（K8s 节点），跳过 containerd 相关二进制安装"
  fi

  for f in /tmp/docker-offline-install/docker/*; do
    local base
    base=$(basename "$f")
    if [[ "$k8s_mode" == "true" ]]; then
      case "$base" in
        containerd|containerd-shim*|containerd-stress|ctr|runc)
          log "  跳过 $base（K8s 节点保留现有 containerd）"
          continue
          ;;
      esac
    fi
    install -m 0755 "$f" "/usr/local/bin/$base"
  done

  mkdir -p /etc/docker /var/lib/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "data-root": "/var/lib/docker",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "10"
  },
  "iptables": true,
  "ip-forward": true,
  "ip-masq": true
}
EOF

  # 清理旧版 BuildKit 缓存，避免 dockerd 29.x 启动失败
  if [[ -d /var/lib/docker/buildkit ]]; then
    warn "检测到旧版 BuildKit 缓存，清理中..."
    rm -rf /var/lib/docker/buildkit
  fi

  # 加载内核模块 (docker 创建 bridge 网络需要)
  modprobe br_netfilter 2>/dev/null || true
  echo "br_netfilter" > /etc/modules-load.d/docker.conf 2>/dev/null || true

  cat > /etc/systemd/system/docker.service <<'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service containerd.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutStartSec=0
RestartSec=2
Restart=always
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable docker
  systemctl restart docker

  # 等待 Docker daemon 就绪
  log "等待 Docker daemon 就绪..."
  for i in $(seq 1 15); do
    if docker info >/dev/null 2>&1; then
      log "Docker daemon 就绪"
      break
    fi
    if [[ $i -eq 15 ]]; then
      fatal "Docker daemon 启动超时，请检查 journalctl -u docker.service"
    fi
    sleep 2
  done

  docker version
}

install_compose() {
  log "安装 Docker Compose 插件"
  mkdir -p /usr/local/lib/docker/cli-plugins

  if [[ -f "$ROOT_DIR/bin/${ARCH}/docker-compose" ]]; then
    install -m 0755 "$ROOT_DIR/bin/${ARCH}/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose
  elif [[ -f "$ROOT_DIR/pkgs/${ARCH}/docker-compose-linux-${COMPOSE_ARCH}" ]]; then
    install -m 0755 "$ROOT_DIR/pkgs/${ARCH}/docker-compose-linux-${COMPOSE_ARCH}" /usr/local/lib/docker/cli-plugins/docker-compose
  else
    warn "未找到 docker-compose 二进制，跳过。请放到 $ROOT_DIR/bin/docker-compose"
    return 0
  fi

  docker compose version
}

install_buildx() {
  log "安装 Docker Buildx 插件"
  mkdir -p /usr/local/lib/docker/cli-plugins

  if [[ -f "$ROOT_DIR/bin/${ARCH}/docker-buildx" ]]; then
    install -m 0755 "$ROOT_DIR/bin/${ARCH}/docker-buildx" /usr/local/lib/docker/cli-plugins/docker-buildx
  else
    warn "未找到 docker-buildx 二进制，跳过。请放到 $ROOT_DIR/bin/docker-buildx"
    return 0
  fi

  docker buildx version
}

main() {
  [[ $EUID -eq 0 ]] || fatal "请使用 root 执行"
  install_docker_binary
  install_compose
  install_buildx
  log "Docker 离线安装完成"
}

main "$@"

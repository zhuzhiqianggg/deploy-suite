#!/usr/bin/env bash
# add_worker.sh - 在 master 节点上添加 worker 节点
#
# 与 install_offline.sh 一致, 全部使用 sealos 命令管理集群
# (master 部署: sealos run, worker 添加: sealos add)
#
# 使用方式:
#   在 K8s master 节点 (已部署集群) 上执行:
#
#   # 1. SSH 免密登录到 worker 节点 (sealos add 通过 SSH 连接)
#   ssh-copy-id root@<worker-ip>
#
#   # 2. 执行此脚本
#   sudo bash add_worker.sh --nodes 192.168.1.101
#   sudo bash add_worker.sh --nodes 192.168.1.101,192.168.1.102
#   sudo bash add_worker.sh --nodes 192.168.1.100-192.168.1.110
#
#   # 如果 worker 的 SSH 密码不是默认, 需指定:
#   sudo bash add_worker.sh --nodes 192.168.1.101 --user root --passwd xxx
#
#   # 添加 master 节点 (高可用):
#   sudo bash add_worker.sh --masters 192.168.1.11 --nodes 192.168.1.101
#
# 此脚本会:
#   1. 验证当前节点是 K8s master (kubectl get nodes)
#   2. 验证 sealos 已安装
#   3. 验证 SSH 连通性
#   4. 执行 sealos add 添加节点 (sealos 会自动 SSH 到目标节点, 安装 containerd/calico/etcd 等)

set -euo pipefail

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal() { log "ERROR: $*"; exit 1; }

# ERR trap
trap 'ret=$?; echo "[$(date "+%F %T")] ERROR at line $LINENO (exit code $ret)" >&2' ERR

[[ $EUID -eq 0 ]] || fatal "请使用 root 执行此脚本"

# 1. 解析参数
NODES=""
MASTERS=""
SSH_USER="root"
SSH_PASSWD=""
SSH_PORT="22"
SSH_PK="/root/.ssh/id_rsa"
ASSUME_YES="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodes)
      NODES="$2"
      shift 2
      ;;
    --masters)
      MASTERS="$2"
      shift 2
      ;;
    --user|-u)
      SSH_USER="$2"
      shift 2
      ;;
    --passwd|-p)
      SSH_PASSWD="$2"
      shift 2
      ;;
    --port)
      SSH_PORT="$2"
      shift 2
      ;;
    --pk|-i)
      SSH_PK="$2"
      shift 2
      ;;
    -y|--yes)
      ASSUME_YES="true"
      shift
      ;;
    --help|-h)
      cat <<'EOF'
用法: add_worker.sh [选项]

添加 K8s 节点 (使用 sealos add), 在 master 节点上执行

选项:
  --nodes <ips>        要添加的 worker 节点 IP (必需, 多个用逗号分隔, 支持 x.x.x.x-x.x.x.y 范围)
  --masters <ips>      同时添加的 master 节点 IP (可选, 用于高可用)
  --user <user>        SSH 用户名 (默认 root)
  --passwd <passwd>    SSH 密码 (默认使用密钥 /root/.ssh/id_rsa)
  --port <port>        SSH 端口 (默认 22)
  --pk <path>          SSH 私钥路径 (默认 /root/.ssh/id_rsa)
  -y, --yes            自动确认

示例:
  # 添加单个 worker (默认 SSH 密钥登录)
  sudo bash add_worker.sh --nodes 192.168.1.101

  # 添加多个 worker
  sudo bash add_worker.sh --nodes 192.168.1.101,192.168.1.102

  # IP 范围
  sudo bash add_worker.sh --nodes 192.168.1.100-192.168.1.110

  # 自定义 SSH 用户和密码
  sudo bash add_worker.sh --nodes 192.168.1.101 --user admin --passwd xxx

  # 添加 master + worker
  sudo bash add_worker.sh --masters 192.168.1.11 --nodes 192.168.1.101

注意:
  1. 此脚本必须在 K8s master 节点上执行
  2. master 与 worker 必须 SSH 互通 (密钥登录)
  3. worker 节点无需任何准备 (sealos add 会自动安装所有依赖)
  4. sealos add 添加的节点与 master 保持相同版本
EOF
      exit 0
      ;;
    *)
      fatal "未知参数: $1 (使用 --help 查看用法)"
      ;;
  esac
done

# 2. 校验参数
if [[ -z "$NODES" && -z "$MASTERS" ]]; then
  fatal "必须指定 --nodes 或 --masters (使用 --help 查看用法)"
fi

# 3. 验证当前节点是 K8s master
log "验证当前节点是 K8s master"
if ! command -v kubectl >/dev/null 2>&1; then
  fatal "kubectl 未安装, 请在 K8s master 节点执行此脚本"
fi
export KUBECONFIG=/root/.kube/config
if ! kubectl get nodes >/dev/null 2>&1; then
  fatal "无法连接 K8s 集群 (KUBECONFIG=$KUBECONFIG), 请在 K8s master 节点执行"
fi
master_count=$(kubectl get nodes --no-headers 2>/dev/null | grep -c 'control-plane' || true)
master_count=${master_count:-0}
if [[ $master_count -eq 0 ]]; then
  fatal "当前节点不是 control-plane, 请在 K8s master 节点执行"
fi
log "当前 K8s 集群状态: $(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ') 个 Ready 节点"

# 4. 验证 sealos
if ! command -v sealos >/dev/null 2>&1; then
  fatal "sealos 未安装, 请先完成 master 部署"
fi
sealos_version=$(sealos version 2>&1 | head -1)
log "sealos 版本: $sealos_version"

# 5. 验证 SSH 连通性
log "验证 SSH 连通性"
for ip in $(echo "${NODES}${NODES:+,}${MASTERS}" | tr ',' ' '); do
  [[ -z "$ip" ]] && continue
  log "  测试 SSH: $SSH_USER@$ip:$SSH_PORT"

  if [[ -n "$SSH_PASSWD" ]]; then
    # 密码登录, 用 sshpass 测试 (可选, 不强制)
    if command -v sshpass >/dev/null 2>&1; then
      if ! sshpass -p "$SSH_PASSWD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
          -p "$SSH_PORT" "$SSH_USER@$ip" "echo ok" >/dev/null 2>&1; then
        fatal "SSH 密码登录失败: $SSH_USER@$ip:$SSH_PORT (请先验证密码正确)"
      fi
    else
      warn "  sshpass 未安装, 跳过密码测试, 实际 sealos add 会直接尝试"
    fi
  else
    # 密钥登录
    if ! ssh -i "$SSH_PK" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        -p "$SSH_PORT" "$SSH_USER@$ip" "echo ok" >/dev/null 2>&1; then
      fatal "SSH 密钥登录失败: $SSH_USER@$ip:$SSH_PORT (请先 ssh-copy-id $SSH_USER@$ip)"
    fi
  fi
  log "  ✓ $ip SSH 通"
done

# 6. 显示计划
echo ""
log "========================================"
log "添加节点计划:"
[[ -n "$MASTERS" ]] && log "  Masters: $MASTERS"
[[ -n "$NODES" ]]   && log "  Nodes:   $NODES"
log "  SSH User: $SSH_USER"
[[ -n "$SSH_PASSWD" ]] && log "  SSH Auth: password" || log "  SSH Auth: key ($SSH_PK)"
log "========================================"
echo ""

# 7. 确认
if [[ "$ASSUME_YES" != "true" ]]; then
  read -rp "确认添加? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { log "已取消"; exit 0; }
fi

# 8. 构建 sealos add 命令
SEALOS_ARGS=(add)
[[ -n "$MASTERS" ]] && SEALOS_ARGS+=(--masters "$MASTERS")
[[ -n "$NODES" ]]   && SEALOS_ARGS+=(--nodes "$NODES")
SEALOS_ARGS+=(--user "$SSH_USER")
SEALOS_ARGS+=(--port "$SSH_PORT")
if [[ -n "$SSH_PASSWD" ]]; then
  SEALOS_ARGS+=(--passwd "$SSH_PASSWD")
else
  SEALOS_ARGS+=(--pk "$SSH_PK")
fi

log "执行: sealos ${SEALOS_ARGS[*]}"
if sealos "${SEALOS_ARGS[@]}"; then
  log "========================================"
  log "节点添加成功!"
  log "========================================"
  echo ""
  log "在 master 节点执行 'kubectl get nodes' 查看新节点"
  echo ""
  log "等待 1-2 分钟后节点会变为 Ready 状态:"
  log "  kubectl get nodes -w"
else
  fatal "sealos add 失败, 请检查上面的错误信息"
fi

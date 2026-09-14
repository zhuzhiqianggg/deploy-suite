#!/usr/bin/env bash
# ============================================================================
# ops-add-worker —— 向现有集群添加 worker/master 节点并完成节点加固
# ============================================================================
# 用法（在 master 节点执行）:
#   sudo bash ops-add-worker.sh --nodes 173.23.1.3[,173.23.1.4] [选项]
#
# 在 sealos add 基础上，自动完成本项目的新节点加固（踩坑教训固化）:
#   1. 安装 nfs-common（Ubuntu 客户端包名；每个挂 NFS PVC 的节点必须有）
#   2. 同步 /etc/containerd/certs.d 镜像加速配置（在线拉取 quay/registry.k8s.io/docker.io 依赖）
#   3. 同步 /etc/sysctl.d 内核参数（存在 k8s 相关配置时）并 sysctl --system
#   4. Kubelet 配置加固（eviction + mergeDefaultEvictionSettings + maxPods + 日志轮转）
#      —— 与 04-cluster-tuning.sh 同参数，来源于 config.env
#
# 选项:
#   --nodes <ips>    worker 节点 IP，逗号分隔，支持范围 a-b
#   --masters <ips>  同时添加的 master（高可用）
#   --user/-u <u>    SSH 用户（默认 root）
#   --passwd/-p <p>  SSH 密码（默认走密钥）
#   --port <port>    SSH 端口（默认 22）
#   --pk/-i <path>   SSH 私钥（默认 /root/.ssh/id_rsa）
#   -y               跳过确认（等价 SKIP_CONFIRM=1）
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
source "${SCRIPT_DIR}/../config.env"

NODES=""; MASTERS=""
SSH_USER="root"; SSH_PASSWD=""; SSH_PORT="22"; SSH_PK="/root/.ssh/id_rsa"
[[ $EUID -eq 0 ]] || { log_error "请用 root/sudo 执行"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodes)   NODES="$2"; shift 2 ;;
    --masters) MASTERS="$2"; shift 2 ;;
    --user|-u) SSH_USER="$2"; shift 2 ;;
    --passwd|-p) SSH_PASSWD="$2"; shift 2 ;;
    --port)    SSH_PORT="$2"; shift 2 ;;
    --pk|-i)   SSH_PK="$2"; shift 2 ;;
    -y|--yes)  export SKIP_CONFIRM=1; shift ;;
    --help|-h) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30; exit 0 ;;
    *) log_error "未知参数: $1"; exit 1 ;;
  esac
done
[[ -z "$NODES" && -z "$MASTERS" ]] && { log_error "必须指定 --nodes 或 --masters"; exit 1; }

# ── 1. 预检 ──────────────────────────────────────────────────────────────────
log_step "预检"
command -v sealos  >/dev/null || { log_error "sealos 未安装"; exit 1; }
command -v kubectl >/dev/null || { log_error "kubectl 未安装"; exit 1; }
kubectl get nodes >/dev/null 2>&1 || { log_error "无法连接集群，请在 master 执行"; exit 1; }
[[ "$(kubectl get nodes -o jsonpath='{.items[?(@.status.conditions[-1].type=="Ready")].metadata.labels.node-role\.kubernetes\.io/control-plane}' | wc -w)" -ge 0 ]] || true
kubectl get nodes --no-headers | grep -q control-plane || { log_error "本机不是 control-plane 节点"; exit 1; }

ALL_IPS="${NODES:+${NODES},}${MASTERS:-}"
command -v rsync >/dev/null || apt-get install -y rsync >/dev/null 2>&1 || true

ssh_run() { # ssh_run <ip> <command...>
  local ip="$1"; shift
  if [[ -n "$SSH_PASSWD" ]] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$SSH_PASSWD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -p "$SSH_PORT" "${SSH_USER}@${ip}" "$@"
  else
    ssh -i "$SSH_PK" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -p "$SSH_PORT" "${SSH_USER}@${ip}" "$@"
  fi
}

for ip in $(echo "$ALL_IPS" | tr ',' ' '); do
  [[ "$ip" == *-* && "$ip" == *.*-* ]] && continue   # IP 范围写法跳过逐个测试
  log_info "测试 SSH: ${SSH_USER}@${ip}:${SSH_PORT}"
  ssh_run "$ip" "echo ok" >/dev/null || { log_error "SSH 不通: $ip"; exit 1; }
  log_ok "SSH 通: $ip"
done

# ── 2. 确认 ──────────────────────────────────────────────────────────────────
log_info "添加计划: masters=[${MASTERS:-无}] nodes=[${NODES:-无}] ssh=${SSH_USER}@port${SSH_PORT}"
if [[ "${SKIP_CONFIRM:-0}" != "1" ]]; then
  read -rp "确认添加? [y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]] || { log_warn "已取消"; exit 0; }
fi

# ── 3. sealos add ────────────────────────────────────────────────────────────
log_step "sealos add"
SEALOS_ARGS=(add)
[[ -n "$MASTERS" ]] && SEALOS_ARGS+=(--masters "$MASTERS")
[[ -n "$NODES"   ]] && SEALOS_ARGS+=(--nodes "$NODES")
SEALOS_ARGS+=(--user "$SSH_USER" --port "$SSH_PORT")
if [[ -n "$SSH_PASSWD" ]]; then SEALOS_ARGS+=(--passwd "$SSH_PASSWD"); else SEALOS_ARGS+=(--pk "$SSH_PK"); fi
log_cmd "sealos ${SEALOS_ARGS[*]}"
sealos "${SEALOS_ARGS[@]}" || { log_error "sealos add 失败"; exit 1; }

# ── 4. 新节点加固（教训: 扩容 worker 先装 nfs-common / certs.d / kubelet 调优）──
log_step "新节点加固"
# 展开范围 IP（173.23.1.3-173.23.1.4 仅支持同 /24 尾段展开，其余原样）
expand_ips() {
  local in="$1"
  if [[ "$in" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)-([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[3]}" ]]; then
    for ((i=BASH_REMATCH[2]; i<=BASH_REMATCH[4]; i++)); do echo "${BASH_REMATCH[1]}.${i}"; done
  else
    echo "$in" | tr ',' '\n'
  fi
}

SYSTEM_RESERVED_GI=$(calc_system_reserved 2>/dev/null || echo 2)

HARDEN_SCRIPT=$(cat <<EOF
set -e
export DEBIAN_FRONTEND=noninteractive
echo "[a] 安装 nfs-common ..."
apt-get update -qq && apt-get install -y nfs-common >/dev/null
echo "[b] 同步 certs.d（由 rsync 推送）"
echo "[c] 内核参数生效"
sysctl --system >/dev/null 2>&1 || true
echo "[d] Kubelet 配置加固 ..."
python3 - <<'PY'
import re
p = '/var/lib/kubelet/config.yaml'
cfg = open(p).read()
def setkv(m):
    return m.group(1)
# evictionHard 整块替换 + mergeDefaultEvictionSettings + maxPods + 日志轮转
block = '''evictionHard:
  memory.available: "${EVICTION_HARD_MEMORY}"
  nodefs.available: "${EVICTION_HARD_NODEFS}"
  imagefs.available: "${EVICTION_HARD_IMAGEFS}"
  nodefs.inodesFree: "5%"
mergeDefaultEvictionSettings: true
evictionMinimumReclaim:
  memory.available: "512Mi"
  nodefs.available: "1Gi"
  imagefs.available: "2Gi"
maxPods: ${MAX_PODS}
containerLogMaxSize: ${CONTAINER_LOG_MAX_SIZE}
containerLogMaxFiles: ${CONTAINER_LOG_MAX_FILES}
'''
def repl(name, text):
    global cfg
    cfg = re.sub(r'(?m)^%s:.*?(?=^[a-zA-Z#]|\Z)' % name, '', cfg, flags=re.S)
    cfg = text + cfg if name == 'evictionHard' else cfg
    return None
# 删除旧块后统一前置插入
for k in ('evictionHard','mergeDefaultEvictionSettings','evictionMinimumReclaim','maxPods','containerLogMaxSize','containerLogMaxFiles'):
    cfg = re.sub(r'(?m)^%s:.*?(?=^[a-zA-Z]|\\Z)' % k, '', cfg, flags=re.S)
cfg = block + cfg
open(p, 'w').write(cfg)
PY
systemctl restart kubelet
echo "[e] 加固完成"
EOF
)

for ip in $(expand_ips "${NODES:-}"); do
  [[ -z "$ip" ]] && continue
  log_info "加固 $ip ..."
  # b) certs.d 与 sysctl 同步
  ssh_run "$ip" "mkdir -p /etc/containerd" 
  if [[ -d /etc/containerd/certs.d ]]; then
    if [[ -n "$SSH_PASSWD" ]] && command -v sshpass >/dev/null; then
      sshpass -p "$SSH_PASSWD" rsync -a -e "ssh -o StrictHostKeyChecking=no -p $SSH_PORT" /etc/containerd/certs.d/ "${SSH_USER}@${ip}:/etc/containerd/certs.d/"
    else
      rsync -a -i "$SSH_PK" -e "ssh -o StrictHostKeyChecking=no -p $SSH_PORT" /etc/containerd/certs.d/ "${SSH_USER}@${ip}:/etc/containerd/certs.d/"
    fi
    log_ok "$ip: certs.d 已同步"
  fi
  for f in /etc/sysctl.d/*k8s*.conf /etc/sysctl.d/99-k8s*.conf; do
    [[ -f "$f" ]] || continue
    if [[ -n "$SSH_PASSWD" ]] && command -v sshpass >/dev/null; then
      sshpass -p "$SSH_PASSWD" scp -P "$SSH_PORT" -o StrictHostKeyChecking=no "$f" "${SSH_USER}@${ip}:${f}"
    else
      scp -i "$SSH_PK" -P "$SSH_PORT" -o StrictHostKeyChecking=no "$f" "${SSH_USER}@${ip}:${f}"
    fi
    log_ok "$ip: 已同步 $(basename "$f")"
  done
  # a/c/d) 远程执行加固（nfs-common + sysctl + kubelet）
  ssh_run "$ip" "sudo -n bash -s" <<< "$HARDEN_SCRIPT" || { log_error "$ip 加固失败，请手动检查"; exit 1; }
  log_ok "$ip: nfs-common + kubelet 加固完成"
done

# ── 5. 验证 ──────────────────────────────────────────────────────────────────
log_step "等待节点 Ready"
sleep 15
kubectl get nodes -o wide
for ip in $(expand_ips "${NODES:-}"); do
  [[ -z "$ip" ]] && continue
  node_name=$(kubectl get nodes -o jsonpath="{range .items[*]}{.status.addresses[?(@.type=='InternalIP')].address}{'\t'}{.metadata.name}{'\n'}{end}" | awk -v ip="$ip" '$1==ip{print $2}')
  if [[ -n "$node_name" ]]; then
    kubectl wait --for=condition=Ready "node/${node_name}" --timeout=300s >/dev/null 2>&1 \
      && log_ok "节点 Ready: $node_name ($ip)" || log_warn "节点未 Ready: $node_name ($ip)，请观察: kubectl get nodes -w"
  fi
done
log_ok "完成"

#!/usr/bin/env bash
# ============================================================================
# 共享函数库 —— 所有脚本 source 此文件
# ============================================================================
set -euo pipefail

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_step()  { echo -e "\n${CYAN}==== $* ====${NC}"; }
log_cmd()   { echo -e "${BLUE}[CMD]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }

# 带日志输出的命令执行
run_cmd() {
    log_cmd "$@"
    if ! "$@"; then
        log_error "命令执行失败: $*"
        return 1
    fi
}

# 需要 root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请用 sudo 执行此脚本: sudo $0"
        exit 1
    fi
}

# 检查内核模块
check_module() {
    lsmod | grep -q "^$1 " || log_warn "模块 $1 未加载"
}

# 等待条件满足（默认超时 60s，间隔 2s）
wait_for() {
    local desc="$1"; shift
    local timeout="${1:-60}"; shift || true
    local interval="${1:-2}"; shift || true
    log_info "等待: $desc (超时 ${timeout}s)"
    local waited=0
    while ! "$@"; do
        sleep "$interval"
        waited=$((waited + interval))
        if [[ $waited -ge $timeout ]]; then
            log_error "超时：$desc"
            return 1
        fi
    done
    log_ok "$desc"
}

# 等待 Pod 全部 Running
wait_pods_ready() {
    local ns="${1:?namespace required}"
    local label="${2:-}"
    local timeout="${3:-120}"
    log_info "等待 namespace=$ns 所有 Pod Running..."
    local waited=0
    while true; do
        local not_ready
        if [[ -n "$label" ]]; then
            not_ready=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed"' || true)
        else
            not_ready=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed"' || true)
        fi
        if [[ -z "$not_ready" ]]; then
            log_ok "Pod 全部 Running"
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
        if [[ $waited -ge $timeout ]]; then
            log_error "Pod 未就绪：\n$not_ready"
            kubectl get pods -n "$ns" -o wide
            return 1
        fi
    done
}

# 检测系统架构
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        aarch64) echo "arm64" ;;
        x86_64)  echo "amd64" ;;
        *)       log_error "不支持的架构: $arch"; exit 1 ;;
    esac
}

# 检测总内存（GB）
detect_total_mem_gb() {
    awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo
}

# 计算系统预留内存（至少 2Gi）
calc_system_reserved() {
    local total="${1:-$(detect_total_mem_gb)}"
    local reserved=$(( total * 2 / 100 ))   # 2%
    (( reserved < 2 )) && reserved=2
    echo "${reserved}Gi"
}

# 创建目录（带输出）
mkdir_p() { for d in "$@"; do [[ -d "$d" ]] || { log_info "创建目录: $d"; mkdir -p "$d"; }; done; }

# 重启 containerd 并确认健康（配置改坏时用于回滚判断）
restart_containerd_healthy() {
    systemctl restart containerd 2>/dev/null || return 1
    local waited=0
    while (( waited < 15 )); do
        if systemctl is-active --quiet containerd && ctr version >/dev/null 2>&1; then
            log_ok "containerd 重启成功且 gRPC 可用"
            return 0
        fi
        sleep 2; waited=$((waited + 2))
    done
    log_error "containerd 重启后不健康"
    return 1
}

# 幂等写用户 bashrc：带标记注释块，重复执行不会产生重复行
write_bashrc_block() {
    local file="$1" marker="$2" block="$3"
    [[ -f "$file" ]] || touch "$file"
    python3 - "$file" "$marker" "$block" <<'PYEOF'
import sys, re
path, marker, block = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    content = open(path).read()
except FileNotFoundError:
    content = ""
# 移除历史遗留的零散 completion/alias 行（老脚本无标记块直接 append 的）
lines = [l for l in content.splitlines()
         if not re.match(r'\s*source <\(kubectl|helm|crictl|kubeadm|sealos completion', l)
         and not re.match(r'\s*complete -o default -F __start_kubectl', l)
         and not re.match(r'\s*alias k=kubectl\s*$', l)
         and 'source /etc/bash_completion.d/kubectl' not in l
         and 'source /etc/bash_completion.d/helm' not in l
         and not re.search(r'source ~/.local/share/bash-completion/completions/(kubectl|helm|crictl|kubeadm)', l)]
content = "\n".join(lines)
pattern = re.compile(r'\n?# >>> ' + re.escape(marker) + r' block >>>.*?<<< ' + re.escape(marker) + r' block <<<\n?', re.S)
if pattern.search(content):
    content = pattern.sub('', content)
block = block.rstrip("\n")
content = content.rstrip("\n") + "\n\n" + block + "\n"
open(path, "w").write(content)
PYEOF
}

# 带重试的下载
retry_download() {
    local url="$1" out="$2" retries="${3:-3}"
    local i=0
    while (( i < retries )); do
        if curl -fsSL --connect-timeout 10 -o "$out" "$url"; then
            return 0
        fi
        i=$((i + 1))
        log_warn "下载失败 (${i}/${retries}): $url"
        sleep 5
    done
    return 1
}

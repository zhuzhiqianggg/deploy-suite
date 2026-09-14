#!/bin/bash
#==============================================================================
# k8s 集群故障一键排查脚本
# 功能：自动执行全链路诊断，定位集群问题，输出修复建议和命令
# 用法：./k8s-diagnose.sh [--fix] [--verbose]
#   --fix      诊断后自动执行安全修复（delete 异常 Pod 触发重建）
#   --verbose  显示详细诊断过程（含正常项）
# 依赖：kubectl + bash（零外部依赖，不依赖 jq）
# 作者：k8s 运维工具集
#==============================================================================

set -o pipefail

#============================== 颜色与常量 ====================================
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# 问题收集数组
declare -a ISSUE_LEVEL=()     # CRITICAL / WARNING / INFO
declare -a ISSUE_DESC=()      # 问题描述
declare -a ISSUE_FIX=()       # 修复建议（含命令）
ISSUE_COUNT=0
CHECK_COUNT=0
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# 脚本参数
AUTO_FIX=false
VERBOSE=false

#============================== 工具函数 ====================================

print_banner() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          Kubernetes 集群故障一键排查工具                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_ok() {
    OK_COUNT=$((OK_COUNT+1))
    [ "$VERBOSE" = true ] && echo -e "  ${GREEN}[✓]${NC} $1"
}

print_warn() {
    WARN_COUNT=$((WARN_COUNT+1))
    echo -e "  ${YELLOW}[!]${NC} $1"
}

print_fail() {
    FAIL_COUNT=$((FAIL_COUNT+1))
    echo -e "  ${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "  ${CYAN}[i]${NC} $1"
}

print_sub() {
    echo -e "  ${DIM}  → $1${NC}"
}

# 显示执行的命令（用于学习和审计排查过程）
print_cmd() {
    printf "  ${DIM}\$ %s${NC}\n" "$1"
}

# 显示命令的简要输出结果
print_result() {
    echo -e "  ${DIM}  → $1${NC}"
}

# 打印状态统计行（含 0 项，统一对齐格式）
print_status_count() {
    local name="$1"
    local count="$2"
    local desc="$3"
    if [ "$count" -eq 0 ]; then
        printf "    ${GREEN}✓${NC}  %-32s %3d 个  ${DIM}— %s${NC}\n" "$name" "$count" "$desc"
    else
        printf "    ${RED}⚠${NC}  %-32s %3d 个  — %s\n" "$name" "$count" "$desc"
    fi
}

# 打印节点状态统计行
print_node_status_count() {
    local name="$1"
    local count="$2"
    local total="$3"
    local desc="$4"
    if [ "$count" -eq 0 ]; then
        printf "    ${GREEN}✓${NC}  %-32s %d/%d  ${DIM}— %s${NC}\n" "$name" "$count" "$total" "$desc"
    else
        printf "    ${RED}⚠${NC}  %-32s %d/%d  — %s\n" "$name" "$count" "$total" "$desc"
    fi
}

add_issue() {
    local level="$1"
    local desc="$2"
    local fix="$3"
    ISSUE_LEVEL+=("$level")
    ISSUE_DESC+=("$desc")
    ISSUE_FIX+=("$fix")
    ISSUE_COUNT=$((ISSUE_COUNT+1))
}

# 安全执行 kubectl 命令（失败不中断脚本）
safe_kubectl() {
    kubectl "$@" 2>/dev/null
    return $?
}

#============================== 检查模块 ====================================

#==============================================================================
# 模块0：环境前置检查
#==============================================================================
check_prerequisites() {
    print_section "0. 环境前置检查"

    # 检查 kubectl 是否存在
    if ! command -v kubectl &>/dev/null; then
        print_fail "kubectl 命令未找到，请确保已安装并加入 PATH"
        echo ""
        echo "修复: 安装 kubectl"
        echo "  curl -LO https://dl.k8s.io/release/\$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        echo "  install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl"
        exit 1
    fi
    print_cmd "kubectl version --client"
    print_ok "kubectl 已安装: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"

    # 检查是否能连接 apiserver
    print_cmd "kubectl get nodes"
    if ! safe_kubectl get nodes &>/dev/null; then
        print_fail "无法连接 apiserver，kubectl 命令失败"
        echo ""
        echo "可能原因:"
        echo "  1. kubeconfig 未配置或过期（检查 ~/.kube/config 或 KUBECONFIG 环境变量）"
        echo "  2. apiserver 不可达（检查 6443 端口和网络）"
        echo "  3. apiserver 进程挂掉（在 master 节点检查 systemctl status kubelet）"
        echo ""
        echo "修复:"
        echo "  # 检查 kubeconfig"
        echo "  kubectl config view --minify"
        echo "  # 在 master 节点检查 apiserver"
        echo "  systemctl status kubelet"
        echo "  crictl ps | grep kube-apiserver"
        exit 1
    fi
    print_ok "apiserver 连接正常"

    # 集群基本信息
    local cluster_info
    print_cmd "kubectl cluster-info"
    cluster_info=$(safe_kubectl cluster-info 2>/dev/null | head -2)
    print_info "集群信息:"
    echo "$cluster_info" | while read -r line; do [ -n "$line" ] && print_sub "$line"; done
}

#==============================================================================
# 模块1：节点状态检查
#==============================================================================
check_nodes() {
    print_section "1. 节点状态检查"

    local nodes_output
    print_cmd "kubectl get nodes -o wide"
    nodes_output=$(safe_kubectl get nodes -o wide 2>/dev/null)
    local total_nodes
    total_nodes=$(echo "$nodes_output" | grep -c -v "^NAME")
    print_result "$total_nodes 个节点"
    print_info "集群节点总数: $total_nodes"

    # 检查 NotReady 节点
    local notready_nodes
    notready_nodes=$(echo "$nodes_output" | awk '$2!="Ready" && NR>1{print $1}')
    if [ -n "$notready_nodes" ]; then
        print_fail "发现 NotReady/Unknown 节点:"
        echo "$notready_nodes" | while read -r node; do
            print_sub "$node"
        done
        add_issue "CRITICAL" \
            "节点 NotReady: $(echo "$notready_nodes" | tr '\n' ' ')" \
            "# 登录异常节点检查:\n# ssh <node-ip>\nsystemctl status kubelet\nsystemctl status containerd\njournalctl -u kubelet --no-pager -n 50\n# 常见原因: kubelet挂掉/容器运行时异常/资源耗尽/CNI未就绪"
    else
        print_ok "所有 $total_nodes 个节点均为 Ready 状态"
    fi

    # 检查节点 Conditions（资源压力）
    local pressure_nodes
    print_cmd "kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}:{range .status.conditions[?(@.status==\"True\")]}{.type} {end}{\"\\n\"}{end}'"
    pressure_nodes=$(safe_kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}:{range .status.conditions[?(@.status=="True")]}{.type} {end}{"\n"}{end}' 2>/dev/null | grep -vE "^$:Ready" | grep -vE "^[^:]+:Ready *$")
    if [ -n "$pressure_nodes" ]; then
        local has_pressure=false
        echo "$pressure_nodes" | while read -r line; do
            local node=$(echo "$line" | cut -d: -f1)
            local conds=$(echo "$line" | cut -d: -f2)
            if echo "$conds" | grep -qE "MemoryPressure|DiskPressure|PIDPressure|NetworkUnavailable"; then
                print_fail "节点 $node 存在异常 Condition: $conds"
                has_pressure=true
            fi
        done
        # 重新检查（上面在子shell中）
        if safe_kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}:{range .status.conditions[?(@.status=="True")]}{.type} {end}{"\n"}{end}' 2>/dev/null | grep -qE "MemoryPressure|DiskPressure|PIDPressure|NetworkUnavailable"; then
            add_issue "WARNING" \
                "部分节点存在资源压力（MemoryPressure/DiskPressure/PIDPressure/NetworkUnavailable）" \
                "# 检查节点资源:\nkubectl describe node <node-name> | grep -A10 Conditions\nkubectl describe node <node-name> | grep -A10 'Allocated resources'\n# 磁盘清理:\nssh <node-ip> 'crictl rmi --prune'\nssh <node-ip> 'journalctl --vacuum-time=3d'"
        fi
    else
        print_ok "所有节点 Conditions 正常（无资源压力）"
    fi

    # 检查 kubelet 版本一致性
    local versions
    print_cmd "kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{\"\\n\"}{end}'"
    versions=$(safe_kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' 2>/dev/null | sort -u)
    local version_count
    version_count=$(echo "$versions" | grep -c .)
    if [ "$version_count" -gt 1 ]; then
        print_warn "节点 kubelet 版本不一致:"
        echo "$versions" | while read -r v; do print_sub "$v"; done
        add_issue "WARNING" \
            "集群中 kubelet 版本不一致: $(echo "$versions" | tr '\n' ' ')" \
            "# 规划升级版本统一的节点:\nkubectl get nodes -o wide\n# 参考: https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/"
    else
        print_ok "kubelet 版本一致: $(echo "$versions" | head -1)"
    fi

    # 检查节点资源使用（需要 metrics-server）
    print_cmd "kubectl top nodes"
    if safe_kubectl top nodes &>/dev/null; then
        local high_usage
        high_usage=$(safe_kubectl top nodes 2>/dev/null | awk 'NR>1 && ($3+0>85 || $6+0>85){print $1": CPU="$3" MEM="$6}')
        if [ -n "$high_usage" ]; then
            print_warn "资源使用率过高（>85%）的节点:"
            echo "$high_usage" | while read -r line; do print_sub "$line"; done
            add_issue "WARNING" \
                "节点资源使用率过高（>85%）:\n$high_usage" \
                "# 检查占用进程:\nssh <node-ip> 'top -b -n1 | head -20'\n# 考虑扩容或迁移 Pod"
        else
            print_ok "节点资源使用率正常（<85%）"
        fi
    else
        print_info "metrics-server 不可用，跳过资源使用率检查"
    fi

    # 检查节点 AGE（近期重新加入的节点可能是故障后重装的）
    local recent_nodes
    recent_nodes=$(safe_kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}:{.metadata.creationTimestamp}{"\n"}{end}' 2>/dev/null | while IFS=: read -r name ts; do
        # 简单检查：如果创建时间在 24 小时内
        local age_days=$(( ($(date +%s) - $(date -d "$ts" +%s 2>/dev/null || echo 0)) / 86400 ))
        if [ "$age_days" -lt 1 ]; then
            echo "$name (AGE: ${age_days}天)"
        fi
    done)
    if [ -n "$recent_nodes" ]; then
        print_warn "近期加入的节点（<1天），可能是故障后重装:"
        echo "$recent_nodes" | while read -r line; do print_sub "$line"; done
    fi
}

#==============================================================================
# 模块2：控制面检查
#==============================================================================
check_control_plane() {
    print_section "2. 控制面检查"

    # componentstatus
    local cs_output
    print_cmd "kubectl get cs"
    cs_output=$(safe_kubectl get cs 2>/dev/null)
    if [ -n "$cs_output" ]; then
        local unhealthy
        unhealthy=$(echo "$cs_output" | awk '$2!="Healthy" && NR>1{print $1": "$2" "$3}')
        if [ -n "$unhealthy" ]; then
            print_fail "控制面组件不健康:"
            echo "$unhealthy" | while read -r line; do print_sub "$line"; done
            add_issue "CRITICAL" \
                "控制面组件异常: $unhealthy" \
                "# 检查对应组件日志:\nkubectl logs -n kube-system <component>-<master> --tail=50\n# 检查 etcd:\nETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \\\n  --cacert=/etc/kubernetes/pki/etcd/ca.crt \\\n  --cert=/etc/kubernetes/pki/etcd/server.crt \\\n  --key=/etc/kubernetes/pki/etcd/server.key \\\n  endpoint health"
        else
            print_ok "控制面组件（scheduler/controller-manager/etcd）均 Healthy"
        fi
    else
        print_info "kubectl get cs 不可用（v1.20+ 已废弃），跳过"
    fi

    # 检查 static pod 状态（apiserver/scheduler/cm/etcd）
    local static_pods
    print_cmd "kubectl get pods -n kube-system | grep -E 'kube-apiserver|kube-scheduler|kube-controller-manager|etcd-'"
    static_pods=$(safe_kubectl get pods -n kube-system -o wide 2>/dev/null | grep -E "kube-apiserver|kube-scheduler|kube-controller-manager|etcd-")
    if [ -n "$static_pods" ]; then
        local bad_pods
        bad_pods=$(echo "$static_pods" | awk '$3!="Running"{print $1" ("$3")"}')
        if [ -n "$bad_pods" ]; then
            print_fail "控制面 static pod 异常:"
            echo "$bad_pods" | while read -r line; do print_sub "$line"; done
            add_issue "CRITICAL" \
                "控制面 static pod 异常: $bad_pods" \
                "# 查看 Pod 日志:\nkubectl logs -n kube-system <pod-name> --tail=50\n# 检查 master 节点 kubelet:\nssh <master-ip> 'systemctl status kubelet'\n# 检查 manifest 文件:\nls -la /etc/kubernetes/manifests/"
        else
            print_ok "控制面 static pod 均正常运行"
        fi
    else
        print_warn "未找到控制面 static pod（可能非标准 kubeadm 部署）"
    fi

    # 检查 kubernetes Service Endpoints
    local k8s_ep
    print_cmd "kubectl get endpoints kubernetes -n default"
    k8s_ep=$(safe_kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
    if [ -n "$k8s_ep" ]; then
        local ep_count
        ep_count=$(echo "$k8s_ep" | tr ' ' '\n' | grep -c .)
        print_ok "kubernetes Service Endpoints 正常（$ep_count 个: $(echo "$k8s_ep" | tr ' ' ',')）"
    else
        print_fail "kubernetes Service Endpoints 为空"
        add_issue "CRITICAL" \
            "kubernetes Service 没有可用的 Endpoints（apiserver 不可达）" \
            "# 检查 apiserver:\ncrictl ps | grep apiserver\nsystemctl status kubelet\n# 检查 apiserver 健康度:\ncurl -k https://localhost:6443/healthz"
    fi

    # 检查 apiserver 健康度
    local healthz
    print_cmd "curl -sk https://localhost:6443/healthz"
    healthz=$(curl -sk --max-time 5 https://localhost:6443/healthz 2>/dev/null)
    if [ "$healthz" = "ok" ]; then
        print_ok "apiserver healthz 正常"
    else
        print_fail "apiserver healthz 异常: $healthz"
        add_issue "CRITICAL" \
            "apiserver healthz 返回异常" \
            "# 检查 apiserver 日志:\nkubectl logs -n kube-system kube-apiserver-$(hostname) --tail=50\n# 检查证书是否过期:\nkubeadm certs check-expiration"
    fi
}

#==============================================================================
# 模块3：网络层（CNI）检查
#==============================================================================
check_network() {
    print_section "3. 网络层（CNI）检查"

    # 检测 CNI 类型
    local cni_type=""
    print_cmd "kubectl get ns calico-system"
    if safe_kubectl get ns calico-system &>/dev/null; then
        cni_type="calico"
        CNI_NS="calico-system"
    elif safe_kubectl get pods -n kube-system -l k8s-app=flannel &>/dev/null; then
        cni_type="flannel"
        CNI_NS="kube-system"
    elif safe_kubectl get pods -n kube-system -l k8s-app=cilium &>/dev/null || safe_kubectl get pods -n kube-system -l app=cilium &>/dev/null; then
        cni_type="cilium"
        CNI_NS="kube-system"
    else
        # 尝试在 kube-system 中找 calico
        if safe_kubectl get pods -n kube-system -l k8s-app=calico-node &>/dev/null; then
            cni_type="calico"
            CNI_NS="kube-system"
        else
            cni_type="unknown"
            CNI_NS="kube-system"
        fi
    fi
    print_info "检测到 CNI: ${cni_type}（命名空间: $CNI_NS）"

    # 检查 CNI Pod 状态
    local cni_pods=""
    if [ "$cni_type" = "calico" ]; then
        print_cmd "kubectl get pods -n $CNI_NS -l k8s-app=calico-node -o wide"
        cni_pods=$(safe_kubectl get pods -n "$CNI_NS" -l k8s-app=calico-node -o wide 2>/dev/null)
    elif [ "$cni_type" = "flannel" ]; then
        cni_pods=$(safe_kubectl get pods -n "$CNI_NS" -l k8s-app=flannel -o wide 2>/dev/null)
    elif [ "$cni_type" = "cilium" ]; then
        cni_pods=$(safe_kubectl get pods -n "$CNI_NS" -l app=cilium -o wide 2>/dev/null)
    fi

    if [ -n "$cni_pods" ]; then
        local total_nodes cni_pod_count
        total_nodes=$(safe_kubectl get nodes --no-headers 2>/dev/null | wc -l)
        cni_pod_count=$(echo "$cni_pods" | grep -c -v "^NAME")
        if [ "$cni_pod_count" -lt "$total_nodes" ]; then
            print_warn "CNI Pod 数量($cni_pod_count) 少于节点数($total_nodes)，部分节点缺少 CNI"
            add_issue "WARNING" \
                "CNI DaemonSet 未覆盖所有节点（$cni_pod_count/$total_nodes）" \
                "# 检查缺少 CNI Pod 的节点:\nkubectl get pods -n $CNI_NS -o wide\n# 检查节点是否有污点阻止调度:\nkubectl describe node <node> | grep Taint"
        else
            print_ok "CNI Pod 数量与节点数匹配（$cni_pod_count/$total_nodes）"
        fi

        # 检查 CNI Pod 是否正常运行
        local bad_cni
        bad_cni=$(echo "$cni_pods" | awk 'NR>1 && $3!="Running"{print $1" ("$3", restarts:"$4")"}')
        if [ -n "$bad_cni" ]; then
            print_fail "CNI Pod 异常:"
            echo "$bad_cni" | while read -r line; do print_sub "$line"; done
            add_issue "CRITICAL" \
                "CNI Pod 异常: $(echo "$bad_cni" | tr '\n' ' ')" \
                "# 查看 CNI Pod 日志:\nkubectl logs -n $CNI_NS <pod-name> --tail=50\n# 重启异常的 CNI Pod:\nkubectl delete pod -n $CNI_NS <pod-name>"
        else
            print_ok "所有 CNI Pod 正常运行"
        fi
    else
        print_warn "未找到 CNI Pod，可能 CNI 未安装或标签不同"
        add_issue "WARNING" \
            "未检测到 CNI Pod" \
            "# 手动检查:\nkubectl get pods -A | grep -E 'calico|flannel|cilium|weave'\n# 检查节点 CNI 配置:\nls /etc/cni/net.d/"
    fi

    # Calico 专项检查：node IP 一致性
    if [ "$cni_type" = "calico" ]; then
        print_info "Calico 专项检查: node IP 一致性"
        local node_ips
        print_cmd "kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.status.addresses[?(@.type==\"InternalIP\")].address}{\"\\t\"}{.metadata.annotations.projectcalico\\.org/IPv4Address}{\"\\n\"}{end}'"
        node_ips=$(safe_kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\t"}{.metadata.annotations.projectcalico\.org/IPv4Address}{"\n"}{end}' 2>/dev/null)
        if [ -n "$node_ips" ]; then
            local has_mismatch=false
            # 使用 here string 避免子 shell 问题（管道中 add_issue 不生效）
            while IFS=$'\t' read -r name real_ip calico_ip; do
                # 提取 calico_ip 中的 IP 部分（去掉 /24 等）
                local calico_ip_only
                calico_ip_only=$(echo "$calico_ip" | cut -d/ -f1)
                if [ -n "$calico_ip" ] && [ "$calico_ip_only" != "$real_ip" ]; then
                    print_fail "节点 $name IP 不一致: 真实IP=$real_ip, calico记录=$calico_ip"
                    has_mismatch=true
                    add_issue "CRITICAL" \
                        "Calico node IP 配置错误: $name 真实IP=$real_ip 但 calico 记录=$calico_ip" \
                        "# 修正 calico annotation:\nkubectl annotate node $name projectcalico.org/IPv4Address=${real_ip}/24 --overwrite\n# 重启该节点的 calico-node:\nkubectl delete pod -n $CNI_NS \$(kubectl get pods -n $CNI_NS -l k8s-app=calico-node -o jsonpath='{range .items[?(@.spec.nodeName==\"$name\")]}{.metadata.name}{end}')"
                fi
            done <<< "$node_ips"
            if [ "$has_mismatch" = false ]; then
                print_ok "所有节点 calico IP 配置一致"
            fi
        else
            print_warn "无法获取 calico node annotation，可能 calico 版本不同或未初始化"
        fi
    fi

    # 检查 kube-proxy
    local kp_pods
    print_cmd "kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide"
    kp_pods=$(safe_kubectl get pods -n kube-system -l k8s-app=kube-proxy -o wide 2>/dev/null)
    if [ -n "$kp_pods" ]; then
        local bad_kp
        bad_kp=$(echo "$kp_pods" | awk 'NR>1 && $3!="Running"{print $1" ("$3")"}')
        if [ -n "$bad_kp" ]; then
            print_fail "kube-proxy Pod 异常:"
            echo "$bad_kp" | while read -r line; do print_sub "$line"; done
            add_issue "WARNING" \
                "kube-proxy Pod 异常: $(echo "$bad_kp" | tr '\n' ' ')" \
                "# 重启异常的 kube-proxy:\nkubectl delete pod -n kube-system <pod-name>"
        else
            print_ok "所有 kube-proxy Pod 正常运行"
        fi
    else
        print_warn "未找到 kube-proxy Pod（可能使用 eBPF 模式或标签不同）"
    fi
}

#==============================================================================
# 模块4：DNS（CoreDNS）检查
#==============================================================================
check_dns() {
    print_section "4. 服务发现（DNS）检查"

    # 检查 CoreDNS Pod
    local dns_pods
    print_cmd "kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide"
    dns_pods=$(safe_kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide 2>/dev/null)
    if [ -z "$dns_pods" ]; then
        dns_pods=$(safe_kubectl get pods -n kube-system -l k8s-app=coredns -o wide 2>/dev/null)
    fi

    if [ -n "$dns_pods" ]; then
        local dns_count
        dns_count=$(echo "$dns_pods" | grep -c -v "^NAME")
        local bad_dns
        bad_dns=$(echo "$dns_pods" | awk 'NR>1 && $3!="Running"{print $1" ("$3")"}')
        if [ -n "$bad_dns" ]; then
            print_fail "CoreDNS Pod 异常:"
            echo "$bad_dns" | while read -r line; do print_sub "$line"; done
            add_issue "CRITICAL" \
                "CoreDNS Pod 异常: $(echo "$bad_dns" | tr '\n' ' ')" \
                "# 查看 CoreDNS 日志:\nkubectl logs -n kube-system <pod-name> --tail=50\n# 重启 CoreDNS:\nkubectl delete pod -n kube-system <pod-name>"
        else
            print_ok "CoreDNS Pod 正常运行（$dns_count 个）"
        fi
    else
        print_fail "未找到 CoreDNS Pod"
        add_issue "CRITICAL" \
            "CoreDNS 未部署或标签不匹配" \
            "# 手动检查:\nkubectl get pods -n kube-system | grep -i dns\n# 检查 Deployment:\nkubectl get deploy -n kube-system | grep dns"
    fi

    # 检查 kube-dns Service
    local dns_svc
    print_cmd "kubectl get svc -n kube-system kube-dns"
    dns_svc=$(safe_kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [ -n "$dns_svc" ]; then
        print_ok "kube-dns Service 存在（ClusterIP: $dns_svc）"
    else
        print_fail "kube-dns Service 不存在"
        add_issue "CRITICAL" \
            "kube-dns Service 不存在，DNS 解析将无法工作" \
            "# 创建 kube-dns Service:\nkubectl expose deployment coredns -n kube-system --port=53 --target-port=53 --protocol=UDP --name=kube-dns\n# 或参考官方清单修复"
    fi

    # 检查 kube-dns Endpoints
    local dns_ep
    print_cmd "kubectl get endpoints -n kube-system kube-dns"
    dns_ep=$(safe_kubectl get endpoints -n kube-system kube-dns -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
    if [ -n "$dns_ep" ]; then
        local ep_count
        ep_count=$(echo "$dns_ep" | tr ' ' '\n' | grep -c .)
        print_ok "kube-dns Endpoints 正常（$ep_count 个: $(echo "$dns_ep" | tr ' ' ',')）"
    else
        print_fail "kube-dns Endpoints 为空（CoreDNS Pod 未就绪或标签不匹配）"
        add_issue "CRITICAL" \
            "kube-dns Service 没有可用的 Endpoints" \
            "# 检查 CoreDNS Pod 是否就绪:\nkubectl get pods -n kube-system -l k8s-app=kube-dns\n# 检查 Service selector 是否匹配 Pod 标签:\nkubectl get svc kube-dns -n kube-system -o yaml | grep selector -A3\nkubectl get pods -n kube-system -l k8s-app=kube-dns --show-labels"
    fi

    # 检查 CoreDNS ConfigMap
    local dns_cm
    print_cmd "kubectl get configmap -n kube-system coredns"
    dns_cm=$(safe_kubectl get configmap -n kube-system coredns 2>/dev/null)
    if [ -n "$dns_cm" ]; then
        print_ok "CoreDNS ConfigMap 存在"
    else
        print_warn "CoreDNS ConfigMap 不存在"
        add_issue "WARNING" \
            "CoreDNS ConfigMap 不存在" \
            "# 检查:\nkubectl get cm -n kube-system | grep dns"
    fi
}

#==============================================================================
# 模块5：存储检查
#==============================================================================
check_storage() {
    print_section "5. 存储层检查"

    # 检查 Pending PVC
    local pending_pvc
    print_cmd "kubectl get pvc -A | grep Pending"
    pending_pvc=$(safe_kubectl get pvc -A 2>/dev/null | awk '$3=="Pending"{print $1"/"$2}')
    if [ -n "$pending_pvc" ]; then
        local pvc_count
        pvc_count=$(echo "$pending_pvc" | grep -c .)
        print_fail "发现 $pvc_count 个 Pending PVC:"
        echo "$pending_pvc" | head -10 | while read -r line; do print_sub "$line"; done
        [ "$pvc_count" -gt 10 ] && print_sub "...（共 $pvc_count 个）"
        add_issue "WARNING" \
            "$pvc_count 个 PVC 处于 Pending 状态" \
            "# 查看 PVC 详情:\nkubectl describe pvc <name> -n <namespace>\n# 常见原因: StorageClass 不存在/PV 容量不足/节点亲和性不匹配"
    else
        print_ok "所有 PVC 已绑定"
    fi

    # 检查异常 PV
    local bad_pv
    print_cmd "kubectl get pv"
    bad_pv=$(safe_kubectl get pv 2>/dev/null | awk '$5!="Bound" && $5!="Available" && NR>1{print $1" ("$5")"}')
    if [ -n "$bad_pv" ]; then
        print_warn "存在异常 PV:"
        echo "$bad_pv" | while read -r line; do print_sub "$line"; done
        add_issue "WARNING" \
            "PV 状态异常: $(echo "$bad_pv" | tr '\n' ' ')" \
            "# 查看 PV 详情:\nkubectl describe pv <name>"
    else
        print_ok "所有 PV 状态正常（Bound/Available）"
    fi

    # 检查 CSI 驱动
    local csi_drivers
    print_cmd "kubectl get csidriver"
    csi_drivers=$(safe_kubectl get csidriver 2>/dev/null)
    if [ -n "$csi_drivers" ]; then
        local driver_count
        driver_count=$(echo "$csi_drivers" | grep -c -v "^NAME")
        print_ok "CSI 驱动已注册（$driver_count 个）"
    else
        print_info "未检测到 CSI 驱动（可能使用 NFS/HostPath 等非 CSI 存储）"
    fi
}

#==============================================================================
# 模块6：镜像拉取检查
#==============================================================================
check_image_pull() {
    print_section "6. 镜像拉取检查"

    local pull_fail_pods
    print_cmd "kubectl get pods -A --field-selector=status.phase!=Running -o jsonpath='{...}'"
    pull_fail_pods=$(safe_kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}:{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null | grep -E "ImagePullBackOff|ErrImagePull")

    if [ -n "$pull_fail_pods" ]; then
        local total_pull_fail
        total_pull_fail=$(echo "$pull_fail_pods" | grep -c .)
        print_fail "发现 $total_pull_fail 个镜像拉取失败的 Pod"

        # 分类统计失败原因
        local auth_fail=0 not_found=0 timeout=0 dns_fail=0 other=0
        while IFS=: read -r pod reason; do
            local ns=$(echo "$pod" | cut -d/ -f1)
            local name=$(echo "$pod" | cut -d/ -f2)
            local detail
            print_cmd "kubectl describe pod $name -n $ns | grep -oE '401|not found|timeout|...'"
            detail=$(safe_kubectl describe pod "$name" -n "$ns" 2>/dev/null | grep -oE "401 Unauthorized|403 Forbidden|not found|manifest unknown|timeout|context deadline|name resolution|no such host|connection refused" | head -1)
            case "$detail" in
                "401 Unauthorized"|"403 Forbidden") auth_fail=$((auth_fail+1)) ;;
                "not found"|"manifest unknown") not_found=$((not_found+1)) ;;
                "timeout"|"context deadline") timeout=$((timeout+1)) ;;
                "name resolution"|"no such host"|"connection refused") dns_fail=$((dns_fail+1)) ;;
                *) other=$((other+1)) ;;
            esac
        done <<< "$pull_fail_pods"

        print_info "失败原因分类:"
        [ "$auth_fail" -gt 0 ] && print_sub "认证失败(401/403): $auth_fail 个 → 检查 imagePullSecrets 凭据"
        [ "$not_found" -gt 0 ] && print_sub "镜像不存在(not found): $not_found 个 → 确认镜像 tag 是否已推送"
        [ "$timeout" -gt 0 ] && print_sub "拉取超时: $timeout 个 → 检查节点到仓库的网络"
        [ "$dns_fail" -gt 0 ] && print_sub "DNS/网络错误: $dns_fail 个 → 检查节点 DNS 配置"
        [ "$other" -gt 0 ] && print_sub "其他原因: $other 个"

        if [ "$auth_fail" -gt 0 ]; then
            add_issue "WARNING" \
                "$auth_fail 个 Pod 镜像拉取认证失败(401 Unauthorized)，imagePullSecrets 凭据可能失效" \
                "# 检查现有 secret:\nkubectl get secret <secret-name> -n <namespace> -o jsonpath='{.data.\\.dockerconfigjson}' | base64 -d\n# 更新 secret:\nkubectl create secret docker-registry <secret-name> \\\n  --docker-server=<registry> --docker-username=<user> --docker-password=<pass> \\\n  -n <namespace> --dry-run=client -o yaml | kubectl apply -f -\n# 重建失败 Pod:\nkubectl delete pod <pod-name> -n <namespace>"
        fi
        if [ "$not_found" -gt 0 ]; then
            add_issue "INFO" \
                "$not_found 个 Pod 引用的镜像 tag 在仓库中不存在" \
            "# 确认镜像是否已推送:\n# 在节点上手动拉取测试:\nssh <node-ip> 'crictl pull <image>'\n# 更新 Deployment 中的 image tag 或推送缺失的镜像"
        fi
        if [ "$timeout" -gt 0 ] || [ "$dns_fail" -gt 0 ]; then
            add_issue "WARNING" \
                "$((timeout+dns_fail)) 个 Pod 镜像拉取因网络/DNS 问题失败" \
            "# 检查节点网络和 DNS:\nssh <node-ip> 'cat /etc/resolv.conf'\nssh <node-ip> 'ping <registry-domain>'\nssh <node-ip> 'curl -v https://<registry-domain>/v2/'"
        fi
    else
        print_result "无镜像拉取失败的 Pod"
        print_ok "无镜像拉取失败的 Pod"
    fi
}

#==============================================================================
# 模块7：Pod 状态全面检查
#==============================================================================
check_pods() {
    print_section "7. Pod 状态全面检查"

    # 获取所有 Pod 数据（含 Running，用于 OOMKilled 检测）
    # 格式: ns/name:phase:waiting_reason:terminated_reason:exit_code
    local all_pod_data
    print_cmd "kubectl get pods -A -o jsonpath='{...}'"
    all_pod_data=$(safe_kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}:{.status.phase}:{.status.containerStatuses[0].state.waiting.reason}:{.status.containerStatuses[0].lastState.terminated.reason}:{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}{end}' 2>/dev/null)

    # 获取异常 Pod（非 Running 非 Succeeded）
    local all_bad_pods
    print_cmd "kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded"
    all_bad_pods=$(safe_kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}:{.status.phase}:{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null)

    # 概览统计
    local total_pods total_bad total_running
    total_pods=$(echo "$all_pod_data" | grep -c . 2>/dev/null || echo 0)
    if [ -n "$all_bad_pods" ]; then
        total_bad=$(echo "$all_bad_pods" | grep -c .)
    else
        total_bad=0
    fi
    total_running=$((total_pods - total_bad))
    print_info "Pod 总数: $total_pods | Running/Succeeded: $total_running | 异常: $total_bad"

    # 初始化所有状态计数器
    local container_creating=0 pod_initializing=0 pending=0 crashloop=0
    local err_image_pull=0 image_pull_backoff=0 create_config_err=0 create_container_err=0
    local run_container_err=0 invalid_image=0 evicted=0 failed=0 unknown=0 other=0
    local oom_killed=0

    # 统计异常 Pod 各状态数量
    if [ -n "$all_bad_pods" ]; then
        while IFS=: read -r pod phase reason; do
            [ -z "$pod" ] && continue
            case "$reason" in
                ContainerCreating) container_creating=$((container_creating+1)) ;;
                PodInitializing|Init:*) pod_initializing=$((pod_initializing+1)) ;;
                CrashLoopBackOff) crashloop=$((crashloop+1)) ;;
                ErrImagePull) err_image_pull=$((err_image_pull+1)) ;;
                ImagePullBackOff) image_pull_backoff=$((image_pull_backoff+1)) ;;
                CreateContainerConfigError) create_config_err=$((create_config_err+1)) ;;
                CreateContainerError) create_container_err=$((create_container_err+1)) ;;
                RunContainerError) run_container_err=$((run_container_err+1)) ;;
                InvalidImageName) invalid_image=$((invalid_image+1)) ;;
                *)
                    case "$phase" in
                        Pending) pending=$((pending+1)) ;;
                        Failed)
                            local ns=$(echo "$pod" | cut -d/ -f1)
                            local name=$(echo "$pod" | cut -d/ -f2)
                            local pod_reason
                            pod_reason=$(safe_kubectl get pod "$name" -n "$ns" -o jsonpath='{.status.reason}' 2>/dev/null)
                            if [ "$pod_reason" = "Evicted" ]; then
                                evicted=$((evicted+1))
                            else
                                failed=$((failed+1))
                            fi
                            ;;
                        Unknown) unknown=$((unknown+1)) ;;
                        *) other=$((other+1)) ;;
                    esac
                    ;;
            esac
        done <<< "$all_bad_pods"
    fi

    # 统计 OOMKilled（可能已恢复为 Running，但 lastState 有 OOMKilled 记录）
    oom_killed=$(echo "$all_pod_data" | grep -c ":OOMKilled:" 2>/dev/null || echo 0)

    # 打印完整状态统计表（所有状态都显示，即使为 0）
    echo ""
    echo -e "  ${BOLD}全部异常状态统计（含 0 项，供参考）:${NC}"
    print_status_count "ContainerCreating" "$container_creating" "容器创建中（短期正常，长期可能存储/CNI问题）"
    print_status_count "PodInitializing" "$pod_initializing" "Pod初始化中（init容器运行中，短期正常）"
    print_status_count "Pending" "$pending" "等待调度（资源不足/污点/PVC未绑定）"
    print_status_count "CrashLoopBackOff" "$crashloop" "崩溃循环退避（应用启动失败，需查看日志）"
    print_status_count "ErrImagePull" "$err_image_pull" "镜像拉取失败（首次，凭据/镜像不存在/网络）"
    print_status_count "ImagePullBackOff" "$image_pull_backoff" "镜像拉取退避（kubelet放弃重试）"
    print_status_count "CreateContainerConfigError" "$create_config_err" "容器配置错误（subPath/NFS/Secret缺失）"
    print_status_count "CreateContainerError" "$create_container_err" "容器创建失败（运行时层面异常）"
    print_status_count "RunContainerError" "$run_container_err" "容器运行失败（镜像损坏/运行时异常）"
    print_status_count "InvalidImageName" "$invalid_image" "镜像名格式错误"
    print_status_count "Evicted" "$evicted" "被驱逐（节点资源不足/磁盘压力）"
    print_status_count "Failed" "$failed" "失败状态（容器已终止退出）"
    print_status_count "Unknown" "$unknown" "未知状态（kubelet无法上报）"
    print_status_count "OOMKilled(已恢复)" "$oom_killed" "内存不足被杀后重启（需调内存限制）"
    [ "$other" -gt 0 ] && print_status_count "其他未分类" "$other" "未分类异常状态"

    # 如果无任何异常
    if [ "$total_bad" -eq 0 ] && [ "$oom_killed" -eq 0 ]; then
        echo ""
        print_ok "集群中所有 Pod 状态正常"
        return
    fi

    # ---- 异常详情分析 ----
    echo ""
    echo -e "  ${BOLD}异常详情分析:${NC}"

    # CrashLoopBackOff 详情
    if [ "$crashloop" -gt 0 ]; then
        print_warn "CrashLoopBackOff Pod（$crashloop 个）:"
        echo "$all_bad_pods" | grep "CrashLoopBackOff" | head -5 | while IFS=: read -r pod phase reason; do
            local ns=$(echo "$pod" | cut -d/ -f1)
            local name=$(echo "$pod" | cut -d/ -f2)
            local exit_code
            print_cmd "kubectl get pod $name -n $ns -o jsonpath='{...exitCode...}'"
            exit_code=$(safe_kubectl get pod "$name" -n "$ns" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null)
            local hint=""
            case "$exit_code" in
                137) hint=" → OOMKilled（内存不足），需增加 resources.limits.memory" ;;
                1) hint=" → 应用错误（exit 1），查看应用日志" ;;
                139) hint=" → Segfault，可能是镜像/依赖问题" ;;
                "") hint=" → 无退出码，查看日志" ;;
                *) hint=" → exit code: $exit_code" ;;
            esac
            print_sub "$pod$hint"
        done
        add_issue "WARNING" \
            "$crashloop 个 Pod 处于 CrashLoopBackOff（容器启动后崩溃退避）" \
            "# 查看崩溃日志:\nkubectl logs <pod-name> -n <namespace>\nkubectl logs <pod-name> -n <namespace> --previous\n# 查看退出码和事件:\nkubectl describe pod <pod-name> -n <namespace> | grep -A5 'Last State'"
    fi

    # CreateContainerConfigError 详情
    if [ "$create_config_err" -gt 0 ]; then
        print_warn "CreateContainerConfigError Pod（$create_config_err 个）:"
        echo "$all_bad_pods" | grep "CreateContainerConfigError" | head -3 | while IFS=: read -r pod phase reason; do
            local ns=$(echo "$pod" | cut -d/ -f1)
            local name=$(echo "$pod" | cut -d/ -f2)
            local err_detail
            print_cmd "kubectl describe pod $name -n $ns | grep -iE 'stale NFS|...'"
            err_detail=$(safe_kubectl describe pod "$name" -n "$ns" 2>/dev/null | grep -iE "stale NFS|not found|subPath|secret|configmap" | head -1)
            print_sub "$pod → $err_detail"
        done
        add_issue "WARNING" \
            "$create_config_err 个 Pod 处于 CreateContainerConfigError（可能 stale NFS / subPath / Secret 缺失）" \
            "# 查看 Pod 详情:\nkubectl describe pod <pod-name> -n <namespace> | grep -A3 Error\n# 如果是 stale NFS file handle，delete Pod 重建即可:\nkubectl delete pod <pod-name> -n <namespace>\n# 批量重建:\nkubectl get pods -A | grep CreateContainerConfigError | awk '{print \$1, \$2}' | while read ns name; do kubectl delete pod -n \$ns \$name; done"
    fi

    # Pending 详情
    if [ "$pending" -gt 0 ]; then
        print_warn "Pending Pod（$pending 个）:"
        echo "$all_bad_pods" | grep "Pending" | head -3 | while IFS=: read -r pod phase reason; do
            local ns=$(echo "$pod" | cut -d/ -f1)
            local name=$(echo "$pod" | cut -d/ -f2)
            local sched_msg
            print_cmd "kubectl get pod $name -n $ns -o jsonpath='{...PodScheduled...}'"
            sched_msg=$(safe_kubectl get pod "$name" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null | head -1)
            print_sub "$pod → $sched_msg"
        done
        add_issue "WARNING" \
            "$pending 个 Pod 处于 Pending（调度失败或等待资源）" \
            "# 查看 Pending 原因:\nkubectl describe pod <pod-name> -n <namespace> | tail -10\n# 常见: 资源不足/节点污点/PVC未绑定/nodeSelector不匹配"
    fi

    # OOMKilled 详情
    if [ "$oom_killed" -gt 0 ]; then
        local oom_pods_list
        oom_pods_list=$(echo "$all_pod_data" | grep ":OOMKilled:" | awk -F: '{print $1}' | head -5)
        print_warn "OOMKilled Pod（$oom_killed 个，已重启恢复但需关注）:"
        echo "$oom_pods_list" | while read -r line; do [ -n "$line" ] && print_sub "$line"; done
        add_issue "WARNING" \
            "$oom_killed 个 Pod 曾因 OOMKilled 重启（内存不足）" \
            "# 增加内存限制:\nkubectl patch deploy <name> -n <ns> --type='json' -p='[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/resources/limits/memory\", \"value\":\"512Mi\"}]'\n# 或排查内存泄漏:\nkubectl logs <pod> -n <ns> --previous | tail -50"
    fi

    # Evicted 详情
    if [ "$evicted" -gt 0 ]; then
        print_warn "Evicted Pod（$evicted 个）:"
        echo "$all_bad_pods" | while IFS=: read -r pod phase reason; do
            local ns=$(echo "$pod" | cut -d/ -f1)
            local name=$(echo "$pod" | cut -d/ -f2)
            local pod_reason
            print_cmd "kubectl get pod $name -n $ns -o jsonpath='{.status.reason}'"
            pod_reason=$(safe_kubectl get pod "$name" -n "$ns" -o jsonpath='{.status.reason}' 2>/dev/null)
            if [ "$pod_reason" = "Evicted" ]; then
                local evict_msg
                evict_msg=$(safe_kubectl get pod "$name" -n "$ns" -o jsonpath='{.status.message}' 2>/dev/null | head -1)
                print_sub "$pod → $evict_msg"
            fi
        done | head -5
        add_issue "WARNING" \
            "$evicted 个 Pod 被驱逐（节点资源不足）" \
            "# 查看 Pod 驱逐原因:\nkubectl describe pod <pod-name> -n <namespace>\n# 检查节点资源:\nkubectl describe node <node-name> | grep -A10 Conditions\n# delete 被驱逐的 Pod 让控制器重建:\nkubectl delete pod <pod-name> -n <namespace>"
    fi
}

#==============================================================================
# 模块8：事件检查
#==============================================================================
check_events() {
    print_section "8. 集群事件检查"

    # 最近 1 小时的 Warning 事件
    local warn_events
    print_cmd "kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp'"
    warn_events=$(safe_kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -20)
    if [ -n "$warn_events" ] && [ "$(echo "$warn_events" | grep -c -v "^NAME")" -gt 0 ]; then
        local event_count
        event_count=$(echo "$warn_events" | grep -c -v "^NAME")
        print_warn "发现 $event_count 个 Warning 事件（最近）:"
        echo "$warn_events" | tail -10 | while read -r line; do
            # 截取关键信息：命名空间、原因、对象、消息
            print_sub "$(echo "$line" | awk '{print $1, $2, $4, $5, substr($0, index($0,$6))}' | cut -c1-120)"
        done
        add_issue "INFO" \
            "集群中有 $event_count 个 Warning 事件" \
            "# 查看完整事件列表:\nkubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp'"
    else
        print_ok "无 Warning 事件"
    fi

    # 检查高频事件（同一事件出现多次）
    local frequent_events
    print_cmd "kubectl get events -A | awk '{print \$4}' | sort | uniq -c | sort -rn"
    frequent_events=$(safe_kubectl get events -A --sort-by='.lastTimestamp' 2>/dev/null | awk 'NR>1{print $4}' | sort | uniq -c | sort -rn | head -5 | awk '$1>10{print $1"次: "$2}')
    if [ -n "$frequent_events" ]; then
        print_warn "高频事件（出现超过 10 次）:"
        echo "$frequent_events" | while read -r line; do print_sub "$line"; done
    fi
}

#==============================================================================
# 模块9：关键组件专项检查
#==============================================================================
check_key_components() {
    print_section "9. 关键组件专项检查"

    # metrics-server
    local ms_pods
    print_cmd "kubectl get pods -n kube-system -l k8s-app=metrics-server"
    ms_pods=$(safe_kubectl get pods -n kube-system -l k8s-app=metrics-server -o wide 2>/dev/null)
    if [ -z "$ms_pods" ]; then
        ms_pods=$(safe_kubectl get pods -n kube-system -l app=metrics-server -o wide 2>/dev/null)
    fi
    if [ -n "$ms_pods" ]; then
        local bad_ms
        bad_ms=$(echo "$ms_pods" | awk 'NR>1 && $3!="Running"{print $1" ("$3")"}')
        if [ -n "$bad_ms" ]; then
            print_fail "metrics-server 异常: $bad_ms"
            add_issue "WARNING" \
                "metrics-server Pod 异常: $bad_ms" \
                "# 查看 metrics-server 日志:\nkubectl logs -n kube-system <pod-name> --tail=30\n# 重启:\nkubectl delete pod -n kube-system <pod-name>"
        else
            print_ok "metrics-server 正常运行"
        fi
    else
        print_info "未检测到 metrics-server（kubectl top 命令将不可用）"
    fi

    # 检查 Deployment 副本数
    local deploys
    print_cmd "kubectl get deploy -A"
    deploys=$(safe_kubectl get deploy -A 2>/dev/null | awk 'NR>1{split($3,a,"/"); if(a[1]!=a[2]) print $1"/"$2": READY="$3" UP-TO-DATE="$4" AVAILABLE="$5}')
    if [ -n "$deploys" ]; then
        local deploy_count
        deploy_count=$(echo "$deploys" | grep -c .)
        print_warn "$deploy_count 个 Deployment 副本数不匹配:"
        echo "$deploys" | head -10 | while read -r line; do print_sub "$line"; done
        [ "$deploy_count" -gt 10 ] && print_sub "...（共 $deploy_count 个）"
        add_issue "INFO" \
            "$deploy_count 个 Deployment 的可用副本数不等于期望副本数" \
            "# 检查:\nkubectl get deploy <name> -n <ns>\nkubectl describe deploy <name> -n <ns>"
    else
        print_ok "所有 Deployment 副本数正常"
    fi

    # 检查节点 kubelet 证书过期（仅检查当前节点）
    if [ -f /etc/kubernetes/pki/apiserver.crt ]; then
        local cert_expiry
        print_cmd "openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate"
        cert_expiry=$(openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate 2>/dev/null | cut -d= -f2)
        if [ -n "$cert_expiry" ]; then
            local expiry_epoch
            expiry_epoch=$(date -d "$cert_expiry" +%s 2>/dev/null)
            local now_epoch
            now_epoch=$(date +%s)
            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
            if [ "$days_left" -lt 30 ]; then
                print_fail "apiserver 证书将在 ${days_left} 天后过期（$cert_expiry）"
                add_issue "CRITICAL" \
                    "apiserver 证书将在 ${days_left} 天后过期" \
                    "# 续期证书:\nkubeadm certs renew all\n# 重启控制面组件:\nkill -s SIGHUP \$(pidof kube-apiserver)\nkill -s SIGHUP \$(pidof kube-controller-manager)\nkill -s SIGHUP \$(pidof kube-scheduler)"
            else
                print_ok "apiserver 证书有效期充足（剩余 ${days_left} 天）"
            fi
        fi
    fi
}

#==============================================================================
# 修复执行模块
#==============================================================================
execute_fix() {
    print_section "自动修复（--fix 模式）"

    echo -e "${YELLOW}仅执行安全操作：delete 异常 Pod 触发控制器重建${NC}"
    echo -e "${YELLOW}不修改任何控制器配置，不执行毁灭性命令${NC}"
    echo -e "${DIM}（static pod / 业务 CrashLoopBackOff 不自动处理）${NC}"
    echo ""

    local total_fixed=0

    # 记录修复前的异常 Pod 数
    local before_count
    before_count=$(safe_kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l)

    # ---- 1. 重建镜像拉取失败的 Pod（ImagePullBackOff + ErrImagePull）----
    echo -e "${CYAN}[1/4] 重建镜像拉取失败的 Pod（ImagePullBackOff / ErrImagePull）...${NC}"
    local pull_pods
    pull_pods=$(safe_kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null | grep -E "ImagePullBackOff|ErrImagePull" | awk '{print $1, $2}')
    if [ -n "$pull_pods" ]; then
        local count=0
        echo "$pull_pods" | while read -r ns name; do
            [ -z "$ns" ] || [ -z "$name" ] && continue
            if kubectl delete pod -n "$ns" "$name" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} deleted: $ns/$name"
            else
                echo -e "  ${RED}✗${NC} failed: $ns/$name"
            fi
        done
        count=$(echo "$pull_pods" | grep -c .)
        total_fixed=$((total_fixed+count))
        echo -e "  ${DIM}共处理 $count 个${NC}"
    else
        echo -e "  ${DIM}无镜像拉取失败的 Pod${NC}"
    fi
    echo ""

    # ---- 2. 重建 CreateContainerConfigError Pod（stale NFS / subPath 问题）----
    echo -e "${CYAN}[2/4] 重建 CreateContainerConfigError Pod（stale NFS / subPath）...${NC}"
    local config_pods
    config_pods=$(safe_kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o jsonpath='{range .items[?(@.status.containerStatuses[0].state.waiting.reason=="CreateContainerConfigError")]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null)
    if [ -n "$config_pods" ]; then
        local count=0
        echo "$config_pods" | while read -r ns name; do
            [ -z "$ns" ] || [ -z "$name" ] && continue
            if kubectl delete pod -n "$ns" "$name" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} deleted: $ns/$name"
            else
                echo -e "  ${RED}✗${NC} failed: $ns/$name"
            fi
        done
        count=$(echo "$config_pods" | grep -c .)
        total_fixed=$((total_fixed+count))
        echo -e "  ${DIM}共处理 $count 个${NC}"
    else
        echo -e "  ${DIM}无 CreateContainerConfigError Pod${NC}"
    fi
    echo ""

    # ---- 3. 重启系统命名空间中异常的 Pod（kube-system / calico-system）----
    echo -e "${CYAN}[3/4] 重启系统命名空间异常 Pod（kube-system / calico-system）...${NC}"
    echo -e "  ${DIM}仅处理 CrashLoopBackOff/ImagePullBackOff 的非 static pod${NC}"
    local sys_fixed=0
    for sys_ns in kube-system calico-system; do
        local sys_pods
        sys_pods=$(safe_kubectl get pods -n "$sys_ns" --field-selector=status.phase!=Running,status.phase!=Succeeded -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null | grep -E "CrashLoopBackOff|ImagePullBackOff|ErrImagePull" | grep -vE "kube-apiserver|kube-scheduler|kube-controller-manager|etcd-")
        if [ -n "$sys_pods" ]; then
            echo "$sys_pods" | while read -r name reason; do
                [ -z "$name" ] && continue
                if kubectl delete pod -n "$sys_ns" "$name" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} deleted: $sys_ns/$name ($reason)"
                else
                    echo -e "  ${RED}✗${NC} failed: $sys_ns/$name"
                fi
            done
            sys_fixed=$((sys_fixed+$(echo "$sys_pods" | grep -c .)))
        fi
    done
    if [ "$sys_fixed" -eq 0 ]; then
        echo -e "  ${DIM}系统命名空间无异常 Pod${NC}"
    fi
    total_fixed=$((total_fixed+sys_fixed))
    echo ""

    # ---- 4. 统计跳过的不可自动修复的问题 ----
    echo -e "${CYAN}[4/4] 跳过的不可自动修复问题（需人工处理）:${NC}"
    local skipped_crash=0
    local skipped_other=0

    # 业务命名空间的 CrashLoopBackOff（需人工判断崩溃原因）
    local biz_crash
    biz_crash=$(safe_kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o jsonpath='{range .items[?(@.status.containerStatuses[0].state.waiting.reason=="CrashLoopBackOff")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -vE "^kube-system/|^calico-system/")
    if [ -n "$biz_crash" ]; then
        skipped_crash=$(echo "$biz_crash" | grep -c .)
        echo -e "  ${YELLOW}→${NC} $skipped_crash 个业务 Pod CrashLoopBackOff（需查看应用日志判断崩溃原因）"
        echo "$biz_crash" | head -5 | while read -r line; do echo -e "    $line"; done
        [ "$skipped_crash" -gt 5 ] && echo -e "    ...(共 $skipped_crash 个)"
    fi

    # Pending Pod（调度问题，需人工判断）
    local pending_pods
    pending_pods=$(safe_kubectl get pods -A --field-selector=status.phase=Pending -o jsonpath='{range .items[?(@.status.containerStatuses[0].state.waiting.reason!="ImagePullBackOff" && @.status.containerStatuses[0].state.waiting.reason!="ErrImagePull")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)
    if [ -n "$pending_pods" ]; then
        local pcount
        pcount=$(echo "$pending_pods" | grep -c .)
        echo -e "  ${YELLOW}→${NC} $pcount 个 Pending Pod（调度失败，需检查资源/污点/PVC）"
    fi

    # OOMKilled Pod（需调整资源限制）
    local oom_pods
    oom_pods=$(safe_kubectl get pods -A -o jsonpath='{range .items[?(@.status.containerStatuses[0].lastState.terminated.reason=="OOMKilled")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)
    if [ -n "$oom_pods" ]; then
        local ocount
        ocount=$(echo "$oom_pods" | grep -c .)
        echo -e "  ${YELLOW}→${NC} $ocount 个 OOMKilled Pod（需增加内存限制或排查内存泄漏）"
    fi

    if [ "$skipped_crash" -eq 0 ] && [ -z "$pending_pods" ] && [ -z "$oom_pods" ]; then
        echo -e "  ${DIM}无需人工处理的问题${NC}"
    fi
    echo ""

    # ---- 修复后验证 ----
    echo -e "${CYAN}等待 Pod 重建...${NC}"
    sleep 30

    local after_count
    after_count=$(safe_kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l)

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  修复报告${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  自动修复 Pod 数: ${GREEN}$total_fixed${NC}"
    echo -e "  修复前异常 Pod: $before_count"
    echo -e "  修复后异常 Pod: $after_count"
    if [ "$after_count" -lt "$before_count" ]; then
        echo -e "  变化: ${GREEN}减少 $((before_count-after_count)) 个${NC}"
    elif [ "$after_count" -gt "$before_count" ]; then
        echo -e "  变化: ${YELLOW}增加 $((after_count-before_count)) 个${NC}（重建中的 Pod 尚未就绪，等待片刻后重新检查）"
    else
        echo -e "  变化: ${DIM}无变化${NC}"
    fi
    echo ""
    echo -e "  ${GREEN}自动修复完成。${NC}"
    echo -e "  ${YELLOW}注意:${NC}"
    echo -e "    - 镜像 tag 不存在的 Pod 重建后仍会失败，需先推送正确镜像"
    echo -e "    - CrashLoopBackOff 的业务 Pod 需人工查看日志判断崩溃原因"
    echo -e "    - OOMKilled 的 Pod 需调整 resources.limits.memory"
    echo -e "    - Pending Pod 需检查资源/污点/PVC 绑定"
    echo -e "    - 修复后建议重新运行: ${CYAN}./k8s-diagnose.sh${NC}"
}

#==============================================================================
# 报告生成模块
#==============================================================================
generate_report() {
    print_section "诊断报告"

    # 健康评分
    local score=100
    for level in "${ISSUE_LEVEL[@]}"; do
        case "$level" in
            CRITICAL) score=$((score-15)) ;;
            WARNING) score=$((score-5)) ;;
            INFO) score=$((score-1)) ;;
        esac
    done
    [ "$score" -lt 0 ] && score=0

    local score_color
    if [ "$score" -ge 90 ]; then
        score_color="$GREEN"
    elif [ "$score" -ge 70 ]; then
        score_color="$YELLOW"
    else
        score_color="$RED"
    fi

    echo -e "  ${BOLD}集群健康评分: ${score_color}${score}/100${NC}"
    echo -e "  检查项统计: ${GREEN}正常=$OK_COUNT${NC}  ${YELLOW}警告=$WARN_COUNT${NC}  ${RED}异常=$FAIL_COUNT${NC}"
    echo -e "  发现问题: $ISSUE_COUNT 个（CRITICAL/WARNING/INFO）"

    if [ "$ISSUE_COUNT" -eq 0 ]; then
        echo ""
        echo -e "  ${GREEN}${BOLD}✓ 集群状态健康，未发现异常问题${NC}"
        return
    fi

    # 按严重级别输出问题
    echo ""
    echo -e "  ${BOLD}━━━ 问题清单与修复建议 ━━━${NC}"
    echo ""

    # CRITICAL 问题
    local has_critical=false
    for i in "${!ISSUE_LEVEL[@]}"; do
        if [ "${ISSUE_LEVEL[$i]}" = "CRITICAL" ]; then
            has_critical=true
            echo -e "  ${RED}${BOLD}[CRITICAL]${NC} ${ISSUE_DESC[$i]}"
            echo -e "  ${DIM}修复建议:${NC}"
            echo "${ISSUE_FIX[$i]}" | while read -r line; do
                [ -n "$line" ] && echo -e "    $line"
            done
            echo ""
        fi
    done

    # WARNING 问题
    local has_warning=false
    for i in "${!ISSUE_LEVEL[@]}"; do
        if [ "${ISSUE_LEVEL[$i]}" = "WARNING" ]; then
            has_warning=true
            echo -e "  ${YELLOW}${BOLD}[WARNING]${NC} ${ISSUE_DESC[$i]}"
            echo -e "  ${DIM}修复建议:${NC}"
            echo "${ISSUE_FIX[$i]}" | while read -r line; do
                [ -n "$line" ] && echo -e "    $line"
            done
            echo ""
        fi
    done

    # INFO 问题
    for i in "${!ISSUE_LEVEL[@]}"; do
        if [ "${ISSUE_LEVEL[$i]}" = "INFO" ]; then
            echo -e "  ${CYAN}${BOLD}[INFO]${NC} ${ISSUE_DESC[$i]}"
            echo -e "  ${DIM}修复建议:${NC}"
            echo "${ISSUE_FIX[$i]}" | while read -r line; do
                [ -n "$line" ] && echo -e "    $line"
            done
            echo ""
        fi
    done

    # 提示
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}提示:${NC}"
    echo -e "  - CRITICAL 问题需立即处理，可能导致集群不可用"
    echo -e "  - WARNING 问题建议尽快处理，影响部分功能"
    echo -e "  - INFO 问题可择机处理，不影响集群运行"
    echo -e "  - 使用 ${CYAN}--fix${NC} 参数可自动执行安全修复（重建异常 Pod）"
    echo -e "  - 所有修复命令均为安全操作（delete pod 触发重建），不含毁灭性命令"
}

#==============================================================================
# 主函数
#==============================================================================
main() {
    # 解析参数
    while [ $# -gt 0 ]; do
        case "$1" in
            --fix) AUTO_FIX=true ;;
            --verbose|-v) VERBOSE=true ;;
            --help|-h)
                echo "用法: $0 [--fix] [--verbose]"
                echo "  --fix      诊断后自动执行安全修复"
                echo "  --verbose  显示详细诊断过程"
                exit 0
                ;;
            *) echo "未知参数: $1"; exit 1 ;;
        esac
        shift
    done

    print_banner
    echo -e "  ${DIM}开始时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "  ${DIM}运行模式: $([ "$AUTO_FIX" = true ] && echo '诊断+修复' || echo '仅诊断')${NC}"
    echo -e "  ${DIM}流程: 分析阶段(模块0-9) → 诊断报告 → $([ "$AUTO_FIX" = true ] && echo '自动修复' || echo '仅给建议')${NC}"

    # ============================================================
    # 第一阶段：全面分析（逐模块检查，收集所有问题）
    # ============================================================
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  第一阶段：全面分析（逐模块检查集群各层状态）               ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"

    check_prerequisites
    check_nodes
    check_control_plane
    check_network
    check_dns
    check_storage
    check_image_pull
    check_pods
    check_events
    check_key_components

    # ============================================================
    # 第二阶段：诊断报告（汇总所有发现的问题 + 修复建议）
    # ============================================================
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  第二阶段：诊断报告（问题清单 + 修复建议 + 命令）           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"

    generate_report

    # ============================================================
    # 第三阶段：自动修复（仅 --fix 模式下执行，安全操作）
    # ============================================================
    if [ "$AUTO_FIX" = true ]; then
        echo ""
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║  第三阶段：自动修复（仅安全操作：delete 异常 Pod 触发重建） ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
        execute_fix
    else
        echo ""
        echo -e "  ${DIM}提示: 使用 ${CYAN}--fix${NC}${DIM} 参数可自动修复可安全修复的问题${NC}"
    fi

    echo ""
    echo -e "  ${DIM}结束时间: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo ""

    # 退出码：有 CRITICAL 问题返回 1，否则返回 0
    for level in "${ISSUE_LEVEL[@]}"; do
        [ "$level" = "CRITICAL" ] && exit 1
    done
    exit 0
}

main "$@"

#!/usr/bin/env bash
# ============================================================================
# app-export —— 从当前集群导出指定 namespace 的全部资源 + 镜像，生成交付包
# ============================================================================
# 用法:
#   ./app-export.sh <ns1,ns2> [输出目录]
#   ./app-export.sh db-lianantech-hk-release              # 默认输出到 deploy/artifacts/
#   SKIP_IMAGES=true ./app-export.sh myns                 # 只导 YAML，不导镜像 tar
#
# 产出目录结构（可直接传输到内网目标机重放）:
#   <out>/manifests/cluster/         关联的 PV/StorageClass（部署优先）
#   <out>/manifests/<ns>/            namespace 全部资源（动态发现，剔除运行时资源）
#   <out>/images/app-images.tar      镜像（containerd 导出，含 sha256）
#   <out>/images.txt                 镜像清单
#   <out>/scripts/{app-load-images.sh,app-deploy.sh}  重放工具
#   <out>/VERSION.txt                包信息
#   <out>/app-bundle-<ns>-<ts>.tar.gz 最终交付包
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '[%s] INFO: %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] FATAL: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

NAMESPACES="${1:-}"
OUT_BASE="${2:-$(cd "$SCRIPT_DIR/../artifacts" 2>/dev/null && pwd || pwd)/app-export}"
[[ -n "$NAMESPACES" ]] || { echo "用法: $0 <ns1,ns2> [输出目录]"; exit 1; }

# 归一化架构 (OCI 平台格式)
case "$(uname -m)" in aarch64|arm64) ARCH="arm64" ;; *) ARCH="amd64" ;; esac

command -v kubectl >/dev/null || fatal "缺少 kubectl"
command -v crictl >/dev/null  || fatal "缺少 crictl"
command -v ctr >/dev/null     || fatal "缺少 ctr"
kubectl get nodes >/dev/null 2>&1 || fatal "无法连接 K8s 集群"
[[ $EUID -eq 0 ]] || warn "当前非 root：crictl/ctr 导出镜像大概率失败，建议 sudo 执行"

TIMESTAMP=$(date '+%Y%m%d%H%M%S')
NS_LABEL=$(echo "$NAMESPACES" | tr ',' '-')
OUT_DIR="${OUT_BASE}/${NS_LABEL}-${TIMESTAMP}"
MANIFESTS_DIR="$OUT_DIR/manifests"
IMAGES_DIR="$OUT_DIR/images"
IMAGES_TXT="$OUT_DIR/images.txt"

# 运行时自动生成的资源不导出（重放时由控制器重建）
EXCLUDE_NAMES="kube-root-ca.crt default"
EXCLUDE_KINDS="events events.events.k8s.io pods pods.metrics.k8s.io replicasets.apps replicationcontrollers endpoints endpointslices.discovery.k8s.io controllerrevisions.apps leases.coordination.k8s.io podtemplates csistoragecapacities.storage.k8s.io"

# ─── 清理 YAML 只读字段 ──────────────────────────────────────────────────────
clean_yaml() {
  python3 - "$1" <<'PYEOF' 2>/dev/null || true
import sys, yaml
file = sys.argv[1]
with open(file) as f:
    data = yaml.safe_load(f)
if data:
    md = data.get('metadata', {})
    for k in ('uid', 'resourceVersion', 'creationTimestamp', 'generation', 'managedFields', 'selfLink', 'ownerReferences'):
        md.pop(k, None)
    if 'status' in data:
        del data['status']
    with open(file, 'w') as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
PYEOF
}

should_skip() {
  local name="$1"
  for ex in $EXCLUDE_NAMES; do [[ "$name" == "$ex" ]] && return 0; done
  [[ "$name" == sh.helm.release.* ]] && return 0
  return 1
}

# ─── 导出 namespace 全部资源（动态发现）──────────────────────────────────────
export_namespace_resources() {
  local ns="$1" ns_dir="$2" total=0
  local ns_resources
  ns_resources=$(kubectl api-resources --namespaced=true --verbs=list -o name 2>/dev/null | sort)
  for kind in $ns_resources; do
    local skip=false
    for ex_kind in $EXCLUDE_KINDS; do [[ "$kind" == "$ex_kind" ]] && { skip=true; break; }; done
    $skip && continue
    local items
    items=$(kubectl get "$kind" -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    [[ -z "$items" ]] && continue
    for item in $items; do
      should_skip "$item" && continue
      local safe_kind="${kind//\//_}"
      local outfile="$ns_dir/${safe_kind}_${item}.yaml"
      if kubectl get "$kind" "$item" -n "$ns" -o yaml > "$outfile" 2>/dev/null; then
        clean_yaml "$outfile"; total=$((total+1))
      else
        warn "  导出失败: $kind/$item (ns=$ns)"; rm -f "$outfile"
      fi
    done
  done
  log "  $ns: 导出 $total 个资源"
}

# ─── 关联的 PV / StorageClass ────────────────────────────────────────────────
export_cluster_resources() {
  local pv_names="$1" sc_names="$2"
  local cluster_dir="$MANIFESTS_DIR/cluster"; mkdir -p "$cluster_dir"
  for pv in $(echo "$pv_names" | xargs); do
    kubectl get pv "$pv" -o yaml > "$cluster_dir/persistentvolume_${pv}.yaml" 2>/dev/null && clean_yaml "$cluster_dir/persistentvolume_${pv}.yaml" \
      && log "  导出 PV: $pv" || warn "  导出 PV 失败: $pv"
  done
  for sc in $(echo "$sc_names" | tr ' ' '\n' | sort -u); do
    [[ -z "$sc" ]] && continue
    kubectl get sc "$sc" -o yaml > "$cluster_dir/storageclass_${sc}.yaml" 2>/dev/null && clean_yaml "$cluster_dir/storageclass_${sc}.yaml" \
      && log "  导出 SC: $sc" || warn "  导出 SC 失败: $sc"
  done
}

# ─── 镜像清单 + containerd 匹配 + 导出 ───────────────────────────────────────
export_images() {
  # 从 YAML 提取 image 字段
  find "$MANIFESTS_DIR" -name '*.yaml' -exec grep -h 'image:' {} \; 2>/dev/null \
    | sed 's/.*image:\s*//; s/^ *"//; s/"$//' \
    | grep -v '^$' | sort -u > "$IMAGES_TXT" || true
  local count; count=$(wc -l < "$IMAGES_TXT")
  log "解析到 $count 个镜像"
  [[ "$count" -eq 0 ]] && { warn "无镜像引用"; return; }
  [[ "${SKIP_IMAGES:-false}" == "true" ]] && { warn "SKIP_IMAGES=true，跳过镜像导出"; return; }

  mkdir -p "$IMAGES_DIR"
  local containerd_images
  containerd_images=$(crictl images -o json 2>/dev/null \
    | python3 -c "import sys,json; data=json.load(sys.stdin); [print(t) for img in data.get('images',[]) for t in img.get('repoTags',[]) if t]" 2>/dev/null || true)

  local found_images=() found=0 notfound=0
  while IFS= read -r img; do
    [[ -z "$img" ]] && continue
    local matched="" candidates=("$img")
    if [[ "$img" != */* ]]; then candidates+=("docker.io/library/$img")
    elif [[ "$img" != docker.io/* && "$img" != registry.k8s.io/* && "$img" != quay.io/* && "$img" != ghcr.io/* ]]; then candidates+=("docker.io/$img"); fi
    for cimg in $containerd_images; do
      local norm="$cimg"
      norm="${norm#docker.io/library/}"; norm="${norm#docker.io/}"
      norm="${norm#registry.k8s.io/}";   norm="${norm#quay.io/}"
      for cand in "${candidates[@]}"; do
        [[ "$cimg" == "$cand" || "$norm" == "$img" ]] && { matched="$cimg"; break 2; }
      done
    done
    if [[ -n "$matched" ]]; then found_images+=("$matched"); found=$((found+1)); log "  找到: $matched"
    else warn "  未在 containerd 中找到: $img"; notfound=$((notfound+1)); fi
  done < "$IMAGES_TXT"

  log "镜像统计: 找到 $found, 未找到 $notfound"
  [[ ${#found_images[@]} -eq 0 ]] && { warn "无可导出镜像"; return; }

  local unique; unique=$(printf '%s\n' "${found_images[@]}" | sort -u)
  log "导出 $(echo "$unique" | wc -l) 个镜像 → images/app-images.tar (linux/$ARCH)"
  ctr -n k8s.io images export --platform "linux/$ARCH" "$IMAGES_DIR/app-images.tar" $unique || fatal "镜像导出失败"
  (cd "$IMAGES_DIR" && sha256sum app-images.tar > app-images.tar.sha256)
  log "镜像导出完成"
}

# ─── 打包 ────────────────────────────────────────────────────────────────────
package_bundle() {
  mkdir -p "$OUT_DIR/scripts"
  cp "$SCRIPT_DIR/app-load-images.sh" "$SCRIPT_DIR/app-deploy.sh" "$OUT_DIR/scripts/"
  cat > "$OUT_DIR/VERSION.txt" <<EOF
业务应用离线交付包
打包时间: $(date '+%Y-%m-%d %H:%M:%S')
架构: $ARCH
Namespace: $NAMESPACES
镜像数量: $(wc -l < "$IMAGES_TXT" 2>/dev/null || echo 0)
资源文件: $(find "$MANIFESTS_DIR" -name '*.yaml' 2>/dev/null | wc -l)

目标机重放步骤:
  1. tar -xzf $(basename "$OUT_DIR").tar.gz
  2. cd $(basename "$OUT_DIR") && sudo bash scripts/app-deploy.sh
EOF
  local tar_file="$OUT_DIR.tar.gz"
  tar -czf "$tar_file" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")"
  (cd "$(dirname "$tar_file")" && sha256sum "$(basename "$tar_file")" > "$(basename "$tar_file").sha256")
  log "========================================"
  log "打包完成: $tar_file ($(du -h "$tar_file" | awk '{print $1}'))"
  log "========================================"
}

# ─── 主流程 ──────────────────────────────────────────────────────────────────
mkdir -p "$MANIFESTS_DIR"
IFS=',' read -ra NS_ARRAY <<< "$NAMESPACES"
pv_names=""; sc_names=""
for ns in "${NS_ARRAY[@]}"; do
  ns=$(echo "$ns" | xargs)
  kubectl get ns "$ns" >/dev/null 2>&1 || { warn "namespace '$ns' 不存在，跳过"; continue; }
  mkdir -p "$MANIFESTS_DIR/$ns"
  log "导出 namespace: $ns"
  export_namespace_resources "$ns" "$MANIFESTS_DIR/$ns"
  for pvc in $(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    p=$(kubectl get pvc "$pvc" -n "$ns" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
    s=$(kubectl get pvc "$pvc" -n "$ns" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
    [[ -n "$p" ]] && pv_names="$pv_names $p"
    [[ -n "$s" ]] && sc_names="$sc_names $s"
  done
done
export_cluster_resources "$pv_names" "$sc_names"
export_images
package_bundle
log "完成！输出目录: $OUT_DIR"

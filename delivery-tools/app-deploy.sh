#!/usr/bin/env bash
# ============================================================================
# app-deploy —— 在目标 K8s 集群重放业务应用（配合 app-export.sh 交付包）
# ============================================================================
# 用法（交付包内执行）:
#   sudo bash scripts/app-deploy.sh [包根目录]
#   SKIP_IMAGES=true ./scripts/app-deploy.sh   # 跳过镜像导入（镜像已就绪时）
#
# 流程: 导入镜像(app-load-images.sh) → cluster/ PV+SC 优先 apply →
#       manifests/<ns>/ 按资源优先级排序 apply（namespace→sa→rbac→configmap→
#       secret→pvc→service→ingress→deployment→sts→ds→cronjob→job→其他）
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${1:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MANIFESTS_DIR="$APP_DIR/manifests"

log()  { printf '[%s] INFO: %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] FATAL: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

command -v kubectl >/dev/null || fatal "缺少 kubectl"
kubectl get nodes >/dev/null 2>&1 || fatal "无法连接 K8s 集群"
[[ -d "$MANIFESTS_DIR" ]] || fatal "缺少 manifests 目录: $MANIFESTS_DIR"

# ─── 镜像导入（委托 app-load-images.sh）──────────────────────────────────────
if [[ "${SKIP_IMAGES:-false}" == "true" ]]; then
  log "跳过镜像导入 (SKIP_IMAGES=true)"
else
  IMAGES_SRC="$APP_DIR/images"
  [[ -d "$IMAGES_SRC" ]] || { warn "无 images 目录，跳过导入"; }
  if [[ -d "$IMAGES_SRC" ]]; then
    log "导入镜像 ..."
    bash "$SCRIPT_DIR/app-load-images.sh" "$(dirname "$(find "$IMAGES_SRC" -name '*.tar' 2>/dev/null | head -1)")" \
      || fatal "镜像导入失败，中止部署（镜像已就绪可用 SKIP_IMAGES=true 跳过）"
  fi
fi

# ─── 资源优先级排序 ───────────────────────────────────────────────────────────
sort_yaml_by_priority() {
  awk '
    BEGIN {
      pri["namespace"]=1; pri["namespaces"]=1
      pri["serviceaccount"]=2; pri["serviceaccounts"]=2
      pri["clusterrole"]=2.5; pri["clusterroles"]=2.5
      pri["role"]=3; pri["roles"]=3
      pri["rolebinding"]=4; pri["rolebindings"]=4
      pri["clusterrolebinding"]=4.5; pri["clusterrolebindings"]=4.5
      pri["customresourcedefinition"]=1.5; pri["customresourcedefinitions"]=1.5
      pri["configmap"]=5; pri["configmaps"]=5
      pri["secret"]=6; pri["secrets"]=6
      pri["persistentvolume"]=6.5; pri["persistentvolumes"]=6.5
      pri["storageclass"]=6.6; pri["storageclasses"]=6.6
      pri["persistentvolumeclaim"]=7; pri["persistentvolumeclaims"]=7
      pri["service"]=9; pri["services"]=9
      pri["ingress"]=10; pri["ingresses"]=10
      pri["deployment"]=11; pri["deployments"]=11
      pri["statefulset"]=12; pri["statefulsets"]=12
      pri["daemonset"]=13; pri["daemonsets"]=13
      pri["cronjob"]=14; pri["cronjobs"]=14
      pri["job"]=15; pri["jobs"]=15
    }
    {
      path=$0; base=path
      sub(/.*\//, "", base); sub(/\.yaml$/, "", base)
      kind=base; sub(/_.*/, "", kind); sub(/\..*/, "", kind)
      p=(kind in pri) ? pri[kind] : 16
      printf "%06.1f\t%s\n", p, path
    }
  ' | sort -k1,1n -k2 | cut -f2-
}

# ─── 部署 ────────────────────────────────────────────────────────────────────
log "=== 重放 $MANIFESTS_DIR ==="

# 1. 集群级资源（PV/SC，PVC 前置依赖）——目录内文件名已带 kind_ 前缀，天然有序
CLUSTER_DIR="$MANIFESTS_DIR/cluster"
if [[ -d "$CLUSTER_DIR" ]] && [[ $(find "$CLUSTER_DIR" -name '*.yaml' | wc -l) -gt 0 ]]; then
  log "[1/2] 部署集群级资源 (PV/StorageClass) ..."
  kubectl apply -f "$CLUSTER_DIR" || warn "集群级资源部分失败（可能已存在且不可变），继续"
fi

# 2. namespace 级资源按优先级 apply
log "[2/2] 部署 namespace 资源（按依赖优先级）..."
mapfile -t ORDERED < <(find "$MANIFESTS_DIR" -mindepth 2 -name '*.yaml' | sort_yaml_by_priority)
[[ ${#ORDERED[@]} -eq 0 ]] && fatal "未找到任何 YAML"

applied=0 failed=0
for f in "${ORDERED[@]}"; do
  rel="${f#$MANIFESTS_DIR/}"
  # 已在 cluster/ 处理过的跳过
  [[ "$rel" == cluster/* ]] && continue
  if kubectl apply -f "$f" >/dev/null 2>&1; then
    log "  [OK] $rel"; applied=$((applied+1))
  else
    warn "  [FAIL] $rel（kubectl apply -f $f 查看详情）"; failed=$((failed+1))
  fi
done

echo ""
log "========================================"
log "重放完成: 成功 $applied / 失败 $failed"
log "========================================"
if [[ $failed -gt 0 ]]; then
  warn "存在失败资源，多为依赖未就绪（PVC/PV 绑定、CRD 缺失），修复后重跑本脚本即可（apply 幂等）"
  exit 1
fi

# 3. 等待工作负载
log "等待 Pod 就绪（Ctrl+C 可跳过观察）..."
kubectl get deploy,sts,ds -A -o name 2>/dev/null | head -20 || true
log "提示: kubectl get pods -A -w 观察就绪状态"

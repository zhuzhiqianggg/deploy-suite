#!/usr/bin/env bash
# deploy_apps.sh - 在内网 K8s 集群部署业务应用
# 用法: ./deploy_apps.sh
#       SKIP_IMAGES=true ./deploy_apps.sh  # 跳过镜像导入
#
# 设计:
#   - 镜像加载交给 load_apps.sh (按镜像列表逐个 ctr import)
#   - 本脚本只负责部署 manifests/ 下的 K8s YAML
#   - 命名空间 (namespace) 是 K8s 资源组织方式, 与镜像打包 (images.conf) 解耦

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFESTS_DIR="$ROOT_DIR/manifests"
IMAGES_DIR="$ROOT_DIR/images"
SCRIPTS_DIR="$ROOT_DIR/scripts"

log()  { printf '[%s] INFO: %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] FATAL: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

# ─── 检查依赖 ───
check_deps() {
  command -v kubectl >/dev/null || fatal "缺少 kubectl"
  command -v ctr >/dev/null || fatal "缺少 ctr（containerd 工具）"
  kubectl get nodes >/dev/null 2>&1 || fatal "无法连接 K8s 集群"

  [[ -d "$MANIFESTS_DIR" ]] || fatal "缺少 manifests 目录: $MANIFESTS_DIR"

  log "依赖检查通过"
}

# ─── 导入镜像到 containerd (委托给 load_apps.sh) ───
import_images() {
  if [[ "${SKIP_IMAGES:-false}" == "true" ]]; then
    log "跳过镜像导入 (SKIP_IMAGES=true)"
    return
  fi

  local load_script="$SCRIPTS_DIR/load_apps.sh"
  if [[ ! -f "$load_script" ]]; then
    warn "load_apps.sh 不存在: $load_script, 跳过镜像导入"
    return
  fi

  log "调用 load_apps.sh 导入镜像..."
  if ! bash "$load_script"; then
    fatal "load_apps.sh 失败, 中止部署"
  fi
  log "镜像导入完成"
}

# ─── 按资源类型优先级排序 YAML 文件 ───
sort_yaml_by_priority() {
  # 输入: 每行一个 YAML 文件路径 (来自 stdin)
  # 输出: 按部署优先级排序后的文件路径
  # 优先级: namespace > serviceaccount > role > rolebinding > configmap
  #         > secret > pvc > service > ingress > deployment
  #         > statefulset > daemonset > cronjob > job > 其他
  awk '
    BEGIN {
      pri["namespace"] = 1;  pri["namespaces"] = 1
      pri["serviceaccount"] = 2;  pri["serviceaccounts"] = 2
      pri["role"] = 3;  pri["roles"] = 3
      pri["rolebinding"] = 4;  pri["rolebindings"] = 4
      pri["configmap"] = 5;  pri["configmaps"] = 5
      pri["secret"] = 6;  pri["secrets"] = 6
      pri["persistentvolumeclaim"] = 7;  pri["persistentvolumeclaims"] = 7
      pri["service"] = 9;  pri["services"] = 9
      pri["ingress"] = 10;  pri["ingresses"] = 10
      pri["deployment"] = 11;  pri["deployments"] = 11
      pri["statefulset"] = 12;  pri["statefulsets"] = 12
      pri["daemonset"] = 13;  pri["daemonsets"] = 13
      pri["cronjob"] = 14;  pri["cronjobs"] = 14
      pri["job"] = 15;  pri["jobs"] = 15
      default_pri = 16
    }
    {
      path = $0
      base = path
      sub(/.*\//, "", base)
      sub(/\.yaml$/, "", base)
      kind = base
      sub(/_.*/, "", kind)
      sub(/\..*/, "", kind)
      p = pri[kind]
      if (p == "") p = default_pri
      printf "%d\t%s\n", p, path
    }
  ' | sort -k1,1n -k2 | cut -f2-
}

# ─── 部署 YAML 资源 ───
deploy_manifests() {
  # 先部署集群级资源（PV/StorageClass），它们是 PVC 的前置依赖
  local cluster_dir="$MANIFESTS_DIR/cluster"
  if [[ -d "$cluster_dir" ]]; then
    local cluster_yaml_count
    cluster_yaml_count=$(find "$cluster_dir" -name '*.yaml' 2>/dev/null | wc -l)
    if [[ "$cluster_yaml_count" -gt 0 ]]; then
      log "部署集群级资源: PV/StorageClass ($cluster_yaml_count 个)"
      local sc_success=0 sc_failed=0 pv_success=0 pv_failed=0
      while IFS= read -r yaml_file; do
        local kind_name
        kind_name=$(basename "$yaml_file" .yaml)
        if kubectl apply -f "$yaml_file" 2>/dev/null; then
          if [[ "$kind_name" == storageclass_* ]]; then
            sc_success=$((sc_success + 1))
          else
            pv_success=$((pv_success + 1))
          fi
        else
          kubectl apply -f "$yaml_file" 2>&1 || true
          if [[ "$kind_name" == storageclass_* ]]; then
            sc_failed=$((sc_failed + 1))
          else
            pv_failed=$((pv_failed + 1))
          fi
          warn "  集群资源部署失败: $kind_name"
        fi
      done < <(find "$cluster_dir" -name '*.yaml' 2>/dev/null | sort)
      log "  StorageClass: 成功 $sc_success, 失败 $sc_failed"
      log "  PersistentVolume: 成功 $pv_success, 失败 $pv_failed"
    fi
  fi

  # 再部署 namespace 级资源
  local ns_dirs=()
  while IFS= read -r dir; do
    ns_dirs+=("$dir")
  done < <(find "$MANIFESTS_DIR" -mindepth 1 -maxdepth 1 -type d -name 'cluster' -prune -o -type d -print | sort)

  if [[ ${#ns_dirs[@]} -eq 0 ]]; then
    fatal "未找到任何 namespace 目录"
  fi

  for ns_dir in "${ns_dirs[@]}"; do
    local ns
    ns=$(basename "$ns_dir")
    local yaml_count
    yaml_count=$(find "$ns_dir" -name '*.yaml' 2>/dev/null | wc -l)

    if [[ "$yaml_count" -eq 0 ]]; then
      warn "namespace '$ns' 下没有 YAML 文件，跳过"
      continue
    fi

    log "部署 namespace: $ns ($yaml_count 个资源)"

    # 确保 namespace 存在
    if ! kubectl get ns "$ns" >/dev/null 2>&1; then
      kubectl create ns "$ns" 2>/dev/null || true
      log "  创建 namespace: $ns"
    fi

    # 部署顺序: 按 K8s 资源依赖关系优先级排序
    # namespace > serviceaccount > role > rolebinding > configmap
    # > secret > pvc > service > ingress > deployment
    # > statefulset > daemonset > cronjob > job > 其他
    local success=0
    local failed=0
    while IFS= read -r yaml_file; do
      local kind_name
      kind_name=$(basename "$yaml_file" .yaml)
      if kubectl apply -f "$yaml_file" 2>/dev/null; then
        success=$((success + 1))
      else
        # 重试一次，显示错误
        if kubectl apply -f "$yaml_file" 2>&1; then
          success=$((success + 1))
        else
          warn "  部署失败: $kind_name"
          failed=$((failed + 1))
        fi
      fi
    done < <(find "$ns_dir" -name '*.yaml' 2>/dev/null | sort_yaml_by_priority)

    log "  $ns: 成功 $success, 失败 $failed"
  done
}

# ─── 验证部署 ───
verify_deployment() {
  echo ""
  log "=== 部署验证 ==="

  # 集群级资源
  if [[ -d "$MANIFESTS_DIR/cluster" ]]; then
    local cluster_count
    cluster_count=$(find "$MANIFESTS_DIR/cluster" -name '*.yaml' 2>/dev/null | wc -l)
    if [[ "$cluster_count" -gt 0 ]]; then
      log "集群级资源:"
      kubectl get pv 2>/dev/null | head -10 || true
      kubectl get sc 2>/dev/null | head -10 || true
      echo ""
    fi
  fi

  # namespace 级资源（跳过 cluster 目录）
  for ns_dir in "$MANIFESTS_DIR"/*/; do
    [[ -d "$ns_dir" ]] || continue
    local ns
    ns=$(basename "$ns_dir")
    [[ "$ns" == "cluster" ]] && continue
    log "namespace: $ns"
    kubectl get deploy,sts,ds,svc,pod -n "$ns" 2>/dev/null || true
    echo ""
  done

  log "等待 Pod 启动 (30s)..."
  sleep 30

  echo ""
  log "=== Pod 状态 ==="
  for ns_dir in "$MANIFESTS_DIR"/*/; do
    [[ -d "$ns_dir" ]] || continue
    local ns
    ns=$(basename "$ns_dir")
    [[ "$ns" == "cluster" ]] && continue
    kubectl get pods -n "$ns" 2>/dev/null || true
  done
}

# ─── 主流程 ───
main() {
  log "=== 业务应用离线部署工具 ==="
  check_deps
  import_images
  deploy_manifests
  verify_deployment
  log "部署完成！"
}

main "$@"

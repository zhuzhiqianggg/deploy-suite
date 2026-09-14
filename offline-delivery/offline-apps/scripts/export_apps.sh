#!/usr/bin/env bash
# export_apps.sh - 从 K8s 集群导出指定 namespace 的全部资源 + 镜像，打包为离线包
# 用法:
#   1. 编辑 apps.conf 填入 namespace 列表，然后执行 ./export_apps.sh
#   2. 或通过环境变量指定: NAMESPACES=app1,app2 ./export_apps.sh
#   3. 或交互式: ./export_apps.sh
#
# 导出范围: namespace 下所有 K8s 资源（动态发现，含 CRD），以及关联的 PV/StorageClass

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFESTS_DIR="$ROOT_DIR/manifests"
IMAGES_DIR="$ROOT_DIR/images"
BUILD_DIR="$ROOT_DIR/build"
CONF_FILE="$ROOT_DIR/apps.conf"

log()  { printf '[%s] INFO: %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%F %T')" "$*"; }
fatal(){ printf '[%s] FATAL: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

# 默认参数
NAMESPACES="${NAMESPACES:-}"

# 读取全局架构配置，归一化为 OCI 格式 (arm64/amd64)
for _p in "$ROOT_DIR/../arch.env" "$ROOT_DIR/arch.env"; do
  if [[ -f "$_p" ]]; then
    # shellcheck disable=SC1090
    source "$_p"
    break
  fi
done
ARCH="${ARCH:-$(uname -m)}"
# 归一化: aarch64 -> arm64, x86_64 -> amd64 (OCI 平台用 arm64/amd64)
case "$ARCH" in
  aarch64|arm64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="amd64" ;;
esac

# 排除的资源名（系统自动生成的，不需要导出）
EXCLUDE_NAMES="kube-root-ca.crt default"

# 排除的资源类型（运行时自动生成，部署时不需要，重新部署会自动重建）
# events: 事件日志，新集群会自动生成
# pods: Pod 由 Deployment/StatefulSet 管理器自动创建
# replicasets: 由 Deployment 管理器自动创建
# replicationcontrollers: 同上，已由 Deployment 替代
# endpoints / endpointslices: 由 Service 控制器自动创建
# controllerrevisions: 由 DaemonSet/StatefulSet 控制器自动管理
# leases: leader election lease，运行时自动生成
# podtemplates: 已废弃的内部资源
# csistoragecapacities: CSI 驱动自动生成的存储容量信息
# pods.metrics.k8s.io: metrics-server 自动生成的指标数据
#
# 注意：resourcequotas、limitranges、networkpolicies 等**不排除**，
# 因为这些可能是管理员有意配置的，需要在目标集群重建。
EXCLUDE_KINDS="events events.events.k8s.io pods pods.metrics.k8s.io replicasets.apps replicationcontrollers endpoints endpointslices.discovery.k8s.io controllerrevisions.apps leases.coordination.k8s.io podtemplates csistoragecapacities.storage.k8s.io"

# ─── 检查依赖 ───
check_deps() {
  command -v kubectl >/dev/null || fatal "缺少 kubectl"
  command -v ctr >/dev/null || fatal "缺少 ctr（containerd 工具）"
  kubectl get nodes >/dev/null 2>&1 || fatal "无法连接 K8s 集群"
  log "依赖检查通过"
}

# ─── 选择 namespace ───
select_namespaces() {
  # 优先级：环境变量 > apps.conf > 交互输入
  if [[ -n "$NAMESPACES" ]]; then
    return
  fi

  # 从 apps.conf 读取（跳过注释和空行）
  if [[ -f "$CONF_FILE" ]]; then
    local conf_ns
    conf_ns=$(grep -vE '^\s*#' "$CONF_FILE" | grep -vE '^\s*$' | tr '\n' ',' | sed 's/,$//' | sed 's/[[:space:]]//g')
    if [[ -n "$conf_ns" ]]; then
      NAMESPACES="$conf_ns"
      log "从 apps.conf 读取到 namespace: $NAMESPACES"
      return
    fi
  fi

  # 交互式选择
  echo "当前集群 namespace 列表："
  kubectl get ns -o custom-columns=NAME:.metadata.name,STATUS:.status.phase --no-headers 2>/dev/null
  echo ""
  echo "提示：也可编辑 apps.conf 文件配置 namespace 列表"
  read -r -p "请输入要导出的 namespace（多个用逗号分隔）: " NAMESPACES
  [[ -n "$NAMESPACES" ]] || fatal "未输入 namespace，请编辑 $CONF_FILE 或使用 NAMESPACES=xxx ./scripts/export_apps.sh"
}

# ─── 清理 YAML 只读字段 ───
clean_yaml() {
  local file="$1"
  # 使用 python3 安全清理 YAML 只读字段
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PYEOF' 2>/dev/null || true
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
  else
    # 回退：用更精确的 sed，只删到下一个同级字段
    sed -i \
      -e '/^  uid:/d' \
      -e '/^  resourceVersion:/d' \
      -e '/^  creationTimestamp:/d' \
      -e '/^  generation:/d' \
      -e '/^  selfLink:/d' \
      -e '/^  managedFields:/,/^[a-z]/d' \
      -e '/^  ownerReferences:/,/^[a-z]/d' \
      -e '/^status:/d' \
      "$file" 2>/dev/null || true
  fi
}

# ─── 判断资源名是否应跳过 ───
should_skip() {
  local name="$1"
  for ex in $EXCLUDE_NAMES; do
    if [[ "$name" == "$ex" ]]; then
      return 0
    fi
  done
  # 跳过 Helm release secrets
  if [[ "$name" == sh.helm.release.* ]]; then
    return 0
  fi
  return 1
}

# ─── 导出 namespace 下全部资源 ───
export_namespace_resources() {
  local ns="$1"
  local ns_dir="$2"

  # 动态获取集群中所有 namespace 级、可 list 的资源类型
  # 输出格式: "name singular" 用制表符分隔
  local ns_resources
  ns_resources=$(kubectl api-resources --namespaced=true --verbs=list -o name 2>/dev/null | sort)

  local total=0

  for kind in $ns_resources; do
    # 跳过运行时自动生成的资源类型
    local skip_kind=false
    for ex_kind in $EXCLUDE_KINDS; do
      if [[ "$kind" == "$ex_kind" ]]; then
        skip_kind=true
        break
      fi
    done
    if $skip_kind; then
      continue
    fi

    # 获取该类型下的所有资源名
    local items
    items=$(kubectl get "$kind" -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [[ -z "$items" ]]; then
      continue
    fi

    for item in $items; do
      # 跳过系统资源
      if should_skip "$item"; then
        continue
      fi

      # 生成文件名：kind_item.yaml（kind 中的 / 替换为 _）
      local safe_kind
      safe_kind="${kind//\//_}"
      local outfile="$ns_dir/${safe_kind}_${item}.yaml"

      if kubectl get "$kind" "$item" -n "$ns" -o yaml > "$outfile" 2>/dev/null; then
        clean_yaml "$outfile"
        total=$((total + 1))
      else
        warn "  导出失败: $kind/$item (ns=$ns)"
        rm -f "$outfile"
      fi
    done
  done

  log "  $ns: 导出 $total 个资源"
}

# ─── 导出关联的集群级资源（PV / StorageClass）───
export_cluster_resources() {
  local pv_names="$1"
  local sc_names="$2"
  local cluster_dir="$MANIFESTS_DIR/cluster"

  # 导出 PV
  if [[ -n "$(echo "$pv_names" | xargs)" ]]; then
    mkdir -p "$cluster_dir"
    log "导出关联的 PersistentVolume ..."
    local pv_count=0
    for pv in $pv_names; do
      local outfile="$cluster_dir/persistentvolume_${pv}.yaml"
      if kubectl get pv "$pv" -o yaml > "$outfile" 2>/dev/null; then
        clean_yaml "$outfile"
        pv_count=$((pv_count + 1))
      else
        warn "  导出失败: pv/$pv"
        rm -f "$outfile"
      fi
    done
    log "  PV: 导出 $pv_count 个"
  fi

  # 导出 StorageClass
  if [[ -n "$(echo "$sc_names" | xargs)" ]]; then
    mkdir -p "$cluster_dir"
    log "导出关联的 StorageClass ..."
    local sc_count=0
    for sc in $(echo "$sc_names" | tr ' ' '\n' | sort -u); do
      [[ -z "$sc" ]] && continue
      local outfile="$cluster_dir/storageclass_${sc}.yaml"
      if kubectl get sc "$sc" -o yaml > "$outfile" 2>/dev/null; then
        clean_yaml "$outfile"
        sc_count=$((sc_count + 1))
      else
        warn "  导出失败: sc/$sc"
        rm -f "$outfile"
      fi
    done
    log "  StorageClass: 导出 $sc_count 个"
  fi
}

# ─── 导出资源 YAML ───
export_manifests() {
  IFS=',' read -ra NS_ARRAY <<< "$NAMESPACES"

  local pv_names=""
  local sc_names=""

  for ns in "${NS_ARRAY[@]}"; do
    ns=$(echo "$ns" | xargs)  # 去空格
    if ! kubectl get ns "$ns" >/dev/null 2>&1; then
      warn "namespace '$ns' 不存在，跳过"
      continue
    fi

    local ns_dir="$MANIFESTS_DIR/$ns"
    mkdir -p "$ns_dir"
    log "导出 namespace: $ns"

    # 导出该 namespace 下全部资源
    export_namespace_resources "$ns" "$ns_dir"

    # 收集 PVC 关联的 PV 和 StorageClass
    local pvc_items
    pvc_items=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    for pvc in $pvc_items; do
      local pv_name sc_name
      pv_name=$(kubectl get pvc "$pvc" -n "$ns" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
      sc_name=$(kubectl get pvc "$pvc" -n "$ns" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)
      [[ -n "$pv_name" ]] && pv_names="$pv_names $pv_name"
      [[ -n "$sc_name" ]] && sc_names="$sc_names $sc_name"
    done
  done

  # 导出关联的集群级资源
  export_cluster_resources "$pv_names" "$sc_names"
}

# ─── 解析镜像列表 ───
extract_images() {
  local images_file="$ROOT_DIR/images.txt"
  > "$images_file"

  # 从所有 YAML 中提取 image 字段
  find "$MANIFESTS_DIR" -name '*.yaml' -exec grep -h 'image:' {} \; 2>/dev/null | \
    sed 's/.*image:\s*//' | \
    sed 's/^ *"//;s/"$//' | \
    sed 's/^ *'"'"'//;s/'"'"'$//' | \
    grep -v '^$' | \
    sort -u > "$images_file" || true

  local count
  count=$(wc -l < "$images_file" 2>/dev/null || echo 0)
  log "解析到 $count 个镜像"

  if [[ "$count" -eq 0 ]]; then
    warn "未找到任何镜像引用"
  fi
}

# ─── 从 containerd 导出镜像 ───
export_images() {
  local images_file="$ROOT_DIR/images.txt"
  [[ -s "$images_file" ]] || { warn "镜像列表为空，跳过镜像导出"; return; }

  mkdir -p "$IMAGES_DIR"

  # 获取 containerd 中已有的镜像列表
  local containerd_images
  containerd_images=$(crictl images -o json 2>/dev/null | \
    python3 -c "import sys,json; data=json.load(sys.stdin); [print(t) for img in data.get('images',[]) for t in img.get('repoTags',[]) if t]" 2>/dev/null || \
    crictl images 2>/dev/null | tail -n +2 | awk '{print $1":"$2}' | grep -v '<none>')

  local found=0
  local not_found=0
  local found_images=()

  while IFS= read -r img; do
    [[ -z "$img" ]] && continue

    # 在 containerd 中查找匹配的镜像（支持短名 -> 完整名映射）
    local matched=""
    local candidates=("$img")

    # 如果没有 registry 前缀，补全为 docker.io/library/ 或 docker.io/
    if [[ "$img" != */* ]]; then
      candidates+=("docker.io/library/$img")
    elif [[ "$img" != docker.io/* && "$img" != registry.k8s.io/* && "$img" != quay.io/* && "$img" != ghcr.io/* ]]; then
      candidates+=("docker.io/$img")
    fi

    for cimg in $containerd_images; do
      for cand in "${candidates[@]}"; do
        if [[ "$cimg" == "$cand" ]]; then
          matched="$cimg"
          break 2
        fi
      done
      # 反向：去掉 containerd 镜像的 registry 前缀后比较
      local cimg_normalized="$cimg"
      cimg_normalized="${cimg_normalized#docker.io/library/}"
      cimg_normalized="${cimg_normalized#docker.io/}"
      cimg_normalized="${cimg_normalized#registry.k8s.io/}"
      cimg_normalized="${cimg_normalized#quay.io/}"
      if [[ "$cimg_normalized" == "$img" ]]; then
        matched="$cimg"
        break
      fi
    done

    if [[ -n "$matched" ]]; then
      found_images+=("$matched")
      found=$((found + 1))
      log "  找到镜像: $matched"
    else
      warn "  镜像未在 containerd 中找到: $img"
      not_found=$((not_found + 1))
    fi
  done < "$images_file"

  log "镜像统计: 找到 $found, 未找到 $not_found"

  if [[ ${#found_images[@]} -gt 0 ]]; then
    # 去重
    local unique_images
    unique_images=$(printf '%s\n' "${found_images[@]}" | sort -u)

    # 批量导出为一个 tar 文件
    local export_list=()
    while IFS= read -r img; do
      export_list+=("$img")
    done <<< "$unique_images"

    log "导出 ${#export_list[@]} 个镜像到 images/app-images.tar ..."
    ctr -n k8s.io images export --platform "linux/$ARCH" \
      "$IMAGES_DIR/app-images.tar" "${export_list[@]}" 2>&1 || \
      fatal "镜像导出失败"

    # 生成校验和
    (cd "$IMAGES_DIR" && sha256sum app-images.tar > app-images.tar.sha256)
    log "镜像导出完成: $IMAGES_DIR/app-images.tar"
  else
    warn "没有找到可导出的镜像"
  fi
}

# ─── 打包 ───
package_bundle() {
  local timestamp
  timestamp=$(date '+%Y%m%d%H%M%S')
  local ns_label
  ns_label=$(echo "$NAMESPACES" | tr ',' '-')
  local bundle_name="offline-apps-${ns_label}-${timestamp}"
  local bundle_dir="$BUILD_DIR/$bundle_name"

  mkdir -p "$bundle_dir/scripts"

  # 复制内容
  cp -r "$MANIFESTS_DIR" "$bundle_dir/" 2>/dev/null || true
  cp -r "$IMAGES_DIR" "$bundle_dir/" 2>/dev/null || true
  cp "$ROOT_DIR/scripts/export_apps.sh" "$bundle_dir/scripts/"
  cp "$ROOT_DIR/scripts/deploy_apps.sh" "$bundle_dir/scripts/"

  # 生成 VERSION.txt
  cat > "$bundle_dir/VERSION.txt" <<EOF
业务应用离线包
打包时间: $(date '+%Y-%m-%d %H:%M:%S')
架构: $ARCH
Namespace: $NAMESPACES
镜像数量: $(wc -l < "$ROOT_DIR/images.txt" 2>/dev/null || echo 0)
资源文件: $(find "$MANIFESTS_DIR" -name '*.yaml' 2>/dev/null | wc -l)
EOF

  # 生成 images.txt
  cp "$ROOT_DIR/images.txt" "$bundle_dir/" 2>/dev/null || true

  # 打 tar
  local tar_file="$ROOT_DIR/bundle/${bundle_name}.tar.gz"
  mkdir -p "$ROOT_DIR/bundle"

  tar -czf "$tar_file" -C "$BUILD_DIR" "$bundle_name"
  (cd "$ROOT_DIR/bundle" && sha256sum "$(basename "$tar_file")" > "$(basename "$tar_file").sha256")

  local size
  size=$(du -h "$tar_file" | awk '{print $1}')

  echo ""
  log "========================================"
  log "打包完成！"
  log "文件: $tar_file"
  log "大小: $size"
  log "========================================"
  echo ""
  echo "传输到内网服务器后："
  echo "  1. 解压: tar -xzf $(basename "$tar_file")"
  echo "  2. 部署: cd $bundle_name && ./scripts/deploy_apps.sh"
}

# ─── 主流程 ───
main() {
  log "=== 业务应用离线打包工具 ==="
  check_deps
  select_namespaces
  export_manifests
  extract_images
  export_images
  package_bundle
  log "完成！"
}

main "$@"

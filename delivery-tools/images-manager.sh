#!/usr/bin/env bash
# ============================================================================
# 镜像管理脚本 v3.0 (merged) - 同步/导出/导入/K8s 注入
#
# 用法:
#   ./images-manager.sh sync [架构]    拉取官方镜像 → 推送到华为云 SWR
#   ./images-manager.sh export [架构]  从 SWR 拉取 → 改回官方名 → 打包 tar.gz
#   ./images-manager.sh import         解压 tar.gz → 加载镜像 (自动适配 containerd/docker)
#   ./images-manager.sh load2k8s [过滤] 直接从 SWR 拉取 → 打回官方名 → 注入 K8s containerd
#                                       (k8s.io namespace, 免 docker/免 tar, 推荐)
#   ./images-manager.sh arch           检查 SWR 镜像的 CPU 架构 (arm64/amd64)
#   ./images-manager.sh list           查看镜像对照表
#   ./images-manager.sh status         检查 SWR 仓库中镜像状态
#
# 架构参数 (sync/export/load2k8s 都支持):
#   native   本机架构
#   arm64    强制 arm64  ← ★ amd64 服务器给 ARM K8s 同步就选这个
#   amd64    强制 amd64
#   all      完整多架构 amd64+arm64 (★默认)
#            SWR 无法解析 OCI 格式 manifest, 本脚本逐架构 docker pull → push →
#            docker manifest create 组合成 Docker manifest list (SWR 兼容)
#
# 三种等价写法:
#   bash images-manager.sh sync arm64
#   bash images-manager.sh sync --arch arm64
#   ARCH=arm64 bash images-manager.sh sync
#
# 排除镜像:
#   编辑 EXCLUDE 数组, 添加需要排除的镜像名 (支持部分匹配)
#   也支持环境变量覆盖: EXCLUDE="dpage/pgadmin kafka-ui" bash images-manager.sh sync
# ============================================================================
set -euo pipefail

# ========================= 基础配置 =========================
SWR_REGISTRY="swr.cn-east-3.myhuaweicloud.com"
SWR_PROJECT="lianantech-public"
SWR_FULL="${SWR_REGISTRY}/${SWR_PROJECT}"

# ========================= 本地同步缓存 =========================
# sync 幂等判断默认每次都远程查 SWR (docker manifest inspect/pull ×N), 镜像一多就很慢。
# 引入本地缓存: 每次成功推送后记录一条 '<SWR tag> <架构列表>' 到 .swr-synced-cache,
# 下次 sync 先查缓存命中即跳过, 不再发起远程请求。
#   · 仅 sync 使用; status / arch 命令仍实时查远端, 不受影响
#   · 首次 sync 或缓存为空时, 任一镜像经远程确认通过 (已同步跳过) 也会顺手写入缓存,
#     之后再次运行即纯本地判断
#   · 远程仓库被手动删除、或上游镜像新增了架构时, 缓存可能误判为已同步;
#     需要重新校验时删除缓存文件即可强制全量重新核对:
#       rm -f .swr-synced-cache   # 下次 sync 会重新全量远程核对并重建缓存
SWR_CACHE_FILE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.swr-synced-cache"

# 本机架构
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64)  HOST_ARCH="amd64" ;;
  aarch64) HOST_ARCH="arm64" ;;
  *)       ;;  # 保持原样
esac

# ========================= 镜像总表 =========================
# 格式: "官方镜像名:tag" (一行一个, 随时增删)
IMAGES=(
  # ── 存储 ──────────────────────────────────────────────────
  "registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2"

  # ── MySQL 8.4 (官方最新 LTS) ─────────────────────────────
  "mysql:8.4"
  "prom/mysqld-exporter:v0.15.1"

  # ── Redis 7.4 (官方最新稳定) ─────────────────────────────
  "redis:7.4"
  "oliver006/redis_exporter:v1.67.0"

  # ── Kafka 4.2 (Apache 官方最新) ──────────────────────────
  "apache/kafka:4.2.0"
  "danielqsj/kafka-exporter:v1.8.0"

  # ── Elasticsearch 7.17.29 (官方 7.x 最新) ───────────────
  "docker.elastic.co/elasticsearch/elasticsearch:7.17.29"
  "docker.elastic.co/kibana/kibana:7.17.29"

  # ── Kafka 管理界面 ────────────────────────────────────────
  "provectuslabs/kafka-ui:latest"

  # ── ES Exporter ───────────────────────────────────────────
  "quay.io/prometheuscommunity/elasticsearch-exporter:v1.7.0"

  # ── PostgreSQL 16 + pgvector + pgadmin ────────────────────
  "postgres:16"
  "pgvector/pgvector:pg16"
  "dpage/pgadmin4:latest"

  # ── NebulaGraph 3.8.0 图数据库 (内核多架构 amd64+arm64) ────
  # ⚠️ docker tag 与 git release 版本不一致: console=v3.8, studio=v3.10 (无 patch 位)
  #    Dashboard 社区版 (v3.4.0) 无 Docker 镜像, 只提供 RPM/DEB/tar, 不在此列表
  "vesoft/nebula-metad:v3.8.0"
  "vesoft/nebula-storaged:v3.8.0"
  "vesoft/nebula-graphd:v3.8.0"
  "vesoft/nebula-console:v3.8"
  "vesoft/nebula-graph-studio:v3.10"

  # ── K8s 基础组件 ─────────────────────────────────────────
  "registry.k8s.io/pause:3.9"
  "registry.k8s.io/coredns/coredns:v1.11.1"

  # ── Milvus 2.6.23 向量数据库 (official standalone compose 依赖集) ─
  # ⚠️ 依赖说明:
  #   etcd    = MVCC 元数据存储 (Milvus compose 官方引用 quay.io/coreos/etcd)
  #   minio   = 对象存储, 沿用已部署的官方老镜像 quay.io/minio/minio (2025-09-07 冻结版),
  #             不更换、不清理 (已上生产)。仅供 Milvus 内部 S3 使用。
  "milvusdb/milvus:v2.6.23"
  "quay.io/coreos/etcd:v3.5.25"
  "quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z"

  # ── MinIO/Silo 对象存储套件 (独立部署, 长期维护 stable) ──────────
  # ⚠️ 背景: MinIO 官方社区版 2025-10 起停止发布二进制/Docker, 2026-02 仓库归档,
  #     docker.io/minio/minio 已下架; quay.io/minio/minio 冻结在 2025-09-07 且有
  #     已知未修 CVE。社区维护分支 pgsty/silo (前身 pgsty/minio) 是唯一活跃的
  #     drop-in 延续: S3/Admin API、MINIO_* 环境变量、.minio.sys 磁盘格式、/minio/* 路由
  #     全部兼容, 每季安全修复, amd64+arm64。
  #     这里 server+client 同版本配套 (silo 20260903 ↔ mc 20260903)。
  #   ✔ 与 Milvus 老 minio 并存: 不同项目可各用各的版本, 无耦合 (都以 S3 API 对接)
  "pgsty/silo:RELEASE.2026-09-03T13-18-01Z"
  "pgsty/mc:RELEASE.2026-09-03T07-13-05Z"

  # ── Kuboard v4 (K8s 管理界面, 官方镜像 eipwork, arm64 已验证) ─
  # 注意: kuboard-agent 上游没有 v4 tag (最新 v3.x)。Kuboard v4 server 导入集群时
  #       自动创建的 kuboard-agent Deployment 引用的就是 eipwork/kuboard-agent:v3
  "eipwork/kuboard:v4"
  "eipwork/kuboard-agent:v3"

  # ── ingress-nginx v1.11.8 (controller 多架构 + webhook 证书工具) ─
  "registry.k8s.io/ingress-nginx/controller:v1.11.8"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.5.1"

  # ── metrics-server (kubectl top 依赖) ─────────────────────
  "registry.k8s.io/metrics-server/metrics-server:v0.7.2"

  # ── Prometheus 监控套件 ────────────────────────────────────
  "prom/prometheus:v3.14.0"
  "prom/alertmanager:v0.34.0"
  "prom/pushgateway:v1.11.3"
  "prom/node-exporter:v1.12.0"
  "prom/blackbox-exporter:v0.28.0"

  # ── Grafana (OSS 13.x 最新稳定) + Loki (日志聚合) ──────────
  "grafana/grafana:13.1.3"
  "grafana/loki:3.7.7"
)

# ========================= 排除列表 =========================
# 添加不需要同步/导出的镜像 (支持子串匹配)
if [[ -z "${EXCLUDE+x}" ]]; then
  EXCLUDE=(
    # "dpage/pgadmin"
    # "kafka-ui"
    # "provectuslabs"
  )
elif [[ "${EXCLUDE}" == *" "* ]]; then
  IFS=' ' read -ra EXCLUDE <<< "$EXCLUDE"
fi

# ========================= 架构参数解析 =========================
# 默认 all = 双架构完整复制 (amd64+arm64 manifest list 原样搬运, 两种服务器都能用)
# 支持 "sync arm64" / "sync --arch arm64" / "ARCH=arm64 sync" 强制单架构
ARCH="${ARCH:-all}"
FILTER=""    # 镜像名过滤参数 (sync/export/load2k8s 都支持, 如: sync vesoft)

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch|-a)
        [[ $# -lt 2 ]] && err "--arch 需要参数: native|arm64|amd64|all"
        ARCH="$2"; shift 2 ;;
      native|arm64|amd64|all)
        ARCH="$1"; shift ;;
      *)
        FILTER="$1"; shift ;;
    esac
  done
}

# 生效架构 (native → 本机架构)
eff_arch() {
  [[ "$ARCH" == "native" ]] && echo "$HOST_ARCH" || echo "$ARCH"
}

# docker 拉取时的 --platform 参数
docker_plat() {
  case "$ARCH" in
    native|all) echo "" ;;           # all 模式走 copy_multiarch 逐平台拉取, 不经过此函数
    *) echo "--platform linux/${ARCH}" ;;
  esac
}

# ========================= 颜色/日志 =========================
GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; BLUE='\033[34m'
CYAN='\033[36m'; GRAY='\033[90m'; RESET='\033[0m'
log()   { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
skip()  { echo -e "${GRAY}[SKIP]${RESET}  $*"; }
stage() { echo -e "\n${BLUE}══════════════════════════════════════════════════════════${RESET}"; echo -e "${BLUE}  $*${RESET}"; echo -e "${BLUE}══════════════════════════════════════════════════════════${RESET}"; }

# ========================= 工具函数 =========================

# 过滤掉 EXCLUDE 中的镜像, 返回实际要处理的列表
get_active_images() {
  local result=()
  for img in "${IMAGES[@]}"; do
    local excluded=false
    for pat in "${EXCLUDE[@]:-}"; do
      [[ -z "$pat" ]] && continue
      if [[ "$img" == *"$pat"* ]]; then
        excluded=true
        break
      fi
    done
    $excluded || result+=("$img")
  done
  echo "${result[@]}"
}

# 官方名 → SWR 名
to_swr() {
  local name="$1"
  name="${name#docker.io/}"
  name="${name#quay.io/}"
  name="${name#registry.k8s.io/}"
  echo "${SWR_FULL}/${name}"
}

# SWR 名 → 官方名 (按 IMAGES 列表反查)
to_official() {
  local base="${1#${SWR_FULL}/}"
  for img in "${IMAGES[@]}"; do
    local s="$img"
    s="${s#docker.io/}"; s="${s#quay.io/}"; s="${s#registry.k8s.io/}"
    [[ "$base" == "$s" ]] && { echo "$img"; return; }
  done
  echo "$base"
}

# 官方名 → K8s 引用名 (完整限定)
# ⚠️ docker.io 镜像必须补全前缀: kubelet 查本地镜像前会把镜像名规范化为完整引用
#    (eipwork/kuboard:v4 → docker.io/eipwork/kuboard:v4), 短名 tag 会导致
#    kubelet 判定本地缺失 → 走镜像源外网拉取 (eipwork/* 被 daocloud 403)
to_full_ref() {
  local name="$1"
  case "$name" in
    *.*/*) echo "$name" ;;                    # 带域名 registry (registry.k8s.io / quay.io / docker.elastic.co), 原样
    */*)   echo "docker.io/$name" ;;          # docker.io 组织镜像: eipwork/kuboard:v4 → docker.io/eipwork/kuboard:v4
    *)     echo "docker.io/library/$name" ;;  # 官方库短名: mysql:8.4 → docker.io/library/mysql:8.4
  esac
}

# 合法 tar 文件名
to_tarname() { echo "${1//[:\/]/_}.tar"; }

# 读取 SWR 凭据, 优先级: 环境变量 > 脚本同目录 .swr-credentials > ~/.docker/config.json
# .swr-credentials 内容为 base64("用户名:密码"), 权限 600, 一行生成:
#   echo -n 'cn-east-3@XXX:密码' | base64 > .swr-credentials
swr_auth() {
  if [[ -n "${SWR_USER:-}" && -n "${SWR_PASS:-}" ]]; then
    return 0
  fi
  local cred_file="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.swr-credentials"
  if [[ -f "$cred_file" ]]; then
    local auth
    auth=$(base64 -d "$cred_file" 2>/dev/null || true)
    if [[ "$auth" == *:* ]]; then
      SWR_USER="${auth%%:*}"
      SWR_PASS="${auth#*:}"
      return 0
    fi
  fi
  local cfg="$HOME/.docker/config.json"
  [[ -f "$cfg" ]] || cfg="/root/.docker/config.json"
  if [[ -f "$cfg" ]] && grep -q "$SWR_REGISTRY" "$cfg" 2>/dev/null; then
    local auth
    auth=$(python3 -c "
import json
d=json.load(open('$cfg'))['auths'].get('$SWR_REGISTRY',{})
print(d.get('auth',''))" 2>/dev/null || true)
    if [[ -n "$auth" ]]; then
      SWR_USER=$(echo "$auth" | base64 -d | cut -d: -f1)
      SWR_PASS=$(echo "$auth" | base64 -d | cut -d: -f2-)
      return 0
    fi
  fi
  return 1
}

# 检查 SWR 镜像 tag 是否存在 (需要 docker; sync/status 用)
swr_exists() {
  docker manifest inspect --insecure "$1" >/dev/null 2>&1 && return 0 || return 1
}

# 获取镜像在 registry 中的 linux 平台架构集合, 输出如 "amd64 arm64"
# skopeo 优先 (单/多架构都能看准), docker manifest inspect 兜底 (只能解析多架构 list)
image_platforms() {
  local ref="$1"
  local creds=()
  # SWR 私有仓库需要凭据; docker.io 公共镜像匿名即可
  if [[ "$ref" == *"$SWR_REGISTRY"* ]] && swr_auth; then
    creds=(--creds "${SWR_USER}:${SWR_PASS}")
  fi
  if command -v skopeo >/dev/null 2>&1; then
    # 多架构: raw manifest 里的 manifests[].platform
    local p
    p=$(skopeo inspect --raw "${creds[@]}" "docker://${ref}" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    plats = set()
    for m in (d.get('manifests') or []):
        pl = m.get('platform') or {}
        if pl.get('os') == 'linux' and pl.get('architecture') in ('amd64', 'arm64'):
            plats.add(pl['architecture'])
    print(' '.join(sorted(plats)))
except Exception:
    pass" 2>/dev/null)
    [[ -n "$p" ]] && { echo "$p"; return 0; }
    # 单架构 manifest: 从 config 的 Architecture 字段拿
    p=$(skopeo inspect "${creds[@]}" "docker://${ref}" 2>/dev/null | python3 -c "
import sys, json
try:
    a = json.load(sys.stdin).get('Architecture', '')
    print(a if a in ('amd64', 'arm64') else '')
except Exception:
    pass" 2>/dev/null)
    [[ -n "$p" ]] && { echo "$p"; return 0; }
    return 1
  fi
  # 无 skopeo: docker buildx imagetools inspect 单/多架构都能识别平台 (需联网)
  local p
  p=$(docker buildx imagetools inspect "$ref" 2>/dev/null | python3 -c "
import sys, re
plats = set()
for line in sys.stdin:
    m = re.search(r'Platform:\s+linux/(amd64|arm64)', line)
    if m: plats.add(m.group(1))
print(' '.join(sorted(plats)))" 2>/dev/null)
  [[ -n "$p" ]] && { echo "$p"; return 0; }

  # 无 buildx 兜底: docker manifest inspect 只能解析多架构 list
  docker manifest inspect --insecure "$ref" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    plats = set()
    for m in (d.get('manifests') or []):
        pl = m.get('platform') or {}
        if pl.get('os') == 'linux' and pl.get('architecture') in ('amd64', 'arm64'):
            plats.add(pl['architecture'])
    print(' '.join(sorted(plats)))
except Exception:
    pass" 2>/dev/null
  return 0
}

# 当前 sync 模式需要校验的架构集合
#   native → 本机架构;  arm64/amd64 → 指定架构;  all → 以上游实际平台为准 (上游 amd64-only 不强求 arm64)
sync_need_arch() {
  local src="$1"
  if [[ "$ARCH" == "native" ]]; then
    echo "$HOST_ARCH"
  elif [[ "$ARCH" != "all" ]]; then
    echo "$ARCH"
  else
    local p; p=$(image_platforms "$(to_src_ref "$src")" 2>/dev/null || true)
    if [[ -n "$p" ]]; then echo "$p"; else echo "amd64 arm64"; fi
  fi
}

# 命中缓存: 该 tag 已记录 且 所需架构全部齐 → 0; 否则 → 1
cache_check() {
  local target="$1" need="$2"
  [[ -f "$SWR_CACHE_FILE" ]] || return 1
  local line
  line=$(awk -v t="$target" '$1==t {v=$0} END{print v}' "$SWR_CACHE_FILE" 2>/dev/null) || true
  [[ -z "$line" ]] && return 1
  local have; have=$(cut -d' ' -f2- <<<"$line")
  local p
  for p in $need; do
    [[ " $have " == *" $p "* ]] || return 1
  done
  return 0
}

# 记录/更新缓存: 格式 '<SWR tag> 架构1 架构2 …'
cache_mark() {
  local target="$1"; shift
  [[ -z "$target" ]] && return
  local tmp="${SWR_CACHE_FILE}.$$"
  mkdir -p "$(dirname "$SWR_CACHE_FILE")"
  : > "$tmp"   # 始终先建空临时文件, 避免 cat 报错触发 set -e
  [[ -f "$SWR_CACHE_FILE" ]] && awk -v t="$target" '$1!=t' "$SWR_CACHE_FILE" >> "$tmp" 2>/dev/null || true
  echo "$target $*" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$SWR_CACHE_FILE"
}

# sync 幂等判断: tag 存在 且 需要的架构都在 才算同步完成
swr_ready() {
  local target="$1" need="$2"
  cache_check "$target" "$need" && return 0   # 本地缓存命中 → 不再远程查
  swr_exists "$target" || return 1        # tag 都没有 → 肯定要推
  local have; have=$(image_platforms "$target" 2>/dev/null || true)
  if [[ -z "$have" ]]; then
    # 平台探测失败 (无 skopeo 且是单架构 manifest, 里面没有 platform 字段)
    # 要求多架构 (如 all 模式) → 单 manifest 必然不满足 → 重推
    # 只要求单架构 → tag 已存在, 按 OK 处理
    if [[ "$need" == *" "* ]]; then return 1; fi
    return 0
  fi
  local p
  for p in $need; do
    [[ " $have " == *" $p "* ]] || return 1
  done
  return 0
}

# 检查镜像是否已存在于本机 containerd k8s.io namespace (幂等)
k8s_image_exists() {
  sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -qx "$1"
}

# 拉取镜像 (按 ARCH 指定平台; amd64 服务器拉 arm64 完全可行, 只是不能运行)
# docker pull 进度实时打印
pull_image() {
  local src="$1"
  docker pull $(docker_plat) "$src" && return 0
  return 1
}

# 源镜像引用映射: docker.io 源可经 SRC_MIRROR 代理站中转, 绕开匿名限流 (429)
# 用法: SRC_MIRROR=docker.1ms.run bash images-manager.sh sync
#   mysql:8.4        → ${SRC_MIRROR}/library/mysql:8.4
#   apache/kafka:xxx → ${SRC_MIRROR}/apache/kafka:xxx
# 其他 registry (quay.io/registry.k8s.io/docker.elastic.co) 不受 Docker Hub 限流, 原样直连
to_src_ref() {
  local src="$1"
  local ns="${src%%/*}"
  if [[ "$src" != */* ]]; then
    # 官方库短名: mysql:8.4 → library/mysql:8.4
    [[ -n "${SRC_MIRROR:-}" ]] && { echo "${SRC_MIRROR}/library/${src}"; return; }
    echo "docker.io/library/${src}"
  elif [[ "$ns" == *.* ]]; then
    echo "$src"    # 带域名的其他 registry: 原样
  else
    # docker.io 组织镜像: apache/kafka → mirror/apache/kafka
    [[ -n "${SRC_MIRROR:-}" ]] && { echo "${SRC_MIRROR}/${src}"; return; }
    echo "docker.io/${src}"
  fi
}

# 多架构复制到 SWR (amd64 + arm64)
# ⚠️ 背景: SWR 只能解析 Docker 格式的 manifest list
#   (application/vnd.docker.distribution.manifest.list.v2+json)。
#   新版官方镜像 (mysql/redis/apache-kafka 等) 的 manifest index 已是 OCI 格式,
#   直接用 docker buildx imagetools create 搬运会原样生成 OCI index,
#   SWR 返回 400 "Invalid image, fail to parse 'manifest.json'"。
#   本函数改为: 逐架构 docker pull (拉下来自动转成 Docker 格式) → 推送到 SWR
#   临时 slot tag (如 xxx:tag-amd64 / xxx:tag-arm64) → docker manifest create 组合
#   成 Docker manifest list 推回主 tag。全程不产生 OCI 格式, SWR 必然可解析;
#   只取 amd64 + arm64, 天然剥离 attestation (unknown/unknown) 与无关平台。
#   临时 tag 保留为单架构快照, 同时可用于 load2k8s 单架构拉取。
#   可选加速: 安装 skopeo 并设 SKOPEO_FAST=1, 走 skopeo copy --format v2s2
#   (同样转 Docker 格式, 服务器端复制不占本地磁盘)。
copy_multiarch() {
  local src="$1" dst="$2"
  local src_ref; src_ref=$(to_src_ref "$src")
  local tmp_amd="${dst}-amd64" tmp_arm="${dst}-arm64"

  # ── 加速路径 (可选): skopeo copy, 服务器端复制 + OCI→Docker 格式转换 ──
  if [[ -n "${SKOPEO_FAST:-}" ]] && command -v skopeo >/dev/null 2>&1; then
    swr_auth || err "SKOPEO_FAST 需要 SWR 凭据: export SWR_USER=xxx SWR_PASS=xxx"
    log "skopeo copy --all --format v2s2: ${src} → ${dst}"
    if skopeo copy --all --format v2s2 \
         --dest-creds "${SWR_USER}:${SWR_PASS}" \
         "docker://${src_ref}" "docker://${dst}"; then
      cache_mark "$dst" $(sync_need_arch "$src")
      return 0
    fi
    warn "skopeo 复制失败, 自动改用 docker 平台拉取方式"
  fi

  # ── 默认路径: 逐架构拉取 → 推 slot tag → manifest 组合 (无条件可用) ──
  local arch archs=()
  for arch in amd64 arm64; do
    local tmp="${dst}-${arch}"
    echo "   ├─ 拉取 ${src_ref} (linux/${arch}) ..."
    if ! docker pull --platform "linux/${arch}" "$src_ref" 2>&1; then
      warn "${src} 上游无 linux/${arch}, 跳过 (最终 manifest 只含其余架构)"
      continue
    fi
    docker tag "$src_ref" "$tmp"
    echo "   ├─ 推送 ${tmp} ..."
    if ! docker push "$tmp" 2>&1; then
      warn "推送 ${tmp} (linux/${arch}) 失败"
      return 1
    fi
    archs+=("$arch")
    log "✅ linux/${arch} 已推送 (slot tag: ${tmp})"
  done

  [[ ${#archs[@]} -eq 0 ]] && { warn "${src} 上游两个架构均拉取失败, 跳过"; return 1; }
  [[ ${#archs[@]} -lt 2 ]] && { log "上游单架构或部分架构缺失 [${archs[*]}], 主 tag 保持单架构 manifest"; return 0; }

  # 组合成 Docker manifest list 并推回主 tag
  docker manifest create --amend "$dst" "$tmp_amd" "$tmp_arm"
  docker manifest annotate "$dst" "$tmp_amd" --arch amd64 --os linux
  docker manifest annotate "$dst" "$tmp_arm" --arch arm64 --os linux
  docker manifest push "$dst"
  log "✅ 多架构 manifest list 已推送 [${archs[*]}] (swr 主 tag: ${dst})"
  log "   单架构 slot tag 保留: ${tmp_amd} / ${tmp_arm}"
  cache_mark "$dst" "${archs[*]}"
  # 释放本地磁盘: 仅用于推 SWR 的本地 staging 镜像全部删除 (防止 33 个镜像同步时磁盘写满)
  docker image rm "$src_ref" "$tmp_amd" "$tmp_arm" >/dev/null 2>&1 || true
  return 0
}

# ========================= sync =========================
do_sync() {
  command -v docker >/dev/null 2>&1 || err "docker 未安装 (sync 需在装有 docker 的服务器执行)"

  # 应用过滤参数 (如: sync vesoft)
  local list=()
  local src
  for src in $(get_active_images); do
    [[ -n "$FILTER" && "$src" != *"$FILTER"* ]] && continue
    list+=("$src")
  done

  local total=${#list[@]} ok=0 skip_count=0 fail=0
  local success_list=() failed_list=() skipped_list=()

  [[ $total -eq 0 ]] && err "过滤条件 '${FILTER}' 没有匹配到任何镜像"

  # 检查登录状态
  if [[ ! -f ~/.docker/config.json ]] || ! grep -q "$SWR_REGISTRY" ~/.docker/config.json 2>/dev/null; then
    err "未登录 SWR, 请先执行: docker login ${SWR_REGISTRY} -u <user> -p <pass>"
  fi

  stage "同步镜像到华为云 SWR"
  log "目标: ${SWR_FULL}"
  log "架构: ${ARCH} (本机: ${HOST_ARCH})"
  [[ "$ARCH" == "all" ]] && log "模式: 双架构 amd64+arm64 (逐架构 pull→push→Docker manifest 组合, SWR 兼容)"
  log "总数: ${total} (过滤: ${FILTER:-无}, 排除: ${#EXCLUDE[@]} 个)"
  echo ""

  for (( i=0; i<total; i++ )); do
    local src="${list[$i]}"
    local target; target=$(to_swr "$src")

    echo -e "\n[${i}+1/${total}] ${CYAN}${src}${RESET}"

    # 幂等: tag 存在 且 架构齐全 才跳过 (解决: 之前推的 amd64-only, arm64 补不上)
    # 快速路径: 本地缓存命中 → 纯本地判断, 不查 src/SWR 远端
    if cache_check "$target" ""; then
      skip "已同步 (缓存)"
      skip_count=$((skip_count + 1)); skipped_list+=("$target")
      continue
    fi
    local need_arch; need_arch=$(sync_need_arch "$src")
    if swr_ready "$target" "$need_arch"; then
      cache_mark "$target" $need_arch   # 远程确认过 → 本地记录, 下次直接走缓存
      local have_plats; have_plats=$(image_platforms "$target" 2>/dev/null || true)
      [[ -z "$have_plats" ]] && have_plats="单架构(装 skopeo 可识别)"
      skip "已同步 [${have_plats}]"
      skip_count=$((skip_count + 1)); skipped_list+=("$target")
      continue
    fi
    if swr_exists "$target"; then
      warn "tag 已存在但架构不全: 现有[$(image_platforms "$target" 2>/dev/null || echo '?')] 需要[${need_arch}] → 重推"
    fi

    echo "         → ${target}"

    # ARCH=all: 多架构复制 (逐架构 docker pull→push→manifest 组合, SWR 兼容 Docker 格式)
    if [[ "$ARCH" == "all" ]]; then
      if copy_multiarch "$src" "$target"; then
        ok=$((ok + 1)); success_list+=("$target")
        log "✅ 多架构推送成功 [$(image_platforms "$target" 2>/dev/null || echo '架构待验证')]"
      else
        fail=$((fail + 1)); failed_list+=("$src (multi-arch)")
        warn "❌ 多架构复制失败 (原因见上方日志)"
      fi
      continue
    fi

    # 单架构: docker pull --platform → tag → push (pull/push 日志实时打印)
    local src_ref; src_ref=$(to_src_ref "$src")
    if pull_image "$src_ref"; then
      docker tag "$src_ref" "$target"
      if docker push "$target"; then
        ok=$((ok + 1)); success_list+=("$target"); log "✅ 推送成功 (linux/$(eff_arch))"
        cache_mark "$target" "$(eff_arch)"
        docker image rm "$src_ref" "$target" >/dev/null 2>&1 || true   # 释放本地 staging 镜像
      else
        fail=$((fail + 1)); failed_list+=("$src (push)"); warn "❌ push 失败 (原因见上方日志)"
      fi
    else
      fail=$((fail + 1)); failed_list+=("$src (pull)"); warn "❌ pull 失败 (可能无 linux/$(eff_arch) 版本)"
    fi
  done

  # 汇总
  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "  同步完成  成功:${ok}  跳过:${skip_count}  失败:${fail}  架构:linux/$(eff_arch)"
  echo "══════════════════════════════════════════════════════════"
  [[ ${#skipped_list[@]} -gt 0 ]] && { echo -e "${GRAY}已跳过:${RESET}"; printf "  - %s\n" "${skipped_list[@]}"; }
  [[ ${#success_list[@]} -gt 0 ]] && { echo "已推送:"; printf "  ✅ %s\n" "${success_list[@]}"; }
  [[ ${#failed_list[@]} -gt 0 ]] && { echo "失败:"; printf "  ❌ %s\n" "${failed_list[@]}"; }
  echo ""
}

# ========================= load2k8s =========================
# 直接从 SWR 拉取 → 打回官方名 → 注入本机 containerd k8s.io namespace
# 无需 docker / 无需 tar, kubelet 按官方镜像名直接命中本地镜像 (IfNotPresent 不再外网拉取)
do_load2k8s() {
  command -v ctr >/dev/null 2>&1 || err "ctr 未安装"
  sudo ctr -n k8s.io namespaces ls >/dev/null 2>&1 || err "containerd 不可访问"
  swr_auth || err "缺少 SWR 凭据: export SWR_USER=xxx SWR_PASS=xxx (华为云 SWR 登录指令中的用户名/密码)"

  # 本地集群只需要本机可运行架构
  if [[ "$ARCH" == "all" ]]; then
    warn "load2k8s 只注入本机可运行架构 (${HOST_ARCH})"
    ARCH="$HOST_ARCH"
  fi

  local active; active=($(get_active_images))

  stage "SWR → K8s containerd (k8s.io namespace)"
  log "SWR : ${SWR_FULL}"
  log "用户: ${SWR_USER}"
  log "架构: linux/$(eff_arch) (本机: ${HOST_ARCH})"
  log "总数: ${#active[@]}${FILTER:+  (过滤: ${FILTER})}"
  echo ""

  local ok=0 skip=0 fail=0
  local failed_list=()

  for src in "${active[@]}"; do
    [[ -n "$FILTER" && "$src" != *"$FILTER"* ]] && continue
    local swr_ref; swr_ref=$(to_swr "$src")
    local k8s_ref; k8s_ref=$(to_full_ref "$src")

    printf "  %-58s" "$k8s_ref"

    # 幂等: 本机已存在
    if k8s_image_exists "$k8s_ref"; then
      echo -e "  ${GRAY}已存在, 跳过${RESET}"
      skip=$((skip + 1)); continue
    fi

    # 拉取指定架构
    if ! sudo ctr -n k8s.io images pull --platform "linux/$(eff_arch)" \
         --user "${SWR_USER}:${SWR_PASS}" "$swr_ref" >/dev/null 2>&1; then
      echo -e "  ${RED}❌ 拉取失败 (SWR 中可能没有 linux/$(eff_arch) 版本, 先跑: $0 arch)${RESET}"
      fail=$((fail + 1)); failed_list+=("$src"); continue
    fi

    # 打回官方名, 让 kubelet 能按原始镜像名命中
    sudo ctr -n k8s.io images tag "$swr_ref" "$k8s_ref" >/dev/null 2>&1
    if k8s_image_exists "$k8s_ref"; then
      sudo ctr -n k8s.io images rm "$swr_ref" >/dev/null 2>&1   # 清理 SWR 名引用
      echo -e "  ${GREEN}✅ 已加载${RESET}"
      ok=$((ok + 1))
    else
      echo -e "  ${RED}❌ tag 失败${RESET}"
      fail=$((fail + 1)); failed_list+=("$src")
    fi
  done

  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "  K8s 加载完成  成功:${ok}  跳过:${skip}  失败:${fail}"
  echo "══════════════════════════════════════════════════════════"
  [[ ${#failed_list[@]} -gt 0 ]] && { echo "失败列表:"; printf "  ❌ %s\n" "${failed_list[@]}"; }

  echo ""
  echo "本机 K8s 可用镜像:"
  sudo crictl images 2>/dev/null | grep -vE "sealos.hub" | head -30 || sudo ctr -n k8s.io images ls -q
  echo ""
}

# ========================= arch =========================
# 检查 SWR 中每个镜像支持的平台 (arm64/amd64) — load2k8s 前建议先跑这个
do_arch() {
  command -v ctr >/dev/null 2>&1 || err "ctr 未安装"
  swr_auth || err "缺少 SWR 凭据: export SWR_USER=xxx SWR_PASS=xxx"

  stage "SWR 镜像架构检查 (本机: ${HOST_ARCH})"
  printf "  %-55s  %-8s  %-8s\n" "镜像" "arm64" "amd64"
  echo "  $(printf '%.0s─' {1..55})  $(printf '%.0s─' {1..8})  $(printf '%.0s─' {1..8})"

  for src in $(get_active_images); do
    local swr_ref; swr_ref=$(to_swr "$src")
    local a64="❌" x64="❌"
    sudo ctr -n k8s.io content fetch --user "${SWR_USER}:${SWR_PASS}" --platform linux/arm64 "$swr_ref" >/dev/null 2>&1 && a64="✅"
    sudo ctr -n k8s.io content fetch --user "${SWR_USER}:${SWR_PASS}" --platform linux/amd64 "$swr_ref" >/dev/null 2>&1 && x64="✅"
    printf "  %-55s  %-8s  %-8s\n" "$src" "$a64" "$x64"
  done
  echo ""
  warn "本机是 ${HOST_ARCH}: 只有 arm64 ✅ 的镜像才能在本机 K8s 运行"
  warn "如果 arm64 全是 ❌: 去 amd 服务器执行 $0 sync arm64 重新同步"
  echo ""
}

# ========================= export =========================
do_export() {
  command -v docker >/dev/null 2>&1 || err "docker 未安装 (export 需在装有 docker 的服务器执行)"

  # docker 本地存储单平台, 多架构离线包需分两次: export arm64 / export amd64
  if [[ "$ARCH" == "all" ]]; then
    warn "export 不支持 all (docker 本地只存单架构), 本次改用 native (${HOST_ARCH})"
    warn "如需双架构离线包: 分别执行 export arm64 和 export amd64, 生成两套 tar"
    ARCH="native"
  fi

  local active; active=($(get_active_images))

  # 应用过滤参数 (如: export vesoft arm64)
  local list=() s
  for s in "${active[@]}"; do
    [[ -n "$FILTER" && "$s" != *"$FILTER"* ]] && continue
    list+=("$s")
  done

  local total=${#list[@]} ok=0 skip_count=0 fail=0
  local export_dir="./docker-images-export"
  local tar_dir="${export_dir}/images"
  mkdir -p "$tar_dir"

  stage "从 SWR 拉取 → 改回官方名 → 导出 tar"
  log "SWR: ${SWR_FULL}"
  log "架构: linux/$(eff_arch) (本机: ${HOST_ARCH})"
  log "导出: ${export_dir}/"
  log "总数: ${total}${FILTER:+  (过滤: ${FILTER})}"
  echo ""

  for (( i=0; i<total; i++ )); do
    local swr_src; swr_src=$(to_swr "${list[$i]}")
    local official="${list[$i]}"
    local tar_name; tar_name=$(to_tarname "$official")
    local tar_path="${tar_dir}/${tar_name}"

    echo -e "\n[${i}+1/${total}] ${CYAN}${official}${RESET}"

    # 幂等: tar 已存在则跳过
    if [[ -f "$tar_path" ]]; then
      skip "tar 已存在, 跳过"
      skip_count=$((skip_count + 1)); continue
    fi

    echo "         ← ${swr_src}"

    if pull_image "$swr_src"; then
      docker tag "$swr_src" "$official"
      if docker save -o "$tar_path" "$official"; then
        ok=$((ok + 1)); log "✅ 导出成功 ($(du -h "$tar_path" | cut -f1))"
      else
        fail=$((fail + 1)); warn "❌ save 失败 (原因见上方日志)"
      fi
    else
      fail=$((fail + 1)); warn "❌ pull 失败 (可能无 linux/$(eff_arch) 版本)"
    fi
  done

  # 生成 load.sh (containerd/docker 自适应)
  _gen_load_script "$export_dir"

  # 打包
  stage "打包离线文件"
  local archive="docker-images-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "${archive}" -C "$(dirname "$export_dir")" "$(basename "$export_dir")"
  local size; size=$(du -h "${archive}" | cut -f1)

  echo ""
  echo "══════════════════════════════════════════════════════════"
  echo "  导出完成  成功:${ok}  跳过:${skip_count}  失败:${fail}"
  echo "══════════════════════════════════════════════════════════"
  echo "  包文件: ${archive} (${size})"
  echo ""
  echo "  使用方法:"
  echo "    1. scp ${archive} <K8s节点>:/tmp/"
  echo "    2. ssh <节点> 'cd /tmp && tar -xzf ${archive} && cd docker-images-export && bash load.sh'"
  echo "    3. load.sh 自动适配 containerd (k8s.io namespace) / docker"
  echo ""
}

# 一键加载脚本: 自动适配 containerd / docker
_gen_load_script() {
  local dir="$1"
  cat > "${dir}/load.sh" <<'LOADSCRIPT'
#!/usr/bin/env bash
# 一键加载镜像到 K8s (自动适配 containerd / docker)
#   containerd (K8s 集群标准): ctr -n k8s.io images import → kubelet 直接可用
#   docker: docker load
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAR_DIR="${SCRIPT_DIR}/images"

GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; GRAY='\033[90m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()  { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

[[ -d "$TAR_DIR" ]] || err "镜像目录不存在: ${TAR_DIR}"
total=$(find "$TAR_DIR" -maxdepth 1 -name '*.tar' 2>/dev/null | wc -l)
[[ $total -eq 0 ]] && err "未找到 .tar 文件"

# ── 运行时检测: 优先 containerd (K8s 集群), 其次 docker ──
ENGINE=""
if command -v ctr >/dev/null 2>&1 && sudo ctr namespaces ls >/dev/null 2>&1; then
  ENGINE="containerd"
  log "检测到 containerd → 镜像注入 k8s.io namespace (kubelet 直接可用)"
elif command -v docker >/dev/null 2>&1; then
  ENGINE="docker"
  log "检测到 docker → docker load"
  warn "K8s 若用 containerd 运行时, docker load 的镜像 kubelet 看不到!"
else
  err "未找到 ctr 或 docker, 无法加载镜像"
fi
echo ""

log "找到 ${total} 个镜像 tar, 开始加载 ..."
echo ""

ok=0; fail=0; skip=0
for tar_file in "${TAR_DIR}"/*.tar; do
  name=$(basename "$tar_file" .tar)
  printf "  %-58s" "${name}"

  output=""
  if [[ "$ENGINE" == "containerd" ]]; then
    if output=$(sudo ctr -n k8s.io images import "$tar_file" 2>&1); then
      echo -e "  ${GREEN}✅ (k8s.io)${RESET}"
      ok=$((ok + 1))
    elif echo "$output" | grep -qi "already exists"; then
      echo -e "  ${GRAY}已存在, 跳过${RESET}"
      skip=$((skip + 1))
    else
      echo -e "  ${RED}❌${RESET}"
      echo "$output" | head -2 | sed 's/^/         /'
      fail=$((fail + 1))
    fi
  else
    if output=$(docker load -i "$tar_file" 2>&1); then
      echo -e "  ${GREEN}✅${RESET} ($(echo "$output" | grep -oP 'Loaded image: \K.*' | head -1))"
      ok=$((ok + 1))
    else
      echo -e "  ${RED}❌${RESET}"
      echo "$output" | head -2 | sed 's/^/         /'
      fail=$((fail + 1))
    fi
  fi
done

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  加载完成: 成功 ${ok}, 跳过 ${skip}, 失败 ${fail}"
echo "══════════════════════════════════════════════════════════"

echo ""
if [[ "$ENGINE" == "containerd" ]]; then
  log "本机 K8s 可用镜像 (k8s.io namespace):"
  sudo crictl images 2>/dev/null | head -40 || sudo ctr -n k8s.io images ls -q | sed 's/^/  /'
else
  log "本地镜像列表:"
  docker images --format "  {{.Repository}}:{{.Tag}}\t{{.Size}}" | sort
fi
echo ""
warn "提示: Pod 使用本地镜像需 imagePullPolicy 为 IfNotPresent 或 Never"
echo ""
LOADSCRIPT
  chmod +x "${dir}/load.sh"
}

# ========================= import =========================
do_import() {
  local import_dir=""

  if [[ -d "./docker-images-export/images" ]]; then
    import_dir="./docker-images-export"
  else
    local latest
    latest=$(ls -t docker-images-*.tar.gz 2>/dev/null | head -1)
    if [[ -n "$latest" ]]; then
      log "解压 ${latest} ..."
      tar -xzf "$latest"
      import_dir="./docker-images-export"
    fi
  fi

  [[ -n "$import_dir" && -d "${import_dir}/images" ]] || \
    err "未找到镜像文件, 请确保目录下有 docker-images-export/ 或 docker-images-*.tar.gz"

  bash "${import_dir}/load.sh"
}

# ========================= status =========================
do_status() {
  command -v docker >/dev/null 2>&1 || err "docker 未安装 (status 用 docker manifest inspect 检查)"

  local active; active=($(get_active_images))
  local total=${#active[@]}

  stage "SWR 镜像状态检查"
  log "仓库: ${SWR_FULL}"
  echo ""

  printf "  ${CYAN}%-55s${RESET}  %-10s  %s\n" "镜像" "状态" "SWR 地址"
  echo "  $(printf '%.0s─' {1..55})  $(printf '%.0s─' {1..10})  $(printf '%.0s─' {1..55})"

  local exist=0 missing=0
  for (( i=0; i<total; i++ )); do
    local src="${active[$i]}"
    local swr; swr=$(to_swr "$src")
    if swr_exists "$swr"; then
      printf "  %-55s  ${GREEN}%-10s${RESET}  %s\n" "$src" "✅ 已同步" "$swr"
      exist=$((exist + 1))
    else
      printf "  %-55s  ${RED}%-10s${RESET}  %s\n" "$src" "❌ 未同步" "$swr"
      missing=$((missing + 1))
    fi
  done

  echo ""
  echo "  共 ${total} 个: 已同步 ${exist}, 未同步 ${missing}"
  echo ""
}

# ========================= list =========================
do_list() {
  local active; active=($(get_active_images))
  local total=${#active[@]}

  stage "镜像对照表 (官方 → SWR)"
  echo ""
  printf "  ${CYAN}%-58s${RESET}  →  %s\n" "官方镜像" "SWR 镜像"
  echo "  $(printf '%.0s─' {1..58})  ─  $(printf '%.0s─' {1..58})"

  for (( i=0; i<total; i++ )); do
    local swr; swr=$(to_swr "${active[$i]}")
    printf "  %-58s  →  %s\n" "${active[$i]}" "$swr"
  done

  if [[ ${#EXCLUDE[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${YELLOW}排除列表:${RESET}"
    for pat in "${EXCLUDE[@]}"; do
      [[ -n "$pat" ]] && echo "    - $pat"
    done
  fi

  echo ""
  echo "  总计: ${#IMAGES[@]} 个, 活跃: ${total} 个, 排除: $((${#IMAGES[@]}-total)) 个"
  echo ""
}

# ========================= usage =========================
usage() {
  cat <<EOF
用法: $0 <command> [架构/过滤参数]

命令:
  sync      拉取官方镜像 → 推送到华为云 SWR (幂等: 已存在跳过) [需 docker, 海外服务器]
  export    从 SWR 拉取 → 改回官方名 → 打包 tar.gz [需 docker]
  import    解压 tar.gz → 加载镜像 (自动适配 containerd / docker)
  load2k8s  直接从 SWR 拉取 → 打回官方名 → 注入 K8s containerd [推荐, 免 docker]
  arch      检查 SWR 镜像的 CPU 架构 (arm64/amd64), load2k8s 前建议先执行
  list      查看镜像对照表
  status    检查 SWR 仓库中镜像同步状态 [需 docker]

架构参数 (sync/export/load2k8s 都支持, ★默认 all 双架构):
  all             完整双架构 amd64+arm64 (逐架构 docker pull→push→manifest 组合,
                 SWR 兼容 Docker manifest list; 可选 SKOPEO_FAST=1 用 skopeo 加速)
  arm64 / amd64   强制指定架构 — amd64 服务器给 ARM K8s 单架构同步: bash $0 sync arm64
  native          本机架构

写法 (三种等价):
  bash $0 sync arm64
  bash $0 sync --arch arm64
  ARCH=arm64 bash $0 sync

load2k8s 过滤:
  bash $0 load2k8s mysql    (只处理名称含 mysql 的镜像)

SWR 凭据 (load2k8s / arch 需要):
  export SWR_USER=<华为云用户名>
  export SWR_PASS=<SWR 登录密码>
  (或已在 ~/.docker/config.json 中登录过)

Docker Hub 限流 (429 Too Many Requests) 时:
  SRC_MIRROR=docker.1ms.run bash $0 sync    # docker.io 源改走国内代理站
  或: docker login docker.io                # 免费账号登录, 限额提升到 200次/6h

典型流程:
  # ── 方案 A: 直连 (网络互通时最简单) ──
  # K8s 服务器 (ARM64):
  bash $0 arch           # 确认 SWR 镜像有 arm64
  bash $0 load2k8s       # 拉取 → 打回官方名 → 注入集群

  # ── 方案 B: amd64 海外服务器先同步 arm64 到 SWR ──
  bash $0 sync arm64     # 在 amd 服务器上: 强制拉 arm64 → 推 SWR
  # 然后 K8s 服务器上执行 方案 A

  # ── 方案 C: 离线包 ──
  bash $0 export arm64   # 海外服务器: 打 arm64 离线包
  bash $0 import         # K8s 服务器: 加载 (自动适配 containerd)

配置:
  IMAGES 数组   - 维护所有镜像 (脚本顶部)
  EXCLUDE 数组  - 排除不需要的镜像 (支持子串匹配)
EOF
}

# ========================= 主入口 =========================
COMMAND="${1:-}"
[[ $# -gt 0 ]] && shift
case "$COMMAND" in
  sync)     parse_args "$@"; do_sync ;;
  export)   parse_args "$@"; do_export ;;
  import)   parse_args "$@"; do_import ;;
  load2k8s) parse_args "$@"; do_load2k8s ;;
  arch)     parse_args "$@"; do_arch ;;
  list)     parse_args "$@"; do_list ;;
  status)   parse_args "$@"; do_status ;;
  *)        usage; exit 1 ;;
esac




#!/usr/bin/env bash
# ==============================================================================
# lops 模块: docker — Docker 环境
# ==============================================================================
# 功能:
#   - install  官方源安装 Docker CE + docker-compose-plugin（国内源加速）
#   - status   服务状态、引擎信息、容器/镜像统计与磁盘占用概览
#   - mirror   配置/更新 daemon.json 镜像加速（备份后重写，重启需确认）
#   - clean    清理悬空镜像/已停止容器/未使用网络/构建缓存（清理前确认）
#   - ps       容器一览（ID/镜像/状态/端口/名称 格式化表格）
# ==============================================================================

# 可配置项（执行前可通过环境变量覆盖，见 mod_docker_help）
LOPS_DOCKER_LOG_MAX_SIZE="${LOPS_DOCKER_LOG_MAX_SIZE:-100m}"   # 单容器日志文件上限
LOPS_DOCKER_LOG_MAX_FILE="${LOPS_DOCKER_LOG_MAX_FILE:-3}"      # 日志文件保留个数
# 镜像加速地址列表（空格分隔，可写多个）
LOPS_DOCKER_MIRRORS="${LOPS_DOCKER_MIRRORS:-https://docker.1ms.run https://docker.m.daocloud.io}"

mod_docker_desc() {
  echo "Docker 环境（安装/镜像加速/状态概览/清理/容器一览）"
}

mod_docker_actions() {
  cat <<'EOF'
install|官方源安装 Docker CE 与 compose 插件（国内源加速 + 基础 daemon.json）
status|Docker 服务状态、引擎信息与磁盘占用概览
mirror|配置/更新 daemon.json 镜像加速（备份后重写，重启需确认）
clean|清理悬空镜像/已停止容器/未使用网络/构建缓存（清理前确认）
ps|容器一览（ID/镜像/状态/端口/名称 格式化表格）
EOF
}

mod_docker_help() {
  cat <<'EOF'
lops docker — Docker 环境
==============================================================================
Docker CE 的安装、配置与日常维护: 官方源安装（国内镜像加速）、
daemon.json 标准化（日志上限 + 镜像加速）、状态概览、空间清理、容器一览。

用法:
  ./lops.sh docker <action>

动作说明:
  install
      通过 mirrors.aliyun.com 的 docker-ce 官方源安装:
      docker-ce / docker-ce-cli / containerd.io / docker-buildx-plugin /
      docker-compose-plugin。
      区分发行版: Ubuntu/Debian 配置 apt keyring 签名源（按发行版代号），
      CentOS/RHEL/Rocky/Alma 配置 yum repo（$releasever 匹配）。
      安装完成后写入 /etc/docker/daemon.json:
        - 日志: log-driver json-file, max-size 100m, max-file 3
          （防止单容器日志撑爆磁盘）
        - 镜像加速: https://docker.1ms.run, https://docker.m.daocloud.io
      并执行 systemctl enable --now docker。
      若已安装则提示并显示版本，不重复安装。
  status
      Docker 概览: 服务状态（active/开机自启）、Client/Server 版本、
      引擎信息（存储驱动/Root 目录）、容器/镜像统计、
      磁盘占用（docker system df）。
  mirror
      仅配置/更新 daemon.json 镜像加速（已有文件先备份为
      *.bak.<时间戳> 后重写，自定义配置请自行对比合并），
      重启 docker 前需二次确认（运行中容器会短暂中断），
      重启后输出当前生效的 Registry Mirrors 验证结果。
  clean
      清理悬空镜像（dangling）、已停止容器、未使用网络与构建缓存。
      清理前先展示 docker system df 可回收空间并要求确认。
      不删除: 带标签的未使用镜像、数据卷（需 --volumes 才会清理）。
  ps
      容器一览: docker ps -a 格式化表格
      （ID / 镜像 / 状态 / 端口 / 名称）。

可配置环境变量（执行前 export 覆盖默认值）:
  LOPS_DOCKER_LOG_MAX_SIZE=100m                      # 单容器日志文件上限
  LOPS_DOCKER_LOG_MAX_FILE=3                         # 日志文件保留个数
  LOPS_DOCKER_MIRRORS="https://docker.1ms.run https://docker.m.daocloud.io"
                                                     # 镜像加速列表（空格分隔）

示例:
  sudo ./lops.sh docker install                      # 安装 Docker CE
  ./lops.sh docker status                            # 查看状态与磁盘占用
  sudo ./lops.sh docker mirror                       # 配置/更新镜像加速
  ./lops.sh docker clean                             # 清理无用资源
  ./lops.sh docker ps                                # 容器一览
  LOPS_DOCKER_MIRRORS="https://docker.1ms.run" \
    sudo ./lops.sh docker mirror                     # 只保留单个加速地址

前置条件:
  - install / mirror 需要 root（写系统源、daemon.json、重启服务）
  - status / clean / ps 需要 docker 命令已安装，且当前用户可连接 daemon
    （root，或加入 docker 组: sudo usermod -aG docker <用户> 后重新登录）
  - install 需要可访问 mirrors.aliyun.com（离线环境请自行配置本地源）

注意事项:
  - install 完成后不自动运行 hello-world（避免离线/受限环境误报），
    联网时可手动执行 docker run --rm hello-world 验证。
  - openEuler 等非标准 redhat 发行版的 $releasever 与 docker-ce 的
    centos 目录可能不匹配，install 失败时请手动调整
    /etc/yum.repos.d/docker-ce.repo 中的 baseurl。
  - mirror/clean 涉及重启服务与删除资源，均内置二次确认，输入 y 才执行。
  - daemon.json 重写前自动备份，出问题可回滚:
    cp /etc/docker/daemon.json.bak.<时间戳> /etc/docker/daemon.json。
EOF
}

# ---------- 内部工具 ----------

# 校验 docker CLI 已安装
docker__require_docker() {
  if ! command -v docker >/dev/null; then
    err "未检测到 docker，请先执行: sudo ./lops.sh docker install"
    return 1
  fi
}

# 校验 docker daemon 可连接（CLI 存在但服务未运行/无权限时给出提示）
docker__require_daemon() {
  if ! docker info >/dev/null 2>/dev/null; then
    err "无法连接 Docker daemon（服务未运行或当前用户无权限）"
    warn "可尝试 sudo 执行，或将用户加入 docker 组: sudo usermod -aG docker \$USER（重新登录后生效）"
    return 1
  fi
}

# 生成/重写 /etc/docker/daemon.json（日志限制 + 镜像加速；写入前自动备份）
docker__write_daemon_json() {
  mkdir -p /etc/docker
  backup_file /etc/docker/daemon.json

  # 拼接 registry-mirrors JSON 数组（LOPS_DOCKER_MIRRORS 为空格分隔列表）
  # shellcheck disable=SC2086
  local m first=1 mirrors_json=""
  for m in ${LOPS_DOCKER_MIRRORS}; do
    if (( first )); then first=0; else mirrors_json+=","; fi
    mirrors_json+="    \"${m}\""
  done

  cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${LOPS_DOCKER_LOG_MAX_SIZE}",
    "max-file": "${LOPS_DOCKER_LOG_MAX_FILE}"
  },
  "registry-mirrors": [
${mirrors_json}
  ]
}
EOF
  log "已写入 /etc/docker/daemon.json（日志上限 ${LOPS_DOCKER_LOG_MAX_SIZE} × ${LOPS_DOCKER_LOG_MAX_FILE} 份，镜像加速: ${LOPS_DOCKER_MIRRORS}）"
}

# ---------- 动作实现 ----------
# 官方源安装 Docker CE + compose 插件（国内源加速）
# 将所有 dev 组的 bash 登录用户追加进 docker 组（幂等；docker/dev 组不存在则跳过）
# 调用方: docker__install（新装完成后同步）与 init user（已装 docker 时同步）
docker__sync_dev_group() {
  if ! getent group docker >/dev/null 2>&1; then
    log "docker 组不存在（Docker 未安装），跳过 dev 成员追加"
    return 0
  fi
  if ! getent group dev >/dev/null 2>&1; then
    log "dev 组不存在，跳过 docker 组成员追加"
    return 0
  fi
  local u shell home n=0
  while IFS=: read -r u _ _ _ _ home shell; do
    [[ "$shell" == */bash && -d "$home" ]] || continue
    id -nG "$u" 2>/dev/null | grep -qw dev || continue
    id -nG "$u" 2>/dev/null | grep -qw docker && continue
    usermod -aG docker "$u" && n=$((n + 1))
  done < /etc/passwd
  log "docker 组成员同步完成（本次新追加 ${n} 人，成员需重新登录生效）"
}

docker__install() {
  require_root
  detect_os

  # 已安装则提示并显示版本，不重复安装
  if command -v docker >/dev/null; then
    log "Docker 已安装:"
    docker --version || true
    local st
    st="$(systemctl is-active docker 2>/dev/null || true)"
    log "docker 服务状态: ${st:-unknown}"
    warn "如需更新镜像加速配置，请执行: sudo ./lops.sh docker mirror"
    docker__sync_dev_group
    return 0
  fi

  section "配置 Docker CE 软件源（mirrors.aliyun.com 加速）"
  if is_debian_family; then
    # Ubuntu / Debian: apt + keyring 签名源（按发行版代号匹配）
    pkg_install ca-certificates curl gnupg || { err "基础依赖（ca-certificates/curl/gnupg）安装失败"; return 1; }
    install -m 0755 -d /etc/apt/keyrings
    # 阿里云 docker-ce 源的 GPG 公钥（ascii 装甲格式可直接作为 signed-by keyring）
    curl -fsSL "https://mirrors.aliyun.com/docker-ce/linux/${LOPS_OS_ID}/gpg" \
      -o /etc/apt/keyrings/docker.asc || { err "下载 docker GPG 公钥失败"; return 1; }
    chmod a+r /etc/apt/keyrings/docker.asc
    local codename arch
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    arch="$(dpkg --print-architecture)"
    [[ -n "$codename" ]] || { err "无法识别发行版代号（VERSION_CODENAME 为空）"; return 1; }
    backup_file /etc/apt/sources.list.d/docker.list
    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.aliyun.com/docker-ce/linux/${LOPS_OS_ID} ${codename} stable
EOF
    log "apt 源已配置: docker-ce（${LOPS_OS_ID} ${codename}，arch ${arch}）"
  else
    # CentOS / RHEL / Rocky / Alma: yum repo（$releasever/$basearch 自动匹配）
    backup_file /etc/yum.repos.d/docker-ce.repo
    cat > /etc/yum.repos.d/docker-ce.repo <<'EOF'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/docker-ce/linux/centos/gpg
EOF
    log "yum 源已配置: docker-ce-stable（mirrors.aliyun.com）"
  fi

  section "安装 Docker CE 与 compose 插件"
  local pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  if ! is_debian_family; then
    # CentOS7 等需要 extras 源中的 container-selinux，预装一次（失败不阻断）
    pkg_install container-selinux || true
  fi
  pkg_install "${pkgs[@]}" || { err "Docker 安装失败，请检查网络/源配置后重试"; return 1; }

  section "写入 daemon.json（日志限制 + 镜像加速）"
  docker__write_daemon_json

  section "启动并设置开机自启"
  systemctl enable --now docker || { err "docker 服务启动失败，请排查: journalctl -u docker -e"; return 1; }
  sleep 2
  # dev 组成员自动追加 docker 组（幂等；无 dev 组则跳过）
  docker__sync_dev_group

  section "安装结果"
  docker --version || true
  docker compose version || true
  local st2
  st2="$(systemctl is-active docker 2>/dev/null || true)"
  log "docker 服务状态: ${st2:-unknown}"

  hr
  log "建议执行以下命令验证安装（需可访问镜像仓库，离线环境请忽略）:"
  echo "    docker run --rm hello-world"
  warn "为避免离线/受限环境误报，本工具不会自动执行验证命令"
}

# Docker 服务状态、引擎信息与磁盘占用概览
docker__status() {
  docker__require_docker || return 1

  section "服务状态"
  local state enabled
  state="$(systemctl is-active docker 2>/dev/null || true)"
  enabled="$(systemctl is-enabled docker 2>/dev/null || true)"
  printf "  服务状态: %s\n" "${state:-unknown}"
  printf "  开机自启: %s\n" "${enabled:-unknown}"
  docker --version || true

  # daemon 连接检查（不可连接时给出权限提示后退出）
  docker__require_daemon || return 1

  section "引擎信息"
  docker info --format '  Server Version:  {{.ServerVersion}}
  Storage Driver: {{.Driver}}
  Cgroup Driver:  {{.CgroupDriver}}
  Docker Root:    {{.DockerRootDir}}' || true

  section "容器/镜像/磁盘占用"
  docker info --format '  容器总数: {{.Containers}}（运行 {{.ContainersRunning}} / 暂停 {{.ContainersPaused}} / 停止 {{.ContainersStopped}}）
  镜像数量: {{.Images}}' || true
  docker system df || true
  hr
  log "容器明细可执行: ./lops.sh docker ps"
}

# 配置/更新 daemon.json 镜像加速并重启 docker（需确认）
docker__mirror() {
  require_root
  docker__require_docker || return 1

  section "配置 Docker 镜像加速"
  docker__write_daemon_json

  if confirm "立即重启 docker 使配置生效？（运行中的容器会短暂中断）"; then
    section "重启 docker"
    systemctl restart docker || { err "docker 重启失败，请排查: journalctl -u docker -e"; return 1; }
    sleep 3
    if ! docker info >/dev/null 2>/dev/null; then
      err "docker 重启后无法连接，请检查 daemon.json 是否合法: cat /etc/docker/daemon.json"
      return 1
    fi
    log "重启成功，当前生效的镜像加速:"
    docker info 2>/dev/null | grep -A 3 "Registry Mirrors" \
      || warn "未能从 docker info 读取到 Registry Mirrors 字段，请人工确认"
  else
    log "已跳过重启，稍后手动执行: sudo systemctl restart docker"
  fi
}

# 清理悬空镜像/已停止容器/未使用网络/构建缓存（清理前确认）
docker__clean() {
  docker__require_docker || return 1
  docker__require_daemon || return 1

  section "当前 Docker 磁盘占用（docker system df）"
  docker system df

  section "清理范围"
  cat <<'EOF'
  - 悬空镜像（dangling: 无标签且无容器引用）
  - 已停止的容器
  - 未被使用的网络
  - 构建缓存

  不会删除: 带标签的未使用镜像、数据卷（需 --volumes 才会清理）
EOF

  if ! confirm "确认执行 docker system prune -f 清理上述内容？"; then
    log "已取消清理"
    return 0
  fi

  section "执行清理"
  docker system prune -f || { err "清理执行失败"; return 1; }

  section "清理后磁盘占用"
  docker system df
  log "清理完成"
}

# 容器一览（格式化表格）
docker__ps() {
  docker__require_docker || return 1
  docker__require_daemon || return 1

  section "容器一览（docker ps -a）"
  docker ps -a --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Names}}"
  hr
  log "仅查看运行中的容器可执行: docker ps"
}

# ---------- 动作分发 ----------

mod_docker_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_docker_help; return 1; }
  shift || true

  case "$action" in
    install) docker__install "$@" ;;
    status)  docker__status "$@" ;;
    mirror)  docker__mirror "$@" ;;
    clean)   docker__clean "$@" ;;
    ps)      docker__ps "$@" ;;
    *)
      err "未知动作: docker ${action}"
      mod_docker_help
      return 1
      ;;
  esac
}
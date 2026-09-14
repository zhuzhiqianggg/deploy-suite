#!/usr/bin/env bash
# ==============================================================================
# lops 模块: pkg — 软件源与常用工具
# ==============================================================================
# 功能:
#   - mirror  换国内源（CentOS 7 阿里云 base/updates/extras/EPEL、Ubuntu 阿里云）
#   - tools   一键安装常用运维工具集（缺哪个装哪个，已装跳过）
#   - list    最近安装的软件包（rpm -qa --last / dpkg 日志）
#   - clean   包缓存清理（先显示占用，确认后 yum clean all / apt clean）
# ==============================================================================

# 可配置项（执行前可通过环境变量覆盖，见 mod_pkg_help）
LOPS_PKG_CENTOS7_VERSION="${LOPS_PKG_CENTOS7_VERSION:-7.9.2009}"  # CentOS 7 vault 归档版本

mod_pkg_desc() {
  echo "软件源与常用工具（换阿里云源/一键装运维工具/最近安装/缓存清理）"
}

mod_pkg_actions() {
  cat <<'EOF'
mirror|换国内源（CentOS 7 阿里云 base+EPEL / Ubuntu 阿里云，备份后切换并验证）
tools|一键安装常用运维工具集（htop/iotop/iftop/tcpdump/nmap 等 16 项，缺哪装哪）
list|最近安装的软件包（rpm -qa --last / dpkg 日志，默认前 20 个）
clean|包缓存清理（先显示缓存占用，确认后 yum clean all / apt clean）
EOF
}

mod_pkg_help() {
  cat <<'EOF'
lops pkg — 软件源与常用工具
==============================================================================
软件源治理与工具装机：把源换成国内镜像（下载提速数倍）、一键补齐
常用运维工具集、查看最近装过什么包、清理包管理缓存。

用法:
  ./lops.sh pkg <action> [参数]

动作说明:
  mirror
      切换为阿里云镜像源（写系统配置，原文件自动备份，需二次确认）:
        - CentOS 7: 重写 /etc/yum.repos.d/CentOS-Base.repo（base/updates/
          extras）与 /etc/yum.repos.d/epel.repo（EPEL），指向阿里云
          centos-vault / epel-archive 归档镜像。
          小知识: CentOS 7 已于 2024-06-30 停止维护（EOL），官方源
          mirrorlist.centos.org 已下线，软件包只保留在 vault 归档库，
          归档版本默认 7.9.2009（可用 LOPS_PKG_CENTOS7_VERSION 覆盖）。
        - Ubuntu: 用 sed 把 /etc/apt/sources.list（及 24.04 的
          /etc/apt/sources.list.d/ubuntu.sources）中的
          archive.ubuntu.com / security.ubuntu.com / ports.ubuntu.com
          替换为 mirrors.aliyun.com（ARM 架构映射到 ubuntu-ports）。
        - 其他发行版（Debian/Rocky/AlmaLinux/RHEL 等）明确提示不支持，
          避免写坏源配置。
      完成后执行 yum clean all && yum makecache / apt-get update 验证；
      验证失败可用备份回滚:
        cp <原文件>.bak.<时间戳> <原文件>
  tools
      一键安装常用运维工具集（16 项，逐个检查、缺哪个装哪个）:
        htop iotop iftop sysstat lsof tcpdump nc nmap telnet tree
        bash-completion rsync net-tools vim wget unzip
      已安装（命令已存在）自动跳过，全部装完后输出逐项状态清单。
      小知识: 包名在不同发行版不同——CentOS 的 nc 来自 nmap-ncat、
      vim 来自 vim-enhanced，Ubuntu 的 nc 来自 netcat-openbsd，
      本动作已按发行版自动映射。CentOS 7 的 htop/iftop/nmap 位于
      EPEL 源，会先自动安装 epel-release。
  list [N]
      最近安装的软件包（默认前 20 个）:
        - CentOS/RHEL: rpm -qa --last（按安装时间倒序）
        - Ubuntu/Debian: grep " install " /var/log/dpkg.log
      只读操作，无需 root。
  clean
      包管理缓存清理: 先显示缓存目录占用
        （/var/cache/yum 或 /var/cache/apt/archives），
      确认后执行 yum clean all / apt-get clean。
      小知识: 包缓存是已下载安装包的副本，装完软件后可安全清理，
      不影响已安装的软件，只是下次安装要重新下载。

可配置环境变量（执行前 export 覆盖默认值）:
  LOPS_PKG_CENTOS7_VERSION=7.9.2009   # CentOS 7 vault 归档版本号

示例:
  sudo ./lops.sh pkg mirror            # 换阿里云源（备份+验证）
  sudo ./lops.sh pkg tools             # 一键补齐运维工具
  ./lops.sh pkg list                   # 最近装了什么
  ./lops.sh pkg list 50                # 最近 50 个
  sudo ./lops.sh pkg clean             # 清理包缓存

前置条件:
  - mirror / tools / clean 需要 root（写系统源、装包、清缓存）
  - mirror 需要能访问 mirrors.aliyun.com（离线环境请自行配置本地源）
  - list 只读无需 root

注意事项:
  - mirror 会重写源配置，属于有风险操作: 原文件自动备份为
    *.bak.<时间戳>，验证失败时先回滚再排查网络。
  - CentOS 7 已 EOL，归档源不再有安全更新，条件允许请尽快迁移到
    Rocky/AlmaLinux 等仍在维护的发行版。
  - tools 在 CentOS 7 依赖 EPEL 提供 htop/iftop/nmap，若 EPEL 配置
    失败这几项会安装失败，其余工具不受影响。
EOF
}

# ---------- 内部工具 ----------

# 判断软件包是否已安装（区分 rpm / dpkg）
pkg__is_installed() {
  if is_redhat_family; then
    rpm -q "$1" >/dev/null 2>&1
  else
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
  fi
}

# ---------- mirror ----------

pkg__mirror() {
  require_root
  detect_os
  section "软件源切换（阿里云镜像）"

  if is_debian_family; then
    if [[ "${LOPS_OS_ID}" != "ubuntu" ]]; then
      err "暂不支持为该发行版换源: ${LOPS_OS_ID} ${LOPS_OS_VERSION}（当前支持 Ubuntu / CentOS 7）"
      return 1
    fi
    pkg__mirror_ubuntu
  elif is_redhat_family; then
    if [[ "${LOPS_OS_ID}" != "centos" || ! "${LOPS_OS_VERSION}" =~ ^7 ]]; then
      err "暂不支持为该发行版换源: ${LOPS_OS_ID} ${LOPS_OS_VERSION}（当前支持 CentOS 7 / Ubuntu）"
      return 1
    fi
    pkg__mirror_centos7
  else
    err "暂不支持的发行版: ${LOPS_OS_ID}"
    return 1
  fi
}

pkg__mirror_ubuntu() {
  local sl="/etc/apt/sources.list"
  local sl822="/etc/apt/sources.list.d/ubuntu.sources"   # Ubuntu 24.04+ deb822 格式

  if [[ ! -f "$sl" && ! -f "$sl822" ]]; then
    err "未找到 apt 源配置（${sl} 或 ${sl822}）"
    return 1
  fi

  warn "将把 apt 源切换为阿里云镜像 mirrors.aliyun.com（原文件自动备份）"
  if ! confirm "确认切换 Ubuntu 软件源为阿里云"; then
    log "已取消"
    return 0
  fi

  local -a edited=()
  local f
  for f in "$sl" "$sl822"; do
    [[ -f "$f" ]] || continue
    backup_file "$f"
    # 域名整体替换为阿里云镜像（不区分 http/https；ARM 架构走 ubuntu-ports）
    sed -i \
      -e 's|//archive.ubuntu.com|//mirrors.aliyun.com|g' \
      -e 's|//security.ubuntu.com|//mirrors.aliyun.com|g' \
      -e 's|//cn.archive.ubuntu.com|//mirrors.aliyun.com|g' \
      -e 's|//ports.ubuntu.com/ubuntu-ports|//mirrors.aliyun.com/ubuntu-ports|g' \
      "$f"
    edited+=("$f")
  done

  section "修改后的源地址（前 5 行）"
  for f in "${edited[@]}"; do
    echo "--- ${f} ---"
    grep -E '^(deb |Types:|URIs:)' "$f" | head -n 5 || true
  done

  section "验证源可用性（apt-get update）"
  if apt-get update 2>&1 | tail -n 15; then
    mark_ok "Ubuntu 换源完成，apt 源可用"
  else
    mark_bad "apt-get update 失败: 请检查网络，或用备份回滚（*.bak.<时间戳> 文件）"
    return 1
  fi
}

pkg__mirror_centos7() {
  local ver="${LOPS_PKG_CENTOS7_VERSION}"
  local base_repo="/etc/yum.repos.d/CentOS-Base.repo"
  local epel_repo="/etc/yum.repos.d/epel.repo"
  local gpg_local="/etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7"
  local epel_key="/etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7"

  warn "CentOS 7 已于 2024-06-30 停止维护（EOL），官方源已下线"
  warn "将切换为阿里云归档镜像: centos-vault/${ver}（base/updates/extras）+ epel-archive/7（EPEL）"
  if ! confirm "确认切换 CentOS 7 软件源为阿里云镜像"; then
    log "已取消"
    return 0
  fi

  # ① base / updates / extras（centos-vault 归档）
  backup_file "$base_repo"
  cat > "$base_repo" <<EOF
# 由 lops pkg mirror 生成 —— 阿里云 centos-vault 归档镜像（CentOS 7 已 EOL）
[base]
name=CentOS-7 - Base - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-vault/${ver}/os/\$basearch/
gpgcheck=1
gpgkey=file://${gpg_local}

[updates]
name=CentOS-7 - Updates - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-vault/${ver}/updates/\$basearch/
gpgcheck=1
gpgkey=file://${gpg_local}

[extras]
name=CentOS-7 - Extras - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/centos-vault/${ver}/extras/\$basearch/
gpgcheck=1
gpgkey=file://${gpg_local}
EOF
  log "已写入 ${base_repo}"

  # ② EPEL（公钥存在则开校验，否则降级 gpgcheck=0 并提示）
  local epel_gpgcheck=1
  if [[ ! -f "$epel_key" ]]; then
    epel_gpgcheck=0
    warn "本机缺少 EPEL GPG 公钥（${epel_key}），EPEL 源暂设 gpgcheck=0"
  fi
  backup_file "$epel_repo"
  cat > "$epel_repo" <<EOF
# 由 lops pkg mirror 生成 —— 阿里云 epel-archive 归档镜像（EPEL 7 已 EOL）
[epel]
name=EPEL-7 - mirrors.aliyun.com
baseurl=https://mirrors.aliyun.com/epel-archive/7/\$basearch/
enabled=1
gpgcheck=${epel_gpgcheck}
gpgkey=file://${epel_key}
EOF
  log "已写入 ${epel_repo}"

  # ③ 清缓存并重建，验证源可用
  section "验证源可用性（yum clean all && yum makecache）"
  if yum clean all 2>&1 | tail -n 3 && yum makecache 2>&1 | tail -n 10; then
    mark_ok "CentOS 7 换源完成，yum 源可用"
  else
    mark_bad "yum makecache 失败: 请检查网络，或用备份回滚（*.bak.<时间戳> 文件）"
    mark_warn "若其他 repo（如 CentOS-fasttrack.repo）仍指向已下线的 mirrorlist.centos.org，可将其 enabled=0"
    return 1
  fi
}

# ---------- tools ----------

pkg__tools() {
  require_root
  detect_os
  section "常用运维工具集（一键补齐）"

  # CentOS 7 的 htop/iftop/nmap 位于 EPEL，先确保 epel 源可用
  if is_redhat_family && ! rpm -q epel-release >/dev/null 2>&1; then
    log "安装 epel-release（htop / iftop / nmap 位于 EPEL 源）..."
    pkg_install epel-release || warn "epel-release 安装失败，EPEL 相关工具可能装不上"
  fi

  # 工具清单: "检查命令:包名"，@pkg 表示无对应命令、按包名检查
  local -a pairs=()
  if is_debian_family; then
    pairs=(
      "htop:htop" "iotop:iotop" "iftop:iftop" "sar:sysstat" "lsof:lsof"
      "tcpdump:tcpdump" "nc:netcat-openbsd" "nmap:nmap" "telnet:telnet"
      "tree:tree" "@pkg:bash-completion" "rsync:rsync" "netstat:net-tools"
      "vim:vim" "wget:wget" "unzip:unzip"
    )
  else
    pairs=(
      "htop:htop" "iotop:iotop" "iftop:iftop" "sar:sysstat" "lsof:lsof"
      "tcpdump:tcpdump" "nc:nmap-ncat" "nmap:nmap" "telnet:telnet"
      "tree:tree" "@pkg:bash-completion" "rsync:rsync" "netstat:net-tools"
      "vim:vim-enhanced" "wget:wget" "unzip:unzip"
    )
  fi

  # 逐个检查，已装跳过，收集缺失项
  local -a need=()
  local p cmd pkg
  for p in "${pairs[@]}"; do
    cmd="${p%%:*}"
    pkg="${p##*:}"
    if [[ "$cmd" == "@pkg" ]]; then
      pkg__is_installed "$pkg" && continue
      echo "  缺失: ${pkg}（bash 补全组件）"
    else
      command -v "$cmd" >/dev/null 2>&1 && continue
      echo "  缺失: ${pkg}（命令 ${cmd} 不可用）"
    fi
    need+=("$pkg")
  done

  if (( ${#need[@]} == 0 )); then
    mark_ok "常用运维工具集已全部安装"
    return 0
  fi

  echo ""
  log "开始安装 ${#need[@]} 个缺失工具: ${need[*]}"
  if ! pkg_install "${need[@]}"; then
    warn "部分软件包安装失败（可能是网络/源/EPEL 问题），继续核对状态..."
  fi

  # 装完逐项核对
  echo ""
  section "安装结果核对"
  local ok=0 bad=0
  for p in "${pairs[@]}"; do
    cmd="${p%%:*}"
    pkg="${p##*:}"
    if [[ "$cmd" == "@pkg" ]]; then
      if pkg__is_installed "$pkg"; then
        mark_ok "${pkg}"
        ok=$((ok + 1))
      else
        mark_bad "${pkg} 未安装成功"
        bad=$((bad + 1))
      fi
    else
      if command -v "$cmd" >/dev/null 2>&1; then
        mark_ok "${pkg}（命令 ${cmd} 可用）"
        ok=$((ok + 1))
      else
        mark_bad "${pkg} 未安装成功（命令 ${cmd} 不可用）"
        bad=$((bad + 1))
      fi
    fi
  done
  echo ""
  print_kv "可用" "${ok} 项"
  print_kv "失败" "${bad} 项"
  if (( bad == 0 )); then
    mark_ok "工具集安装完成"
  else
    mark_bad "有 ${bad} 项未装上，请查看上方日志"
  fi
  (( bad == 0 ))
}

# ---------- list ----------

pkg__list() {
  detect_os
  local n="${1:-20}"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n == 0 )); then
    err "数量需为正整数: ${n}"
    return 1
  fi

  section "最近安装的软件包（前 ${n} 个）"
  if is_redhat_family; then
    # rpm -qa --last 按安装时间倒序，最新在最上
    rpm -qa --last | head -n "$n"
  else
    if [[ -r /var/log/dpkg.log ]]; then
      # dpkg.log 按时间追加、最新在末尾，取尾部展示（最新在最上）
      echo "  （格式: 日期 时间 包名）"
      grep " install " /var/log/dpkg.log | tail -n "$n" | awk '{printf "  %s %s  %s\n", $1, $2, $4}'
    else
      err "无法读取 /var/log/dpkg.log（可能已被轮转，可查看 /var/log/dpkg.log.*）"
      return 1
    fi
  fi
}

# ---------- clean ----------

pkg__clean() {
  require_root
  detect_os
  section "包管理缓存清理"

  if is_debian_family; then
    local cache="/var/cache/apt/archives"
    print_kv "缓存目录" "${cache}（已下载的 .deb 安装包副本）"
    if [[ -d "$cache" ]]; then
      print_kv "当前占用" "$(du -sh "$cache" 2>/dev/null | awk '{print $1}')"
    fi
    if ! confirm "确认执行 apt-get clean 清理缓存"; then
      log "已取消"
      return 0
    fi
    apt-get clean
    if [[ -d "$cache" ]]; then
      print_kv "清理后占用" "$(du -sh "$cache" 2>/dev/null | awk '{print $1}')"
    fi
    mark_ok "apt 包缓存已清理（不影响已安装软件，仅删除安装包副本）"
  else
    local cache="/var/cache/yum"
    print_kv "缓存目录" "${cache}（包副本 + 仓库元数据）"
    if [[ -d "$cache" ]]; then
      print_kv "当前占用" "$(du -sh "$cache" 2>/dev/null | awk '{print $1}')"
    fi
    if ! confirm "确认执行 yum clean all"; then
      log "已取消"
      return 0
    fi
    if yum clean all 2>&1 | tail -n 3; then
      if [[ -d "$cache" ]]; then
        print_kv "清理后占用" "$(du -sh "$cache" 2>/dev/null | awk '{print $1}')"
      fi
      mark_ok "yum 缓存已清理（下次安装/查询将重新下载元数据）"
    else
      mark_bad "yum clean all 执行失败"
      return 1
    fi
  fi
}

# ---------- 动作分发 ----------

mod_pkg_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_pkg_help; return 1; }
  shift || true

  case "$action" in
    mirror) pkg__mirror ;;
    tools)  pkg__tools ;;
    list)   pkg__list "$@" ;;
    clean)  pkg__clean ;;
    *)
      err "未知动作: pkg ${action}"
      mod_pkg_help
      return 1
      ;;
  esac
}

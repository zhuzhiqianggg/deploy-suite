#!/usr/bin/env bash
# ==============================================================================
# lops 模块: init — 系统初始化
# ==============================================================================

# 可配置项（执行前可通过环境变量覆盖，见 mod_init_help）
LOPS_INIT_TIMEZONE="${LOPS_INIT_TIMEZONE:-Asia/Shanghai}"
LOPS_INIT_LOCALE="${LOPS_INIT_LOCALE:-zh_CN.UTF-8}"
LOPS_INIT_USER="${LOPS_INIT_USER:-zhuzhiqiang}"
LOPS_INIT_USER_PASSWORD="${LOPS_INIT_USER_PASSWORD:-Lianantech@2023}"
LOPS_INIT_SSH_PORT="${LOPS_INIT_SSH_PORT:-22}"
LOPS_INIT_ENABLE_DOCKER="${LOPS_INIT_ENABLE_DOCKER:-true}"
LOPS_INIT_UNATTENDED_MODE="${LOPS_INIT_UNATTENDED_MODE:-disable}"
LOPS_INIT_ENABLE_NODE_EXPORTER="${LOPS_INIT_ENABLE_NODE_EXPORTER:-true}"
LOPS_INIT_ENABLE_DISK_MONITOR="${LOPS_INIT_ENABLE_DISK_MONITOR:-auto}"

mod_init_desc() {
  echo "系统初始化（时区/NTP/中文环境/资源限制/审计/管理用户）"
}

mod_init_actions() {
  cat <<'EOF'
all|一键初始化（按序执行下列全部步骤，可按需开关）
pkg|安装基础软件包（curl/vim/htop/iotop/rsync/jq 等常用工具）
time|配置时区 + chrony 时间同步（阿里云/腾讯 NTP 源）
locale|配置中文 locale 环境
profile|配置全局 shell 环境（别名/HISTSIZE/EDITOR/umask + 危险命令二次确认）
user|创建 dev 分组 + 运维用户（dev 组持有 sudo 免密；用户默认 zhuzhiqiang，初始密码可用环境变量覆盖）
limits|配置 ulimit 资源限制 + 内核参数（sysctl，含内存水位保底防整机卡死）
history|配置全用户命令审计（按用户/日期落盘 /opt/backup/history）
unattended|加固无人值守自动升级（黑名单 systemd，防 daemon-reexec 批量重启业务）
rescue|救援通道保障（sshd OOM 保护/自动拉起；刻意不做 panic 自动重启）
logrotate|日志治理（lops 日志轮转 + journald 持久化与防膨胀）
EOF
}

mod_init_help() {
  cat <<EOF
lops init — 系统初始化
==============================================================================
新服务器标准化初始化，也支持对已运行服务器单独执行某一步骤。
所有步骤幂等：重复执行不会破坏已有配置（修改系统文件前自动备份）。

用法:
  ./lops.sh init <action>

动作说明:
  all       一键初始化。按序执行 pkg → time → locale → profile → user
            → limits → history → unattended → rescue → logrotate，
            并根据开关调用 ssh/docker/monitor 模块。
            适合新装服务器，装完即达到生产基线。
  pkg       安装基础软件包: ca-certificates curl wget rsync git vim jq htop
            iotop iftop tree lsof sysstat acl bash-completion net-tools 等。
  time      时区设为 Asia/Shanghai，安装并配置 chrony
            （NTP 源: ntp.aliyun.com + 腾讯云 time1/time2）。
  locale    生成并启用 zh_CN.UTF-8 中文环境。
  profile   写入 /etc/profile.d/zz-ops-base.sh: 中文 locale、TZ、vim 编辑器、
            history 容量、常用别名（ll/lla/dfh 等）。
            另写入 zz-ops-safe.sh 危险命令二次确认（仅交互式 shell，
            脚本/cron 不受影响）: rm -r 递归删目录、reboot/poweroff/halt、
            shutdown now、mkfs、dd 写块设备弹彩色确认框（输 yes 执行 /
            输 no 取消，其余输入一律取消）；绕过: command rm、
            /bin/rm、OPS_SAFETY=0（注意 \rm 只跳过 alias 不跳过函数）。
            单文件删除不拦。
  user      创建 dev 分组与运维管理用户（默认 zhuzhiqiang，初始密码
            LOPS_INIT_USER_PASSWORD，仅新建时设置不覆盖已改密码），
            用户加入 dev 组；sudo 免密按 %dev 组授权（后续新成员
            加入 dev 组即自动拥有免密 sudo），写入前 visudo 校验。
            dev 组全体成员自动追加 docker 组（幂等；Docker 未装时
            在 docker install 完成后同步）；检测到旧版残留 ops 用户
            时提示人工清理。
  limits    写入 /etc/security/limits.d/99-ops.conf（nofile/nproc 65535）
            与 /etc/sysctl.d/99-ops.conf（网络/内存/文件句柄调优）。
            含内存水位防线（防内存耗尽导致整机卡死）:
            vm.min_free_kbytes 按总内存 2% 动态计算（上限 1GB 下限 128MB），
            vm.watermark_scale_factor=100 让 kswapd 提前后台回收。
            原理: OOM 可恢复、卡死无从入手，保底空闲内存保证系统始终可操作。
            同时禁用登录会话 core dump（* soft/hard core 0，防进程反复 crash
            产生超大 core 撑爆磁盘；systemd 服务由 LimitCORE= 独立控制不受影响）。
  history   命令审计: /opt/backup/history 父目录 1777（sticky），用户首次登录
            自动自建自己的 0700 审计目录（root init 时也会为现有 bash 用户
            预建并修复归属，幂等），写入 /etc/profile.d/zz-ops-history.sh
            按天记录命令（时间戳/来源目录）。目录不可用或属主异常时静默
            降级为默认 ~/.bash_history，登录与每条命令零报错；脚本可重复
            source（幂等）。
  unattended 加固 Ubuntu/Debian 的 unattended-upgrades，防止 apt-daily-upgrade
            凌晨自动升级触发 daemon-reexec，把 systemd 托管的业务服务（数据库/
            中间件）批量重启（真实事故: Doris BE 5 节点凌晨批量重启，根因是
            util-linux/coreutils/libssh/zlib 底层库更新触发 APT 钩子，并非
            systemd 包本身）。
            默认 disable 模式（生产推荐）: 停 apt timer + 置 0 自动升级开关，
            补丁统一走维护窗口手动执行（先 --dry-run 预览）。
            LOPS_INIT_UNATTENDED_MODE=blacklist 为黑名单模式（不能完全防住，
            触发 reexec 的底层包无法穷举）。
            RHEL 系检查 dnf-automatic.timer，运行中则告警。
            第二道闸（两种模式都做）: needrestart 策略改为只列出不自动重启
            （needrestart 是升级后批量重启使用旧库服务的直接执行者）。
  rescue    救援通道保障（保证"人始终能登录上来判断"，不做自动重启）:
            sshd OOM 保护与自动拉起（drop-in: OOMScoreAdjust=-1000 +
            Restart=on-failure）——sshd 常驻内存仅几十 MB，保护成本极低；
            OOM 风暴时 sshd 存活 = 仍可登录救火，不再"内存恢复却进不来"。
            drop-in 在下次 sshd 重启后完全生效，脚本不自动 restart。
            刻意不设 kernel.panic 自动重启（2026-09-08 决策）: panic 场景
            无法程序化判断该不该重启，盲目自动重启有放弃现场/二次损坏/
            重启风暴风险，必须人工确认；机器可操作性由内存水位防线与
            带外通道保障。全景清单见 guides/38-Linux整机级故障防线清单.md。
  logrotate 日志治理: lops 自身日志每周轮转（保留 8 份压缩）+ journald
            治理（Storage=persistent 持久化重启不丢取证日志、
            SystemMaxUse=1G 与 30 天保留上限防 /var/log 被撑爆）。

可配置环境变量（执行前 export 覆盖默认值）:
  LOPS_INIT_TIMEZONE=Asia/Shanghai        # 时区
  LOPS_INIT_LOCALE=zh_CN.UTF-8            # locale
  LOPS_INIT_USER=zhuzhiqiang              # 管理用户名
  LOPS_INIT_USER_PASSWORD=Lianantech@2023 # 用户初始密码（仅新建时设置，不覆盖已改密码）
  LOPS_INIT_UNATTENDED_MODE=disable       # unattended 模式: disable(生产推荐)/blacklist
  LOPS_INIT_ENABLE_DOCKER=true            # all 时是否安装 Docker
  LOPS_INIT_ENABLE_NODE_EXPORTER=true     # all 时是否安装 node_exporter
  LOPS_INIT_ENABLE_DISK_MONITOR=auto      # 磁盘健康监控: auto(默认,自动判断仅物理机装)/true(强制)/false(禁用)

示例:
  ./lops.sh init all                                  # 新机一键初始化
  ./lops.sh init time                                 # 只配置时间同步
  ./lops.sh init unattended                           # 已有服务器单独补防自动升级加固
  LOPS_INIT_USER=admin ./lops.sh init user            # 创建 admin 管理用户
  LOPS_INIT_UNATTENDED_MODE=blacklist ./lops.sh init unattended  # 仅黑名单模式（不推荐数据库节点）
  LOPS_INIT_ENABLE_DOCKER=false ./lops.sh init all    # 初始化但不装 Docker

前置条件:
  - root 权限（所有动作都会写系统配置）
  - 可访问软件源（pkg/all 需要；离线环境请先自行配置本地源）

注意事项:
  - all 会调用 ssh 模块加固 SSH（端口 ${LOPS_INIT_SSH_PORT}，保持密码登录），
    如当前通过 SSH 连接，执行完成后建议保持会话并新开终端验证再退出。
  - 修改过的系统文件自动备份为 *.bak.<时间戳>，出问题可回滚。
EOF
}

# ---------- 动作实现 ----------

init__pkg() {
  require_root
  section "安装基础软件包"
  if is_debian_family; then
    pkg_install ca-certificates curl wget gnupg rsync git vim unzip zip jq \
      htop iotop iftop tree lsof sysstat acl sudo bash-completion cron \
      iproute2 net-tools iputils-ping chrony smartmontools
  else
    pkg_install epel-release curl wget rsync git vim unzip zip jq \
      htop iotop iftop tree lsof sysstat acl sudo bash-completion cronie \
      iproute net-tools iputils chrony smartmontools
  fi
  log "基础软件包安装完成"
}

init__time() {
  require_root
  section "配置时区与时间同步"
  ln -snf "/usr/share/zoneinfo/${LOPS_INIT_TIMEZONE}" /etc/localtime
  echo "${LOPS_INIT_TIMEZONE}" > /etc/timezone 2>/dev/null || true
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "${LOPS_INIT_TIMEZONE}" || true
  fi

  pkg_install chrony >/dev/null 2>&1 || true
  if is_debian_family; then
    local chrony_conf="/etc/chrony/chrony.conf"
  else
    local chrony_conf="/etc/chrony.conf"
  fi
  if [[ -f "$chrony_conf" ]]; then
    backup_file "$chrony_conf"
    cat > "$chrony_conf" <<EOF
# 由 lops init time 生成
server ntp.aliyun.com iburst
server time1.cloud.tencent.com iburst
server time2.cloud.tencent.com iburst
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/drift
logdir /var/log/chrony
EOF
  fi
  systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony || true
  sleep 2
  if command -v chronyc >/dev/null 2>&1; then
    chronyc tracking | head -n 8
  fi
  log "时间同步配置完成"
}

init__locale() {
  require_root
  section "配置中文 locale"
  if is_debian_family; then
    pkg_install language-pack-zh-hans locales >/dev/null 2>&1 || true
  else
    pkg_install glibc-langpack-zh >/dev/null 2>&1 || true
  fi
  if ! locale -a 2>/dev/null | grep -qi "${LOPS_INIT_LOCALE}"; then
    locale-gen "${LOPS_INIT_LOCALE}" 2>/dev/null || true
  fi
  if command -v update-locale >/dev/null 2>&1; then
    update-locale LANG="${LOPS_INIT_LOCALE}" LC_ALL="${LOPS_INIT_LOCALE}"
  else
    backup_file /etc/locale.conf
    echo "LANG=${LOPS_INIT_LOCALE}" > /etc/locale.conf
  fi
  log "locale 配置完成（重新登录后生效）"
}

init__profile() {
  require_root
  section "配置全局 shell 环境"
  mkdir -p /etc/profile.d
  cat > /etc/profile.d/zz-ops-base.sh <<EOF
# 由 lops init profile 生成
export LANG=${LOPS_INIT_LOCALE}
export TZ=${LOPS_INIT_TIMEZONE}
export EDITOR=vim
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTTIMEFORMAT='%F %T '
shopt -s histappend
umask 022
alias ll='ls -lh'
alias la='ls -A'
alias lla='ls -lah'
alias grep='grep --color=auto'
alias dfh='df -h'
alias free='free -h'
EOF
  chmod 0644 /etc/profile.d/zz-ops-base.sh
  log "shell 环境配置完成（/etc/profile.d/zz-ops-base.sh）"

  # 危险命令二次确认（独立文件，便于单独禁用: rm /etc/profile.d/zz-ops-safe.sh）
  cat > /etc/profile.d/zz-ops-safe.sh <<'SAFE_EOF'
# 危险命令二次确认 —— 由 lops init profile 生成
# 原理：函数包装覆盖命令，仅对"人"生效；自动化脚本/cron/CI 走绝对路径不受影响
# 生效条件：交互式 shell（$- 含 i）
# 绕过方式（按需删除/临时用）：
#   command rm -rf dir     # 调真实命令（一次性；注意 \rm 只跳过 alias 不跳过函数！）
#   /bin/rm -rf dir        # 绝对路径同理
#   OPS_SAFETY=0           # 会话内全局关闭
#   rm /etc/profile.d/zz-ops-safe.sh && 重新登录   # 彻底卸载
if [[ $- == *i* && "${OPS_SAFETY:-1}" != "0" ]]; then

# 颜色仅在 stderr 为终端时启用（重定向/日志文件里不混入转义码）
if [[ -t 2 ]]; then
  OPS_B=$'\e[1m' OPS_RED=$'\e[1;31m' OPS_YEL=$'\e[33m' OPS_GRN=$'\e[1;32m' OPS_DIM=$'\e[2m' OPS_RST=$'\e[0m'
else
  OPS_B='' OPS_RED='' OPS_YEL='' OPS_GRN='' OPS_DIM='' OPS_RST=''
fi

# 统一确认框：只认 yes（其余任何输入一律取消，fail-closed）
ops_safe_confirm() {
  local ans
  echo "" >&2
  echo "  ${OPS_RED}${OPS_B}⚠ 高危操作${OPS_RST}: ${OPS_YEL}$1${OPS_RST}" >&2
  echo "  ${OPS_DIM}----------------------------------------------------------${OPS_RST}" >&2
  read -r -p "  输入 ${OPS_GRN}${OPS_B}yes${OPS_RST} 执行 / 输入 ${OPS_RED}${OPS_B}no${OPS_RST} 取消: " ans
  if [[ "$ans" == "yes" ]]; then
    return 0
  fi
  echo "  ${OPS_DIM}✗ 已取消（未输入 yes，未执行任何操作）${OPS_RST}" >&2
  return 1
}

# ---- rm: 仅拦"递归删除目录"；单文件删除不拦 ----
rm() {
  local -a paths=()
  local recursive=0 end_opts=0 a i c
  for a in "$@"; do
    if (( end_opts )); then
      paths+=("$a")
      continue
    fi
    case "$a" in
      --) end_opts=1 ;;
      --recursive) recursive=1 ;;
      -[a-zA-Z]*)
        for ((i = 1; i < ${#a}; i++)); do
          c=${a:i:1}
          [[ "$c" == r || "$c" == R ]] && recursive=1
        done ;;
      -*) ;;
      *) paths+=("$a") ;;
    esac
  done
  if (( recursive )); then
    local p size
    for p in "${paths[@]}"; do
      if [[ -d "$p" ]]; then
        size="$(du -sh "$p" 2>/dev/null | awk '{print $1}')"
        echo "  ${OPS_YEL}即将递归删除目录${OPS_RST}: ${OPS_B}$p${OPS_RST} (大小 ${size:-?}) ${OPS_RED}[目录内容将不可恢复]${OPS_RST}" >&2
        if ! ops_safe_confirm "rm -r ${p}"; then
          return 1
        fi
      fi
    done
  fi
  command rm "$@"
}

# ---- 关机/重启类: 全部确认（shutdown 带分钟数的可 cancel，不拦）----
reboot()   { ops_safe_confirm "重启系统（所有服务将中断）" && command reboot "$@"; }
poweroff() { ops_safe_confirm "关闭系统（所有服务将中断）" && command poweroff "$@"; }
halt()     { ops_safe_confirm "停机（所有服务将中断）" && command halt "$@"; }
shutdown() {
  case " $* " in
    *" now "*)
      ops_safe_confirm "shutdown 立即停机/重启" && command shutdown "$@" ;;
    *)
      command shutdown "$@" ;;
  esac
}

# ---- mkfs 系列: 格式化必须确认 ----
mkfs()       { ops_safe_confirm "格式化文件系统: mkfs $*" && command mkfs "$@"; }
mkfs.ext2()  { ops_safe_confirm "格式化 ext2: mkfs.ext2 $*" && command mkfs.ext2 "$@"; }
mkfs.ext4()  { ops_safe_confirm "格式化 ext4: mkfs.ext4 $*" && command mkfs.ext4 "$@"; }
mkfs.xfs()   { ops_safe_confirm "格式化 xfs: mkfs.xfs $*" && command mkfs.xfs "$@"; }

# ---- dd: 输出目标是块设备时确认（写错 of= 直接毁盘）----
dd() {
  local a
  for a in "$@"; do
    if [[ "$a" == of=/dev/* && "$a" != of=/dev/null* ]]; then
      echo "  ${OPS_YEL}即将向块设备写入${OPS_RST}: ${OPS_B}${a#of=}${OPS_RST} ${OPS_RED}[设备原有数据将被覆盖]${OPS_RST}" >&2
      if ! ops_safe_confirm "dd ${a}"; then
        return 1
      fi
      break
    fi
  done
  command dd "$@"
}

fi
SAFE_EOF
  chmod 0644 /etc/profile.d/zz-ops-safe.sh
  log "危险命令二次确认已配置（/etc/profile.d/zz-ops-safe.sh，重新登录生效）"
}

init__user() {
  require_root
  section "创建 dev 分组与运维用户: ${LOPS_INIT_USER}"

  # dev 分组: 运维/开发人员统一入口组，sudo 免密按组授权（新成员加入 dev 组即有权限）
  if ! getent group dev >/dev/null 2>&1; then
    groupadd dev
    log "dev 分组已创建"
  else
    log "dev 分组已存在，跳过创建"
  fi

  if ! id "${LOPS_INIT_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G dev "${LOPS_INIT_USER}"
    # 初始密码仅创建时设置一次: 重跑不覆盖用户自行修改的密码（幂等安全）
    echo "${LOPS_INIT_USER}:${LOPS_INIT_USER_PASSWORD}" | chpasswd
    log "用户 ${LOPS_INIT_USER} 已创建（加入 dev 组）并设置初始密码"
  else
    id "${LOPS_INIT_USER}" | grep -qw dev || usermod -aG dev "${LOPS_INIT_USER}"
    log "用户 ${LOPS_INIT_USER} 已存在，跳过创建与密码重置（已确保在 dev 组）"
  fi

  # sudo 免密按 %dev 组授权（替代旧的单用户授权，跨发行版统一）
  cat > /etc/sudoers.d/90-lops-dev <<'EOF'
# dev 组全员免密 sudo
%dev ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 0440 /etc/sudoers.d/90-lops-dev
  if command -v visudo >/dev/null 2>&1; then
    visudo -cf /etc/sudoers.d/90-lops-dev >/dev/null 2>&1 \
      || die "sudoers 校验失败，请检查 /etc/sudoers.d/90-lops-dev"
  fi
  log "sudo 免密已按 %dev 组授权"

  # 旧版残留检测: 早期版本曾默认创建 ops 用户，新版默认 ${LOPS_INIT_USER}——删除属高危动作，不自动删，提示人工确认
  if id ops >/dev/null 2>&1; then
    warn "检测到旧版残留的 ops 用户（当前默认用户为 ${LOPS_INIT_USER}）"
    warn "确认无业务依赖后手动清理: sudo userdel -r ops；并检查 crontab -l / systemd 单元中 ops 的残留任务"
  fi

  # dev 组全体成员统一追加 docker 组（幂等；Docker 未装时由 docker install 完成后自动同步）
  if declare -F docker__sync_dev_group >/dev/null 2>&1; then
    docker__sync_dev_group
  fi
}

# 判断是否物理机: 0=确认物理机; 非 0=虚拟机或无法确认（按不自动安装处理，宁可漏装不误装）
init__is_physical() {
  # 1) systemd-detect-virt: systemd 机器标配，最可靠（物理机输出 none）
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local v
    v="$(systemd-detect-virt 2>/dev/null || true)"
    if [[ "$v" == "none" ]]; then
      return 0
    elif [[ -n "$v" && "$v" != "unknown" ]]; then
      return 1
    fi
  fi
  # 2) DMI 信息降级判断（/sys/class/dmi/id 普通用户可读）
  if [[ -r /sys/class/dmi/id/sys_vendor ]]; then
    local vendor product
    vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
    product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    case "${vendor} ${product}" in
      *QEMU*|*KVM*|*VMware*|*VirtualBox*|*Xen*|*Bochs*|*BHYVE*|*innotek*|*Microsoft\ Corporation*)
        return 1 ;;
    esac
    if [[ -n "$vendor" ]]; then
      return 0
    fi
  fi
  # 3) 两级都判断不了: 视为不确定，不自动安装
  return 1
}

init__limits() {
  require_root
  section "配置资源限制与内核参数"
  cat > /etc/security/limits.d/99-ops.conf <<'EOF'
# 由 lops init limits 生成
* soft nofile 65535
* hard nofile 65535
* soft nproc  65535
* hard nproc  65535
# 禁用登录会话 core dump: 防进程反复 crash 产生超大 core 文件撑爆磁盘（二次故障）
# systemd 服务的 core 由单元参数 LimitCORE= 独立控制，不受本限制影响
* soft core 0
* hard core 0
EOF
  # 内存水位防线（防内存耗尽导致整机卡死，原理见 guides/37-Linux内存水位防线与防卡死.md）:
  #   vm.min_free_kbytes 按总内存 2% 动态计算，上限 1GB、下限 128MB（不超过总内存 1%~2%）。
  #   作用: 强制内核保留空闲内存 + kswapd 提前后台回收，保证系统永不进入同步回收卡死。
  local mem_total_kb min_free_kbytes
  mem_total_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
  min_free_kbytes="$(awk -v t="${mem_total_kb:-0}" 'BEGIN{r=int(t*0.02); if(r<131072)r=131072; if(r>1048576)r=1048576; print r}')"
  cat > /etc/sysctl.d/99-ops.conf <<EOF
# 由 lops init limits 生成
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syn_retries = 5
net.ipv4.tcp_synack_retries = 2
net.ipv4.ip_local_port_range = 10000 65000
vm.swappiness = 10
vm.max_map_count = 262144
fs.file-max = 1048576
# inotify（大量容器/Go 程序 fsnotify 场景，默认 128 实例会被耗尽，
# 表现为 kubelet/minio 等报 "failed to create fsnotify watcher: too many open files"）
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
kernel.pid_max = 4194304
# 内存水位防线（防内存耗尽导致整机卡死）
vm.min_free_kbytes = ${min_free_kbytes}
vm.watermark_scale_factor = 100
EOF
  sysctl --system >/dev/null 2>&1 || true
  log "limits 与 sysctl 配置完成（nofile/nproc 65535，内存保底水位 ${min_free_kbytes}KB，重新登录生效）"
}

init__history() {
  require_root
  section "配置命令历史审计"
  mkdir -p /opt/backup/history
  # 1777(sticky): 任何用户可自建自己的审计子目录（新用户首次登录自动建，无需重跑本动作），sticky 防互删
  chmod 1777 /opt/backup/history
  # 同时为现有 bash 用户预建（幂等，顺带修复归属/权限错乱的旧目录）
  local u uid gid home shell d
  while IFS=: read -r u _ uid gid _ home shell; do
    [[ "$shell" == */bash && -d "$home" ]] || continue
    d="/opt/backup/history/$u"
    [[ -d "$d" ]] || mkdir -m 0700 "$d"
    chown "$u:$gid" "$d" 2>/dev/null
    chmod 0700 "$d" 2>/dev/null
  done < /etc/passwd
  cat > /etc/profile.d/zz-ops-history.sh <<'EOF'
# 由 lops init history 生成：全用户命令按天落盘审计
# 设计要点：
#   父目录 1777(sticky)——用户首次登录自建自己的 0700 审计目录（全自动）；
#   root 侧 init 也会为现有 bash 用户预建（幂等）。
#   三重检查: 目录存在 + 可写 + 属主是自己(-O，防目录被他人抢占导致命令泄露)，
#   任一不满足静默降级为默认 ~/.bash_history——登录与每条命令零报错。
#   本文件可重复 source（幂等）。
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTTIMEFORMAT='%F %T '
shopt -s histappend
shopt -s cmdhist
__ops_audit_dir="/opt/backup/history/${USER:-$(id -un 2>/dev/null)}"
if [ -n "$__ops_audit_dir" ]; then
  [ -d "$__ops_audit_dir" ] || mkdir -m 0700 "$__ops_audit_dir" 2>/dev/null
  __ops_audit_file="$__ops_audit_dir/history_$(date +%F).log"
  if [ -d "$__ops_audit_dir" ] && [ -w "$__ops_audit_dir" ] && [ -O "$__ops_audit_dir" ]; then
    touch "$__ops_audit_file" 2>/dev/null
    chmod 0600 "$__ops_audit_file" 2>/dev/null
    if [ -w "$__ops_audit_file" ] && [ -O "$__ops_audit_file" ]; then
      export HISTORY_FILE="$__ops_audit_file"
      export PROMPT_COMMAND='echo "$(date +"%F %T") user=${USER} cwd=$(pwd) cmd=$(history 1 | sed "s/^ *[0-9]\+  *//")" >> "${HISTORY_FILE}"'
    fi
  fi
fi
unset __ops_audit_dir __ops_audit_file
EOF
  chmod 0644 /etc/profile.d/zz-ops-history.sh
  log "命令审计配置完成（已为现有 bash 用户预建审计目录；父目录 1777 支持新用户登录自建；异常时静默降级零报错）"
}

init__unattended() {
  require_root
  section "加固无人值守自动升级（防 daemon-reexec 批量重启业务）"

  if is_debian_family; then
    if [[ "${LOPS_INIT_UNATTENDED_MODE}" == "blacklist" ]]; then
      # 黑名单模式（可选，不能完全防住）: 只拉黑 systemd 家族 + 常见底层库。
      # 注意: 生产事故已证明 util-linux/coreutils/libssh/zlib 等底层库更新
      # 同样触发 APT 钩子调用 daemon-reexec，黑名单无法穷举全部触发包，
      # 数据库/中间件节点推荐 disable 模式（本脚本默认）。
      local bl="/etc/apt/apt.conf.d/52unattended-upgrades-local"
      [[ -f "$bl" ]] && backup_file "$bl"
      cat > "$bl" <<'EOF'
// 由 lops init unattended 生成（blacklist 模式）
// 黑名单: systemd 家族 + 常见触发 daemon-reexec 的底层库。
// 局限: 触发 reexec 的不止这些包（任何替换 PID1 已加载 so 库的更新都可能触发），
//   无法穷举，生产数据库/中间件节点建议改用 disable 模式。
// 注意: 指令名必须是 Package-Blacklist；写成 AutoUpdate-Blacklist 是无效指令，
//   会被 apt 静默忽略（等于没配置）。
Unattended-Upgrade::Package-Blacklist {
    "systemd";
    "systemd-.*";
    "libsystemd.*";
    "util-linux";
    "util-linux-.*";
    "libuuid1";
    "coreutils";
    "zlib1g";
    "libssh";
    "libssh-.*";
    "glibc";
    "libc6";
    "libssl.";
    "openssh";
};
EOF
      # 生效验证
      if command -v apt-config >/dev/null 2>&1; then
        if apt-config dump 2>/dev/null | grep 'Unattended-Upgrade::Package-Blacklist' | grep -q 'systemd'; then
          log "黑名单已写入并生效: ${bl}"
          warn "黑名单模式无法完全防住 daemon-reexec（触发包无法穷举），数据库节点建议 disable 模式"
        else
          warn "apt-config 输出中未见 systemd 黑名单，请人工检查 ${bl}"
        fi
      fi
    else
      # disable 模式（默认，生产推荐）: 停 timer + APT::Periodic 置 0。
      # 原因: util-linux/coreutils/libssh/zlib 等底层库更新触发 APT 钩子
      #   daemon-reexec，黑名单无法穷举，只能整体关闭，补丁走维护窗口手动执行。
      systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
      local auto_conf="/etc/apt/apt.conf.d/20auto-upgrades"
      [[ -f "$auto_conf" ]] && backup_file "$auto_conf"
      cat > "$auto_conf" <<'EOF'
// 由 lops init unattended 生成：完全关闭自动升级（生产数据库/中间件节点基线）
// 原因: 底层库(util-linux/coreutils/libssh/zlib 等)自动更新会触发 APT 钩子
//   daemon-reexec，systemd 托管的服务全部批量重启（机器不重启，极难感知）。
// 补丁规范: 维护窗口手动执行，先 --dry-run 预览，含底层包则分批滚动升级。
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
      # 验证 timer 已停
      local t1 t2
      t1="$(systemctl is-enabled apt-daily.timer 2>/dev/null || true)"
      t2="$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true)"
      if [[ "$t1" == "enabled" || "$t2" == "enabled" ]]; then
        warn "apt timer 仍为 enabled，请人工检查 systemctl list-timers apt-*"
      else
        log "已完全关闭无人值守升级（apt-daily / apt-daily-upgrade timer 已停）"
      fi
      warn "注意: 安全补丁不再自动安装，需在维护窗口人工执行（先 --dry-run 预览）"
    fi

    # ---- 第二道闸: needrestart 服务自动重启策略（无论上面哪种模式都配置）----
    # needrestart 在 apt 升级后会自动重启"使用了被替换 so 库"的服务进程
    # （doris-be 映射了 util-linux/zlib 等库，升级即被重启——批量重启的直接执行者之一）。
    # 默认交互模式在非交互/生产脚本场景下等同于自动重启，必须改为只列出不重启。
    if command -v needrestart >/dev/null 2>&1 || [[ -d /etc/needrestart ]]; then
      local nr_conf="/etc/needrestart/conf.d/99-lops.conf"
      mkdir -p /etc/needrestart/conf.d
      cat > "$nr_conf" <<'EOF'
# 由 lops init unattended 生成
# restart 策略改为只列出不重启: apt 升级后需要重启的服务由运维
# 在维护窗口评估后手动处理，防止业务服务被批量自动重启。
$nrconf{restart} = 'l';
EOF
      log "needrestart 策略已改为只列出不重启: ${nr_conf}"
      warn "提示: 升级底层库后 needrestart 会列出需重启的服务清单，由运维评估后手动重启"
    else
      log "未安装 needrestart，跳过（Ubuntu 22.04+ 默认自带）"
    fi
  else
    # RHEL 系: dnf-automatic 默认未启用，运行中才有风险
    if systemctl is-active dnf-automatic.timer >/dev/null 2>&1; then
      warn "dnf-automatic.timer 运行中: 自动升级底层库同样会触发 daemon-reexec"
      warn "建议停用（systemctl disable --now dnf-automatic.timer），补丁走维护窗口"
    else
      log "RHEL 系 dnf-automatic 未启用，无自动升级风险"
    fi
  fi
}

init__rescue() {
  require_root
  section "配置救援通道保障（sshd OOM 保护）"
  # 设计决策（2026-09-08 用户评审）: 刻意不做 kernel.panic 自动重启——
  # panic 场景无法程序化判断该不该重启，盲目自动重启有放弃现场/二次损坏/
  # 重启风暴风险，必须人工确认；机器"能被操作"由内存水位防线（limits）
  # 与带外通道保障，本动作只保证"人始终能登录上来判断"。

  # sshd OOM 保护与自动拉起: sshd 常驻内存仅几十 MB，保护成本极低；
  # OOM 风暴时 sshd 存活 = 仍可登录救火（呼应"卡死时无从入手"）。
  local unit
  unit="$(systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -xE 'sshd.service|ssh.service' | head -n 1 || true)"
  if [[ -n "$unit" ]]; then
    mkdir -p "/etc/systemd/system/${unit}.d"
    cat > "/etc/systemd/system/${unit}.d/99-ops-rescue.conf" <<'EOF'
# 由 lops init rescue 生成
[Service]
# OOM 时保住 sshd: 内存紧张时仍可登录处置（sshd 占用小，保护代价可忽略）
OOMScoreAdjust=-1000
# sshd 异常退出自动拉起，不依赖人工
Restart=on-failure
RestartSec=5s
EOF
    systemctl daemon-reload
    log "sshd OOM 保护与自动拉起已配置（drop-in: /etc/systemd/system/${unit}.d/99-ops-rescue.conf）"
    warn "drop-in 在下次 sshd 重启后完全生效；当前会话不受影响，可择机执行: systemctl restart ${unit}"
  else
    warn "未识别 sshd/ssh unit（可能未安装 openssh-server），跳过 OOM 保护配置"
  fi
}

init__logrotate() {
  require_root
  section "配置日志治理（lops 轮转 + journald 防膨胀）"
  if ! command -v logrotate >/dev/null 2>&1; then
    pkg_install logrotate
  fi
  cat > /etc/logrotate.d/lops <<'EOF'
# 由 lops init logrotate 生成
/var/log/lops/lops.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    dateext
}
EOF
  # journald 治理: 持久化（重启不丢日志，OOM/panic 取证依赖历史日志）
  # + 容量与保留时长上限（防 journal 无限增长撑爆 /var/log）
  mkdir -p /etc/systemd/journald.conf.d /var/log/journal
  cat > /etc/systemd/journald.conf.d/99-ops.conf <<'EOF'
# 由 lops init logrotate 生成
[Journal]
# 持久化: 重启不丢日志（OOM / panic 后取证依赖历史日志）
Storage=persistent
# 磁盘占用上限: 防 journal 撑爆 /var/log
SystemMaxUse=1G
# 保留时长上限
MaxRetentionSec=30day
EOF
  systemctl restart systemd-journald 2>/dev/null || true
  log "日志治理完成（lops 周轮转 8 份；journald 持久化 + 上限 1G/30 天）"
}

init__all() {
  require_root
  detect_os
  banner "lops init all — 一键初始化"
  log "开始初始化 ${LOPS_OS_ID} ${LOPS_OS_VERSION}"
  log "开关: Docker=${LOPS_INIT_ENABLE_DOCKER} node_exporter=${LOPS_INIT_ENABLE_NODE_EXPORTER} disk_monitor=${LOPS_INIT_ENABLE_DISK_MONITOR}"

  init__pkg
  init__time
  init__locale
  init__profile
  init__user
  init__limits
  init__history
  init__unattended
  init__rescue
  init__logrotate

  # 调用其他模块完成可选组件（模块均已 source，函数存在即调用）
  if declare -F mod_ssh_run >/dev/null 2>&1; then
    LOPS_SSH_PORT="${LOPS_INIT_SSH_PORT}" mod_ssh_run harden || warn "SSH 加固失败，请手动处理"
  fi
  if [[ "${LOPS_INIT_ENABLE_DOCKER}" == "true" ]] && declare -F mod_docker_run >/dev/null 2>&1; then
    mod_docker_run install || warn "Docker 安装失败，可稍后执行 ./lops.sh docker install"
  fi
  if [[ "${LOPS_INIT_ENABLE_NODE_EXPORTER}" == "true" ]] && declare -F mod_monitor_run >/dev/null 2>&1; then
    mod_monitor_run node_exporter || warn "node_exporter 安装失败"
  fi
  # disk_monitor 仅物理机需要（虚拟机磁盘故障由云平台负责，SMART 采集无意义）
  local install_disk="false"
  case "${LOPS_INIT_ENABLE_DISK_MONITOR}" in
    true)  install_disk="true" ;;
    false) install_disk="false" ;;
    auto)
      if init__is_physical; then
        install_disk="true"
        log "已确认物理机，将安装磁盘健康监控"
      else
        log "虚拟机或无法确认物理机身份，跳过磁盘健康监控（可 LOPS_INIT_ENABLE_DISK_MONITOR=true 强制安装）"
      fi
      ;;
    *) warn "LOPS_INIT_ENABLE_DISK_MONITOR 取值无效: ${LOPS_INIT_ENABLE_DISK_MONITOR}（应为 true/false/auto），跳过" ;;
  esac
  if [[ "$install_disk" == "true" ]] && declare -F mod_monitor_run >/dev/null 2>&1; then
    mod_monitor_run disk_monitor || warn "磁盘健康监控部署失败"
  fi

  section "初始化完成"
  log "建议: 重新登录使 locale/limit/history 配置生效，并新开终端验证 SSH 可登录"
}

# ---------- 动作分发 ----------
mod_init_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_init_help; return 1; }
  shift || true

  case "$action" in
    all)     init__all ;;
    pkg)     init__pkg ;;
    time)    init__time ;;
    locale)  init__locale ;;
    profile) init__profile ;;
    user)    init__user ;;
    limits)  init__limits ;;
    history) init__history ;;
    unattended) init__unattended ;;
    rescue) init__rescue ;;
    logrotate) init__logrotate ;;
    *)
      err "未知动作: init ${action}"
      mod_init_help
      return 1
      ;;
  esac
}

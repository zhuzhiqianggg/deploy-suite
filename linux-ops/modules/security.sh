#!/usr/bin/env bash
# ==============================================================================
# lops 模块: security — 安全巡检与加固
# ==============================================================================

mod_security_desc() {
  echo "安全巡检加固（安全巡检/交互加固/fail2ban 防爆破/防火墙操作）"
}

mod_security_actions() {
  cat <<'EOF'
check|安全巡检（只读：防火墙/SELinux/SSH/空口令/爆破/SUID/cron）
harden|交互式安全加固（禁root登录/空口令设密码/锁账户/密钥登录指引）
fail2ban|安装部署 fail2ban 并启用 sshd 防爆破 jail
firewall|防火墙常用操作（状态/放行端口/封禁IP/规则清单）
EOF
}

mod_security_help() {
  cat <<'EOF'
lops security — 安全巡检与加固
==============================================================================
安全三板斧: 先巡检（check 看病）→ 再加固（harden 治病）→ 最后部署
fail2ban（长期值班防爆破）。巡检只读不改配置，加固项全部可回滚。

用法:
  ./lops.sh security <action> [参数]

动作说明:
  check    安全巡检（只读，不改任何配置），逐项输出 ✓/⚠/✘，共 10 项:
             ① 防火墙    firewalld / ufw / iptables 哪个在跑（都没跑最危险）
             ② SELinux   内核强制访问控制（CentOS 系的"安全门卫"）
             ③ SSH 配置  PermitRootLogin / PasswordAuthentication / Port
             ④ 空口令账户 口令字段为空 = 不要密码就能登录，高危
             ⑤ UID=0 账户 除 root 外任何 UID=0 账户都视作后门
             ⑥ 爆破统计  最近 24h 登录失败次数与来源 IP Top5（lastb）
             ⑦ authorized_keys  各用户 SSH 密钥文件的最后变更时间
             ⑧ SUID 文件 带"临时提权"位的可执行文件数量与清单（基线）
             ⑨ cron 可写  定时任务目录/文件是否全局可写（提权后门高发区）
             ⑩ 自动升级  unattended-upgrades/dnf-automatic 是否运行（底层库自动
                        更新触发 daemon-reexec 批量重启业务，Doris 真实事故）
           结尾输出异常清单。
  harden   交互式安全加固（逐项菜单，每项操作前自动备份 + 二次确认）:
             1. 禁用 root SSH 直接登录（PermitRootLogin no）
             2. 为空口令账户生成 16 位随机密码（gen_password + chpasswd）
             3. 锁定可疑账户（usermod -L，锁定后无法登录，-U 解锁）
             4. SSH 改密钥登录指引（生成 → 上传 → 验证 → 再禁密码 四步法）
  fail2ban 安装部署 fail2ban 并启用 sshd 防爆破 jail:
             - 自动 yum（含 EPEL）/ apt 安装
             - 写入 /etc/fail2ban/jail.local（10 分钟错 5 次封 1 小时）
             - 封禁动作按防火墙后端自动适配（firewalld/ufw/iptables）
             - systemctl enable --now 并用 fail2ban-client 验证
  firewall 防火墙常用操作（自动适配 firewalld/ufw，iptables 兜底）:
             status               查看防火墙状态与当前规则
             open <端口> [tcp|udp] 放行端口（永久生效）
             deny <IP>            封禁 IP（drop 全部流量）
             list                 列出当前生效规则
           不带子参数进入交互菜单。

示例:
  sudo ./lops.sh security check                  # 上线前/每周安全巡检
  sudo ./lops.sh security harden                 # 按菜单逐项加固
  sudo ./lops.sh security fail2ban               # 一次部署，长期防爆破
  sudo ./lops.sh security firewall open 8080 tcp # 放行业务端口
  sudo ./lops.sh security firewall deny 1.2.3.4  # 封禁恶意 IP
  ./lops.sh security firewall status             # 查状态（只读）

前置条件:
  - check 只读，普通用户可执行；但空口令/爆破统计/authorized_keys
    需要 root 才能读到，建议直接 sudo 执行获得完整结果
  - harden / fail2ban / firewall 全部需要 root
  - fail2ban 需要 root + 可用软件源（RHEL 系自动安装 EPEL 源）

注意事项:
  - 通俗概念:
      SELinux   内核级"安全门卫": 即使程序被入侵，也限制其越权行为
                （Enforcing 最安全 / Permissive 只记日志不拦截 / Disabled 关闭）
      SUID      "临时工牌"机制: 普通用户运行该程序时临时获得文件属主权限
                （passwd/sudo 等系统程序正常需要; 出现在 /tmp 等目录才可疑）
      fail2ban  日志巡逻的"看门狗": 谁反复登录失败就调用防火墙拉黑谁
      jail      fail2ban 的监控单元，一个 jail 盯一个服务（这里是 sshd）
  - harden 禁用 root 登录前，请确保已有其他管理账户（如 init user
    创建的 ops）并能登录，否则会把自己锁在门外
  - 切换密钥登录务必"先验证、后禁用"，全程保留当前会话不退出
  - 所有被修改的配置文件自动备份为 *.bak.<时间戳>，可随时回滚
  - fail2ban 解封命令: fail2ban-client set sshd unbanip <IP>
EOF
}

# ==============================================================================
# 内部辅助
# ==============================================================================

# 检测当前生效的防火墙后端: firewalld / ufw / iptables / none
# 检测顺序即优先级; 非 root 时 ufw/iptables 探测受限，结果可能偏低
security__fw_backend() {
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    echo "firewalld"
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    echo "ufw"
  elif command -v iptables >/dev/null 2>&1 \
    && [[ -n "$(iptables -S 2>/dev/null | grep -vE '^-(P|N) ' || true)" ]]; then
    # 过滤掉默认链策略(-P)与自定义链声明(-N)后仍有规则，说明裸 iptables 在用
    echo "iptables"
  else
    echo "none"
  fi
}

# 重载 sshd（发行版服务名不同: RHEL 系 sshd，Debian 系 ssh）
security__reload_sshd() {
  systemctl reload sshd 2>/dev/null \
    || systemctl reload ssh 2>/dev/null \
    || warn "无法自动 reload sshd，请手动执行: systemctl reload sshd"
}

# ==============================================================================
# check — 安全巡检（只读）
# ==============================================================================

security__check() {
  banner "lops security check — 安全巡检（只读）"
  if [[ "${EUID}" -ne 0 ]]; then
    warn "当前非 root: 空口令/爆破统计/authorized_keys 等项将不完整，建议 sudo 执行"
  fi
  local issues=()

  # ① 防火墙状态
  section "① 防火墙状态"
  local fw
  fw="$(security__fw_backend)"
  case "$fw" in
    firewalld)
      print_kv "运行中的防火墙" "firewalld"
      firewall-cmd --list-all 2>/dev/null | awk 'NR<=8' || true
      mark_ok "firewalld 正在运行"
      ;;
    ufw)
      print_kv "运行中的防火墙" "ufw"
      ufw status 2>/dev/null || true
      mark_ok "ufw 正在运行"
      ;;
    iptables)
      print_kv "运行中的防火墙" "iptables（裸规则模式）"
      iptables -S 2>/dev/null | awk 'NR<=8' || true
      mark_warn "使用裸 iptables 规则（重启易丢失，建议 firewalld/ufw 统一管理）"
      ;;
    none)
      mark_bad "未检测到运行中的防火墙（firewalld/ufw/iptables 均未生效）"
      issues+=("防火墙未运行")
      ;;
  esac

  # ② SELinux 状态
  section "② SELinux 状态"
  if command -v getenforce >/dev/null 2>&1; then
    local se
    se="$(getenforce 2>/dev/null || echo Unknown)"
    print_kv "SELinux" "$se"
    case "$se" in
      Enforcing)  mark_ok "Enforcing（强制模式，最安全）" ;;
      Permissive) mark_warn "Permissive（只记录不拦截），建议执行 setenforce 1" ;;
      Disabled)   mark_warn "Disabled（已关闭），如业务允许建议开启" ;;
      *)          mark_warn "无法确认 SELinux 状态: $se" ;;
    esac
  else
    print_kv "SELinux" "未安装（Debian/Ubuntu 常见，非异常）"
  fi

  # ③ SSH 配置
  section "③ SSH 配置"
  local sshd_conf="/etc/ssh/sshd_config"
  local prl="" pa="" ssh_port="" sshd_t=""
  if [[ -f "$sshd_conf" ]]; then
    # 优先用 sshd -T 读取"实际生效"配置（含 Include 展开）；失败回退解析主配置文件
    if command -v sshd >/dev/null 2>&1; then
      sshd_t="$(sshd -T 2>/dev/null || true)"
    fi
    if [[ -n "$sshd_t" ]]; then
      prl="$(awk 'tolower($1)=="permitrootlogin"{print $2}' <<<"$sshd_t")"
      pa="$(awk 'tolower($1)=="passwordauthentication"{print $2}' <<<"$sshd_t")"
      ssh_port="$(awk 'tolower($1)=="port"{print $2}' <<<"$sshd_t")"
    else
      # sshd_config 后写的值覆盖先写的，取最后一个匹配
      prl="$(awk 'tolower($1)=="permitrootlogin"{v=$2} END{print v}' "$sshd_conf" 2>/dev/null || true)"
      pa="$(awk 'tolower($1)=="passwordauthentication"{v=$2} END{print v}' "$sshd_conf" 2>/dev/null || true)"
      ssh_port="$(awk 'tolower($1)=="port"{v=$2} END{print v}' "$sshd_conf" 2>/dev/null || true)"
    fi
    print_kv "SSH 端口" "${ssh_port:-22（默认）}"
    print_kv "PermitRootLogin" "${prl:-prohibit-password（默认）}"
    print_kv "PasswordAuthentication" "${pa:-yes（默认）}"
    case "${prl:-prohibit-password}" in
      yes)
        mark_bad "PermitRootLogin yes — root 可直接 SSH 登录，是爆破首选目标"
        issues+=("SSH 允许 root 直接登录（PermitRootLogin yes）")
        ;;
      no)
        mark_ok "PermitRootLogin no — root 已禁止直接登录"
        ;;
      prohibit-password|without-password)
        mark_warn "PermitRootLogin ${prl} — root 仍可用密钥登录（建议改为 no）"
        ;;
    esac
    case "${pa:-yes}" in
      no)  mark_ok "PasswordAuthentication no — 已仅密钥登录" ;;
      yes) mark_warn "PasswordAuthentication yes — 建议迁移密钥后关闭密码登录" ;;
    esac
  else
    mark_warn "未找到 ${sshd_conf}，跳过 SSH 配置检查"
  fi

  # ④ 空口令账户
  section "④ 空口令账户"
  local empty_users=""
  if [[ -r /etc/shadow ]]; then
    # 口令字段为空 = 该账户无需密码即可登录（能登录的前提，仍属高危）
    empty_users="$(awk -F: '($2==""){print $1}' /etc/shadow 2>/dev/null || true)"
    if [[ -n "$empty_users" ]]; then
      local _u
      while read -r _u; do
        [[ -z "$_u" ]] && continue
        mark_bad "空口令账户: ${_u}"
      done <<<"$empty_users"
      issues+=("存在空口令账户: $(printf '%s' "$empty_users" | tr '\n' ' ')")
    else
      mark_ok "无空口令账户"
    fi
  else
    mark_warn "无 /etc/shadow 读取权限（需 root），跳过空口令检查"
  fi

  # ⑤ UID=0 账户清单
  section "⑤ UID=0（root 级）账户清单"
  local uid0 extra0
  uid0="$(awk -F: '$3==0{print $1}' /etc/passwd)"
  extra0="$(awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd)"
  print_kv "UID=0 账户" "$(printf '%s' "$uid0" | tr '\n' ' ')"
  if [[ -n "$extra0" ]]; then
    local _u0
    while read -r _u0; do
      [[ -z "$_u0" ]] && continue
      mark_bad "UID=0 非 root 账户: ${_u0}（等同于后门账户）"
    done <<<"$extra0"
    issues+=("存在 UID=0 非 root 账户: $(printf '%s' "$extra0" | tr '\n' ' ')")
  else
    mark_ok "仅 root 拥有 UID=0"
  fi

  # ⑥ 最近 24h 登录失败（爆破统计）
  section "⑥ 最近 24h 登录失败统计（爆破迹象）"
  if command -v lastb >/dev/null 2>&1 && [[ -r /var/log/btmp ]]; then
    local fail_cnt=0 fail_scope="全部记录" top_ip="" lastb_cmd="lastb"
    # 新版 util-linux 支持按时间过滤 -s；老版本回退统计全部
    if lastb -s -24h >/dev/null 2>&1; then
      lastb_cmd="lastb -s -24h"
      fail_scope="最近 24h"
    fi
    # 过滤空行与尾部 "btmp begins" 统计行
    fail_cnt="$(${lastb_cmd} 2>/dev/null | awk 'NF>1 && $1!="btmp"{c++} END{print c+0}' || true)"
    print_kv "失败登录次数（${fail_scope}）" "$fail_cnt"
    # 来源 IP Top5（$3 为来源地址，过滤非 IP 字段）
    top_ip="$(${lastb_cmd} 2>/dev/null | awk '$3 ~ /^[0-9]+\./{print $3}' | sort | uniq -c | sort -rn | awk 'NR<=5' || true)"
    if [[ -n "$top_ip" ]]; then
      echo "  来源 IP Top5:"
      printf '%s\n' "$top_ip" | awk '{printf "    %-8s %s\n", $1, $2}'
    fi
    if (( fail_cnt >= 100 )); then
      mark_bad "失败登录 ${fail_cnt} 次（>=100），正在被爆破，建议部署 fail2ban"
      issues+=("登录失败 ${fail_cnt} 次（${fail_scope}），存在爆破")
    elif (( fail_cnt >= 1 )); then
      mark_warn "少量失败登录属正常（记错密码/扫描器），持续增长再关注"
    else
      mark_ok "无失败登录记录"
    fi
  else
    mark_warn "读取 /var/log/btmp 需要 root（且需 lastb 命令），跳过爆破统计"
  fi

  # ⑦ authorized_keys 变更时间
  section "⑦ authorized_keys 变更时间"
  local ak_files="" ak
  ak_files="$(find /root/.ssh /home -maxdepth 3 -name authorized_keys -type f 2>/dev/null || true)"
  if [[ -z "$ak_files" ]]; then
    print_kv "authorized_keys" "未发现（无密钥登录文件，正常）"
  else
    local now_s cutoff mtime mdate owner
    now_s="$(date +%s)"
    cutoff=$(( now_s - 7 * 86400 ))
    while read -r ak; do
      [[ -z "$ak" ]] && continue
      mtime="$(stat -c %Y "$ak" 2>/dev/null || echo 0)"
      mdate="$(stat -c %y "$ak" 2>/dev/null | cut -d. -f1 || true)"
      owner="$(basename "$(dirname "$(dirname "$ak")")")"
      if (( mtime >= cutoff )); then
        mark_warn "用户 ${owner} 的密钥文件 7 天内有变更: ${mdate}  ${ak}（请确认为本人操作）"
        issues+=("authorized_keys 近期变更: ${ak}")
      else
        print_kv "用户 ${owner} 密钥变更时间" "${mdate}  ${ak}"
      fi
    done <<<"$ak_files"
  fi

  # ⑧ SUID 文件
  section "⑧ SUID 文件扫描"
  log "扫描 SUID 文件（根文件系统内，可能耗时数秒）..."
  local suid_list="" suid_cnt=0
  suid_list="$(find / -xdev -type f -perm -4000 2>/dev/null || true)"
  suid_cnt="$(printf '%s' "$suid_list" | grep -c '^' || true)"
  print_kv "SUID 文件数量" "${suid_cnt}（正常系统几十个，数量突增才可疑）"
  if (( suid_cnt > 0 )); then
    printf '%s\n' "$suid_list" | awk 'NR<=10 {print "  " $0}'
    (( suid_cnt > 10 )) && echo "  ...（仅展示前 10 个，基线建议记录本次全量）"
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    mark_warn "非 root 扫描可能遗漏受限目录，建议 sudo 执行"
  fi

  # ⑨ cron 可疑可写项
  section "⑨ 定时任务可写检查（cron）"
  local cron_bad=""
  # -perm -0002 = 任意用户可写（other-write），文件与目录均算（目录可写可植入计划任务）
  cron_bad="$(find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly \
    /etc/cron.monthly /etc/crontab /var/spool/cron -maxdepth 2 -perm -0002 2>/dev/null || true)"
  if [[ -n "$cron_bad" ]]; then
    local _c
    while read -r _c; do
      [[ -z "$_c" ]] && continue
      mark_bad "全局可写的 cron 项: ${_c}（任何用户都可植入定时任务）"
    done <<<"$cron_bad"
    issues+=("cron 存在全局可写项: $(printf '%s' "$cron_bad" | tr '\n' ' ')")
  else
    mark_ok "cron 相关目录/文件无可疑可写项"
  fi

  # ⑩ 无人值守自动升级风险（底层库自动更新 → APT 钩子 daemon-reexec → 托管服务批量重启）
  section "⑩ 无人值守自动升级风险（可致 systemd 托管服务批量重启）"
  if command -v apt-config >/dev/null 2>&1; then
    # Debian/Ubuntu: timer 禁用或自动升级开关为 0 才算安全
    local t_enabled="" uu_enabled=""
    systemctl is-enabled apt-daily-upgrade.timer >/dev/null 2>&1 && t_enabled="yes"
    apt-config dump 2>/dev/null | grep -E '^APT::Periodic::Unattended-Upgrade "1"' >/dev/null 2>&1 && uu_enabled="yes"
    if [[ -z "$t_enabled" && -z "$uu_enabled" ]]; then
      mark_ok "apt-daily-upgrade 已禁用，无人值守升级风险已关闭"
      # needrestart 策略检测（批量重启的直接执行者之一）
      if command -v needrestart >/dev/null 2>&1; then
        if [[ -f /etc/needrestart/conf.d/99-lops.conf ]] || grep -rEq "\\\$nrconf\{restart\}\s*=\s*'l'" /etc/needrestart/conf.d/ 2>/dev/null; then
          mark_ok "needrestart 已配置为只列出不自动重启"
        else
          mark_warn "needrestart 默认策略会在升级后自动重启使用旧库的服务（批量重启直接执行者），建议 ./lops.sh init unattended 设置 restart=l"
          issues+=("needrestart 未设置为只列出不重启")
        fi
      fi
    else
      local uu_blacklisted=""
      apt-config dump 2>/dev/null | grep 'Unattended-Upgrade::Package-Blacklist' | grep -q 'systemd' && uu_blacklisted="yes"
      if [[ -n "$uu_blacklisted" ]]; then
        mark_warn "自动升级运行中，黑名单仅缓解: util-linux/coreutils 等底层库更新同样触发 daemon-reexec（无法穷举拉黑），数据库/中间件节点建议 disable"
        issues+=("unattended-upgrades 仍在运行（黑名单模式不能完全防住，建议 ./lops.sh init unattended 关闭）")
      else
        mark_bad "unattended-upgrades 运行且无防护: 底层库自动更新触发 daemon-reexec，systemd 托管服务（数据库/中间件）批量重启（Doris 真实事故）"
        issues+=("unattended-upgrades 未关闭（建议 ./lops.sh init unattended）")
      fi
    fi
  elif command -v dnf >/dev/null 2>&1; then
    # RHEL 系: 看 dnf-automatic 是否在跑
    if systemctl is-active dnf-automatic.timer >/dev/null 2>&1; then
      mark_bad "dnf-automatic.timer 运行中: 自动升级底层库会触发 daemon-reexec 批量重启业务"
      issues+=("dnf-automatic 未停用（建议 systemctl disable --now dnf-automatic.timer）")
    else
      mark_ok "dnf-automatic 未启用，无自动升级风险"
    fi
  fi

  # 汇总
  echo ""
  banner "巡检结论"
  if (( ${#issues[@]} == 0 )); then
    mark_ok "10 项检查完成，未发现明显安全隐患"
  else
    mark_bad "发现 ${#issues[@]} 项安全隐患:"
    local i
    for i in "${issues[@]}"; do
      echo "  ✘ $i"
    done
    echo ""
    log "可执行 ./lops.sh security harden 逐项加固，或 ./lops.sh security fail2ban 部署防爆破"
  fi
}

# ==============================================================================
# harden — 交互式加固
# ==============================================================================

security__harden() {
  require_root
  while true; do
    echo ""
    banner "lops security harden — 交互式加固"
    local choice
    choice="$(menu_choose "请选择加固项" \
      "禁用 root SSH 直接登录（PermitRootLogin no）" \
      "为空口令账户设置随机密码" \
      "锁定可疑账户（usermod -L）" \
      "SSH 改密钥登录指引与切换")"
    case "$choice" in
      1) security__harden_no_root ;;
      2) security__harden_empty_pwd ;;
      3) security__harden_lock ;;
      4) security__harden_keylogin ;;
      *) return 0 ;;
    esac
  done
}

# 加固项 1: 禁用 root SSH 直接登录
security__harden_no_root() {
  local sshd_conf="/etc/ssh/sshd_config"
  section "加固: 禁用 root SSH 直接登录"
  [[ -f "$sshd_conf" ]] || { err "未找到 ${sshd_conf}"; return 1; }

  local cur
  cur="$(awk 'tolower($1)=="permitrootlogin"{v=$2} END{print v}' "$sshd_conf" 2>/dev/null || true)"
  print_kv "当前配置" "PermitRootLogin ${cur:-prohibit-password（默认）}"
  if [[ "$cur" == "no" ]]; then
    mark_ok "root 已禁止 SSH 直接登录，无需操作"
    return 0
  fi
  warn "前提: 必须已有其他管理账户（如 ops）且可正常 SSH 登录，否则将无法远程管理!"
  confirm "确认禁止 root 通过 SSH 登录?" || { log "已取消"; return 0; }

  backup_file "$sshd_conf"
  if grep -qiE '^[[:space:]]*PermitRootLogin[[:space:]]' "$sshd_conf"; then
    # I 标志: 大小写不敏感替换既有配置行
    sed -i -E 's/^[[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin no/I' "$sshd_conf"
  else
    printf '\nPermitRootLogin no\n' >> "$sshd_conf"
  fi

  # 改完先做语法校验，避免把 sshd 配置改坏导致重启后无法登录
  if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>/dev/null; then
    err "sshd -t 配置校验失败! 请检查 ${sshd_conf} 或回滚最近的 .bak 备份"
    return 1
  fi
  security__reload_sshd
  mark_ok "完成: root 已禁止 SSH 直接登录（当前会话不受影响，下次登录生效）"
  log "验证建议: 新开终端确认管理账户可登录后，再退出当前会话"
}

# 加固项 2: 为空口令账户设置随机密码
security__harden_empty_pwd() {
  section "加固: 为空口令账户设置随机密码"
  local empty
  empty="$(awk -F: '($2==""){print $1}' /etc/shadow 2>/dev/null || true)"
  if [[ -z "$empty" ]]; then
    mark_ok "无空口令账户，无需处理"
    return 0
  fi
  echo "以下账户口令为空（高危，等于不设防）:"
  local _u
  while read -r _u; do
    [[ -z "$_u" ]] && continue
    echo "  - ${_u}"
  done <<<"$empty"

  local user
  user="$(ask_value "请输入要设置密码的用户名（回车取消）")"
  [[ -z "$user" ]] && { log "已取消"; return 0; }
  if ! printf '%s\n' "$empty" | grep -qxF -- "$user"; then
    err "${user} 不在空口令账户清单中（本入口仅处理空口令账户）"
    return 1
  fi
  confirm "确认为 ${user} 生成 16 位随机密码并写入?" || { log "已取消"; return 0; }

  local newpwd
  newpwd="$(gen_password 16)"
  echo "${user}:${newpwd}" | chpasswd
  usermod -U "$user" 2>/dev/null || true   # 若账户同时处于锁定状态则解锁
  mark_ok "密码已设置并写入账户"
  echo ""
  printf "  用户:   %s\n  新密码: %s\n" "$user" "$newpwd"
  warn "请立即记录并妥善保存该密码（这是唯一一次显示）"
  passwd -S "$user" 2>/dev/null || true
}

# 加固项 3: 锁定可疑账户
security__harden_lock() {
  section "加固: 锁定可疑账户"
  # 可疑范围: 空口令账户 + UID=0 非 root 账户
  local suspect=""
  suspect="$(awk -F: '($2==""){print $1}' /etc/shadow 2>/dev/null || true)"
  suspect+="$(awk -F: '$3==0 && $1!="root" && $1!=""{print $1}' /etc/passwd)"
  if [[ -z "${suspect//[$' \n']/}" ]]; then
    mark_ok "未发现空口令/UID=0 异常账户，无锁定对象"
    return 0
  fi
  echo "可疑账户（空口令 或 UID=0 非 root）:"
  printf '%s\n' "$suspect" | awk 'NF>0{print "  - " $0}' | sort -u

  local user
  user="$(ask_value "请输入要锁定的用户名（回车取消）")"
  [[ -z "$user" ]] && { log "已取消"; return 0; }
  if ! id "$user" >/dev/null 2>&1; then
    err "用户不存在: ${user}"
    return 1
  fi
  if [[ "$user" == "root" ]]; then
    err "拒绝锁定 root（会导致系统无法管理）"
    return 1
  fi
  confirm "确认锁定 ${user}?（锁定后无法登录，解锁命令: usermod -U ${user}）" || { log "已取消"; return 0; }

  usermod -L "$user"
  mark_ok "账户 ${user} 已锁定"
  passwd -S "$user" 2>/dev/null || true
}

# 加固项 4: SSH 改密钥登录指引与切换
security__harden_keylogin() {
  section "加固: SSH 改密钥登录（指引 + 可选切换）"
  cat <<'EOF'
分步指引（密钥登录 = 私钥证明身份，密码可被爆破而私钥文件不能）:

 1. 在你的【本地电脑】生成密钥对（Ed25519 更快更安全）:
      ssh-keygen -t ed25519 -C "ops-key"
    一路回车即可; 生成的私钥 ~/.ssh/id_ed25519 绝不能外传。

 2. 把公钥铺到服务器（把 user 换成你的管理账户）:
      ssh-copy-id user@服务器IP
    （即追加本地 ~/.ssh/id_ed25519.pub 到服务器该用户家目录的
      .ssh/authorized_keys 文件末尾）

 3. 【新开一个终端】验证: ssh user@服务器IP 能否免密登录。
    切记: 验证成功前不要关闭当前会话!

 4. 验证成功后，回来执行下面的切换（关闭密码登录）。
EOF
  echo ""
  if ! confirm "是否已验证密钥可登录，并立即禁用 SSH 密码登录?"; then
    log "暂不切换。请先完成上述 1-3 步验证后再来"
    return 0
  fi

  local sshd_conf="/etc/ssh/sshd_config"
  [[ -f "$sshd_conf" ]] || { err "未找到 ${sshd_conf}"; return 1; }
  backup_file "$sshd_conf"
  if grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]' "$sshd_conf"; then
    sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication no/I' "$sshd_conf"
  else
    printf '\nPasswordAuthentication no\n' >> "$sshd_conf"
  fi
  if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>/dev/null; then
    err "sshd -t 配置校验失败! 请检查 ${sshd_conf} 或回滚 .bak 备份"
    return 1
  fi
  security__reload_sshd
  mark_ok "完成: SSH 已禁用密码登录（仅密钥）"
  warn "请保持当前会话，并立即新开终端验证密钥登录成功后再退出!"
}

# ==============================================================================
# fail2ban — 安装部署
# ==============================================================================

security__fail2ban() {
  require_root
  detect_os
  banner "lops security fail2ban — 部署 sshd 防爆破"

  # RHEL 系的 fail2ban 在 EPEL 源，先确保 epel-release（已装会自动跳过）
  if is_redhat_family; then
    pkg_install epel-release >/dev/null 2>&1 || true
  fi

  if ! command -v fail2ban-server >/dev/null 2>&1; then
    log "安装 fail2ban ..."
    pkg_install fail2ban
  else
    log "fail2ban 已安装: $(fail2ban-server --version 2>/dev/null | awk 'NR<=1' || echo ok)"
  fi

  # 封禁动作按本机防火墙后端自动适配
  local fw banaction
  fw="$(security__fw_backend)"
  case "$fw" in
    firewalld) banaction="firewallcmd-rich-rules" ;;
    ufw)       banaction="ufw" ;;
    *)         banaction="iptables-multiport" ;;
  esac

  # 写入 jail.local（已存在则先备份）
  local jail="/etc/fail2ban/jail.local"
  backup_file "$jail"
  cat > "$jail" <<EOF
# 由 lops security fail2ban 生成（$(date '+%F %T')）
[DEFAULT]
# 封禁策略: 10 分钟内失败 5 次即封 1 小时（可按需调整）
bantime  = 1h
findtime = 10m
maxretry = 5
# 封禁动作按本机防火墙自动适配（当前后端: ${fw}）
banaction = ${banaction}

[sshd]
enabled = true
# 新系统无 /var/log/auth.log，改从 systemd journal 读取登录日志
backend = systemd
EOF
  log "已写入 ${jail}（sshd jail 启用，backend=systemd）"

  # 已运行则 restart 加载新配置；未运行则 enable --now 开机自启并立即启动
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    systemctl restart fail2ban
  else
    systemctl enable --now fail2ban
  fi
  sleep 2

  section "部署验证"
  if fail2ban-client status sshd 2>/dev/null; then
    mark_ok "fail2ban sshd jail 运行正常（上表含当前封禁 IP 列表）"
  else
    mark_warn "sshd jail 状态获取失败，查看整体状态:"
    fail2ban-client status 2>/dev/null || true
    warn "排查命令: journalctl -u fail2ban -n 30 --no-pager"
    warn "老系统（如 CentOS 7）若 backend=systemd 报错，可将 ${jail} 中 backend 改为 auto 后 systemctl restart fail2ban"
    return 1
  fi
  echo ""
  log "常用命令: fail2ban-client status sshd（查封禁）/ fail2ban-client set sshd unbanip <IP>（解封）"
}

# ==============================================================================
# firewall — 防火墙常用操作
# ==============================================================================

# 子操作分发: firewall [status|open <port> [tcp|udp]|deny <ip>|list]
security__firewall() {
  local sub="${1:-}"
  case "$sub" in
    "")     security__fw_menu ;;
    status) security__fw_status ;;
    open)   shift; security__fw_open "$@" ;;
    deny)   shift; security__fw_deny "$@" ;;
    list)   security__fw_list ;;
    *)
      err "未知子操作: security firewall ${sub}（可选: status/open/deny/list）"
      return 1
      ;;
  esac
}

security__fw_menu() {
  while true; do
    echo ""
    banner "lops security firewall — 防火墙操作"
    local choice port proto ip
    choice="$(menu_choose "请选择操作" \
      "查看防火墙状态" \
      "放行端口" \
      "封禁 IP" \
      "列出当前规则")"
    case "$choice" in
      1) security__fw_status ;;
      2) port="$(ask_value "端口号 (1-65536)")"
         [[ -z "$port" ]] && continue
         proto="$(ask_value "协议 (tcp/udp)" "tcp")"
         security__fw_open "$port" "$proto" ;;
      3) ip="$(ask_value "要封禁的 IP 地址")"
         [[ -z "$ip" ]] && continue
         security__fw_deny "$ip" ;;
      4) security__fw_list ;;
      *) return 0 ;;
    esac
  done
}

security__fw_status() {
  section "防火墙状态"
  if [[ "${EUID}" -ne 0 ]]; then
    warn "非 root 下 ufw/iptables 状态可能读取失败，建议 sudo 执行"
  fi
  local fw
  fw="$(security__fw_backend)"
  case "$fw" in
    firewalld)
      print_kv "后端" "firewalld"
      print_kv "状态" "$(firewall-cmd --state 2>/dev/null || echo unknown)"
      print_kv "默认区域" "$(firewall-cmd --get-default-zone 2>/dev/null || echo unknown)"
      firewall-cmd --list-all 2>/dev/null || true
      ;;
    ufw)
      print_kv "后端" "ufw"
      ufw status verbose 2>/dev/null || true
      ;;
    iptables)
      print_kv "后端" "iptables（裸规则）"
      iptables -L -n 2>/dev/null | awk 'NR<=15' || true
      ;;
    none)
      mark_bad "未检测到运行中的防火墙"
      echo "  建议（二选一）:"
      echo "    yum install firewalld && systemctl enable --now firewalld"
      echo "    apt install ufw && ufw allow 22/tcp && ufw enable   # 先放行 SSH 再启用!"
      ;;
  esac
}

# 放行端口: security__fw_open <port> [tcp|udp]
security__fw_open() {
  local port="${1:-}" proto="${2:-tcp}"
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    err "无效端口号: ${port}（应为 1-65535）"
    return 1
  fi
  proto="${proto,,}"
  [[ "$proto" == "tcp" || "$proto" == "udp" ]] || { err "协议只能是 tcp/udp: ${proto}"; return 1; }
  require_root

  local fw
  fw="$(security__fw_backend)"
  case "$fw" in
    firewalld)
      confirm "确认放行端口 ${port}/${proto}?（外部将可访问该端口）" || { log "已取消"; return 0; }
      firewall-cmd --permanent --add-port="${port}/${proto}" \
        && firewall-cmd --reload \
        && mark_ok "已放行 ${port}/${proto}（永久规则，立即生效）"
      ;;
    ufw)
      confirm "确认放行端口 ${port}/${proto}?（外部将可访问该端口）" || { log "已取消"; return 0; }
      ufw --force allow "${port}/${proto}" \
        && mark_ok "已放行 ${port}/${proto}"
      ;;
    iptables)
      warn "当前为裸 iptables 模式: 规则仅存于内存，重启后丢失"
      confirm "确认放行 ${port}/${proto}?" || { log "已取消"; return 0; }
      iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT \
        && mark_ok "已放行 ${port}/${proto}（内存生效，建议尽快改用 firewalld/ufw）"
      ;;
    none)
      err "未检测到运行中的防火墙，规则无处生效。请先启用 firewalld 或 ufw"
      return 1
      ;;
  esac
}

# 封禁 IP: security__fw_deny <ip>
security__fw_deny() {
  local ip="${1:-}"
  if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    err "无效 IPv4 地址: ${ip}"
    return 1
  fi
  local o
  for o in ${ip//./ }; do
    if (( o > 255 )); then
      err "无效 IPv4 地址: ${ip}"
      return 1
    fi
  done
  require_root

  warn "封禁后该 IP 对本机所有端口的访问将被丢弃（drop），请确认不是自己的管理 IP!"
  confirm "确认封禁 ${ip}?" || { log "已取消"; return 0; }

  local fw
  fw="$(security__fw_backend)"
  case "$fw" in
    firewalld)
      firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${ip}' drop" \
        && firewall-cmd --reload \
        && mark_ok "已封禁 ${ip}（drop，永久规则）"
      ;;
    ufw)
      ufw --force deny from "$ip" \
        && mark_ok "已封禁 ${ip}"
      ;;
    iptables)
      iptables -I INPUT -s "$ip" -j DROP \
        && mark_ok "已封禁 ${ip}（内存生效，重启丢失）"
      ;;
    none)
      err "未检测到运行中的防火墙，规则无处生效。请先启用 firewalld 或 ufw"
      return 1
      ;;
  esac
}

security__fw_list() {
  section "当前防火墙规则"
  if [[ "${EUID}" -ne 0 ]]; then
    warn "非 root 下 ufw/iptables 规则可能读取失败，建议 sudo 执行"
  fi
  local fw
  fw="$(security__fw_backend)"
  case "$fw" in
    firewalld) firewall-cmd --list-all 2>/dev/null || true ;;
    ufw)       ufw status numbered 2>/dev/null || true ;;
    iptables)  iptables -L -n -v --line-numbers 2>/dev/null | awk 'NR<=25' || true ;;
    none)      mark_bad "未检测到运行中的防火墙（无规则可列出）" ;;
  esac
}

# ==============================================================================
# 动作分发
# ==============================================================================

mod_security_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_security_help; return 1; }
  shift || true

  case "$action" in
    check)    security__check ;;
    harden)   security__harden ;;
    fail2ban) security__fail2ban ;;
    firewall) security__firewall "$@" ;;
    *)
      err "未知动作: security ${action}"
      mod_security_help
      return 1
      ;;
  esac
}

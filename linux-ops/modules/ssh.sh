#!/usr/bin/env bash
# ==============================================================================
# lops 模块: ssh — SSH 安全与密钥管理
# ==============================================================================

LOPS_SSH_PORT="${LOPS_SSH_PORT:-22}"
LOPS_PASSWORD_AUTH="${LOPS_PASSWORD_AUTH:-yes}"
LOPS_ROOT_LOGIN="${LOPS_ROOT_LOGIN:-yes}"

mod_ssh_desc() {
  echo "SSH 安全（密钥生成/批量推送公钥/安全加固/配置审计）"
}

mod_ssh_actions() {
  cat <<'EOF'
keygen|为当前用户生成 ed25519 密钥对
pushkey|按主机清单批量推送 SSH 公钥（expect 自动输密码）
harden|SSH 安全基线加固（写配置前备份，sshd -t 校验后重启）
audit|只读审计当前 sshd 生效配置的安全项
EOF
}

mod_ssh_help() {
  cat <<EOF
lops ssh — SSH 安全与密钥管理
==============================================================================
覆盖 SSH 运维四件事：本机密钥生成、批量推送公钥（免密铺设）、
安全基线加固、配置只读审计。加固动作自动备份原配置，
sshd -t 校验失败会自动回滚，避免把机器锁死。

用法:
  ./lops.sh ssh <action> [参数]

动作说明:
  keygen                    为当前用户生成 ed25519 密钥对
                            （~/.ssh/id_ed25519，无口令）。已存在则跳过
                            并显示公钥内容。
  pushkey <ip_file> [key]   批量推送公钥到远程主机。ip_file 每行格式:
                            "IP 用户名 密码"（# 开头行忽略）。
                            默认公钥 ~/.ssh/id_ed25519.pub。
                            依赖 expect + ssh-copy-id（缺失时提示安装）。
                            逐台推送，结尾汇总成功/失败数。
  harden                    写入 SSH 安全基线:
                              Port（LOPS_SSH_PORT，默认 22）
                              PasswordAuthentication（LOPS_PASSWORD_AUTH，默认 yes）
                              PermitRootLogin（LOPS_ROOT_LOGIN，默认 yes）
                              PubkeyAuthentication yes / PermitEmptyPasswords no
                              X11Forwarding no / UseDNS no / MaxAuthTries 3
                              ClientAliveInterval 60 / ClientAliveCountMax 3
                            Debian 系写入 sshd_config.d/；RedHat 系追加到
                            sshd_config（先备份）。sshd -t 校验通过才重启，
                            失败自动回滚。
  audit                     只读检查 sshd -T 实际生效的安全配置，
                            逐项输出配置值与 ✓/⚠ 状态及建议。

可配置环境变量:
  LOPS_SSH_PORT=22          # harden 时的 SSH 端口
  LOPS_PASSWORD_AUTH=yes    # harden 时是否保留密码登录（no=仅密钥）
  LOPS_ROOT_LOGIN=yes       # harden 时 root 登录策略
                            （yes/prohibit-password/no）

示例:
  ./lops.sh ssh keygen                          # 生成密钥对
  ./lops.sh ssh pushkey hosts.txt               # 按 hosts.txt 批量铺公钥
  ./lops.sh ssh pushkey hosts.txt ~/.ssh/id_ed25519.pub
  LOPS_SSH_PORT=2222 ./lops.sh ssh harden       # 加固并改端口为 2222
  LOPS_PASSWORD_AUTH=no ./lops.sh ssh harden    # 加固并关闭密码登录
  ./lops.sh ssh audit                           # 只读安全审计

前置条件:
  - pushkey 依赖 expect 与 ssh-copy-id（未安装会提示安装命令）
  - harden 需要 root 权限

注意事项:
  ⚠⚠ 远程通过 SSH 执行 harden 时，若修改端口或关闭密码登录，
     务必保持当前会话不退出，另开新终端验证新配置可登录后再收尾。
  - pushkey 的主机清单含明文密码，用完建议删除或加密保存。
  - audit 只读不改配置，可放心在任何机器执行。
EOF
}

# ---------- 动作实现 ----------

ssh__keygen() {
  local key="${HOME}/.ssh/id_ed25519"
  if [[ -f "$key" ]]; then
    log "密钥已存在: ${key}"
    log "公钥内容:"
    cat "${key}.pub"
    return 0
  fi
  mkdir -p "${HOME}/.ssh"
  chmod 0700 "${HOME}/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$key" -C "${USER}@$(hostname)"
  log "密钥对已生成:"
  print_kv "私钥" "$key"
  print_kv "公钥" "${key}.pub"
  echo ""
  cat "${key}.pub"
}

ssh__pushkey() {
  local ip_file="${1:-}"
  local key="${2:-${HOME}/.ssh/id_ed25519.pub}"

  # 交互环境参数缺失时提示输入
  if [[ -z "$ip_file" ]] && [[ -t 0 ]]; then
    ip_file="$(ask_value "主机清单文件路径（每行: IP 用户名 密码）")"
  fi
  [[ -z "$ip_file" ]] && { err "用法: lops.sh ssh pushkey <ip_file> [key_file]"; return 1; }

  require_cmd expect || { err "请先安装: apt install expect 或 yum install expect"; return 1; }
  require_cmd ssh-copy-id || { err "请先安装: apt install openssh-client 或 yum install openssh-clients"; return 1; }

  if [[ ! -f "$ip_file" ]]; then
    err "主机清单文件不存在: ${ip_file}"
    err "格式示例（每行）: 192.168.1.10 root yourpassword"
    return 1
  fi
  if [[ ! -f "$key" ]]; then
    err "公钥不存在: ${key}（可先执行 ./lops.sh ssh keygen 生成）"
    return 1
  fi

  local ip username password success=0 fail=0
  while IFS=' ' read -r ip username password || [[ -n "$ip" ]]; do
    [[ -z "${ip}" || "${ip}" == \#* ]] && continue
    # 剥离 Windows 换行符，避免密码末尾多出 \r 导致认证失败
    ip="${ip%$'\r'}"
    username="${username%$'\r'}"
    password="${password%$'\r'}"
    section "推送: ${username}@${ip}"
    if expect <<EOF
set timeout 30
spawn ssh-copy-id -i "${key}" -o StrictHostKeyChecking=no ${username}@${ip}
expect {
    "(yes/no" { send "yes\r"; exp_continue }
    "password:" { send "${password}\r" }
    timeout { exit 1 }
}
expect {
    "already exist" { exit 0 }
    "Number of key(s) added" { exit 0 }
    "now try logging" { exit 0 }
    timeout { exit 1 }
    eof
}
EOF
    then
      mark_ok "${ip} 推送成功"
      success=$((success + 1))
    else
      mark_bad "${ip} 推送失败"
      fail=$((fail + 1))
    fi
  done < "$ip_file"

  echo ""
  section "推送结果汇总"
  print_kv "成功" "${success} 台"
  print_kv "失败" "${fail} 台"
  log "验证: ssh <user>@<ip> 应免密登录"
}

ssh__harden() {
  require_root
  section "SSH 安全基线加固"
  print_kv "端口" "${LOPS_SSH_PORT}"
  print_kv "密码登录" "${LOPS_PASSWORD_AUTH}"
  print_kv "root 登录" "${LOPS_ROOT_LOGIN}"

  local conf_block
  conf_block="# --- lops ssh harden 开始 ---
Port ${LOPS_SSH_PORT}
Protocol 2
PasswordAuthentication ${LOPS_PASSWORD_AUTH}
PubkeyAuthentication yes
PermitRootLogin ${LOPS_ROOT_LOGIN}
PermitEmptyPasswords no
X11Forwarding no
UseDNS no
MaxAuthTries 3
ClientAliveInterval 60
ClientAliveCountMax 3
# --- lops ssh harden 结束 ---"

  local target
  if [[ -d /etc/ssh/sshd_config.d ]] && grep -q "^Include /etc/ssh/sshd_config.d" /etc/ssh/sshd_config 2>/dev/null; then
    # Debian 系：独立配置文件。
    # sshd 对同名指令"首次出现生效"（first-obtained value wins），
    # Include 位于主配置顶部、目录内按文件名排序加载，
    # 因此用 00- 前缀排在 50-cloud-init 等其他 drop-in 之前，确保我们的配置优先生效
    target="/etc/ssh/sshd_config.d/00-lops-sshd.conf"
    backup_file "$target"
    echo "$conf_block" > "$target"
  else
    # RedHat 系或旧版：追加到主配置。
    # 同样因为"首次出现生效"，追加在文件末尾的指令不会覆盖文件中已存在的同名指令，
    # 必须先把已存在的同名指令注释掉，再追加我们的配置块
    target="/etc/ssh/sshd_config"
    backup_file "$target"
    # 注释掉已存在的同名指令（避免其优先于我们追加的配置生效）
    sed -i -r 's/^[[:space:]]*(Port|Protocol|PasswordAuthentication|PubkeyAuthentication|PermitRootLogin|PermitEmptyPasswords|X11Forwarding|UseDNS|MaxAuthTries|ClientAliveInterval|ClientAliveCountMax)[[:space:]]+/# \1 /' "$target"
    # 移除旧的 lops 配置块再追加，保证幂等
    sed -i '/# --- lops ssh harden 开始 ---/,/# --- lops ssh harden 结束 ---/d' "$target"
    echo "$conf_block" >> "$target"
  fi

  if ! sshd -t; then
    err "sshd 配置校验失败，正在回滚..."
    # 回滚：恢复最近的备份
    local latest_bak
    # shellcheck disable=SC2012  # 需按时间取最近备份，ls -t 最直接
    latest_bak="$(ls -t "${target}".bak.* 2>/dev/null | head -n 1)"
    if [[ -n "$latest_bak" ]]; then
      cp -a "$latest_bak" "$target"
      log "已回滚到备份: ${latest_bak}"
    else
      if [[ "$target" == *.d/* ]]; then rm -f "$target"; else
        sed -i '/# --- lops ssh harden 开始 ---/,/# --- lops ssh harden 结束 ---/d' "$target"
      fi
      log "已移除本次写入的配置块"
    fi
    die "回滚完成，sshd 未重启，服务不受影响"
  fi

  systemctl restart sshd 2>/dev/null || systemctl restart ssh
  log "SSH 已加固并重启（配置: ${target}）"
  warn "请保持当前会话，另开新终端验证 SSH 可正常登录后再退出"
}

ssh__audit() {
  section "SSH 配置安全审计（只读）"
  if ! command -v sshd >/dev/null 2>&1; then
    err "未找到 sshd 命令（可能客户端环境）"
    return 1
  fi

  local conf pass=0 warn_n=0
  conf="$(sshd -T 2>/dev/null)"
  if [[ -z "$conf" ]]; then
    err "sshd -T 无法读取生效配置（尝试 sudo 重试）"
    return 1
  fi

  local item
  for item in port permitrootlogin passwordauthentication pubkeyauthentication \
              permitemptypasswords maxauthtries x11forwarding usedns; do
    local val
    val="$(echo "$conf" | awk -v k="$item" 'tolower($1)==k {print $2; exit}')"
    [[ -z "$val" ]] && val="(未设置)"
    case "$item" in
      port)
        if [[ "$val" == "22" ]]; then
          mark_warn "Port ${val}（默认端口，建议改为非标准端口）"; warn_n=$((warn_n + 1))
        else
          mark_ok "Port ${val}"; pass=$((pass + 1))
        fi
        ;;
      permitrootlogin)
        if [[ "$val" == "yes" ]]; then
          mark_warn "PermitRootLogin ${val}（建议 prohibit-password 或 no）"; warn_n=$((warn_n + 1))
        else
          mark_ok "PermitRootLogin ${val}"; pass=$((pass + 1))
        fi
        ;;
      passwordauthentication)
        if [[ "$val" == "yes" ]]; then
          mark_warn "PasswordAuthentication ${val}（建议密钥登录后改为 no）"; warn_n=$((warn_n + 1))
        else
          mark_ok "PasswordAuthentication ${val}"; pass=$((pass + 1))
        fi
        ;;
      pubkeyauthentication)
        if [[ "$val" == "yes" ]]; then
          mark_ok "PubkeyAuthentication ${val}"; pass=$((pass + 1))
        else
          mark_bad "PubkeyAuthentication ${val}（密钥登录被禁用）"; warn_n=$((warn_n + 1))
        fi
        ;;
      permitemptypasswords)
        if [[ "$val" == "no" ]]; then
          mark_ok "PermitEmptyPasswords ${val}"; pass=$((pass + 1))
        else
          mark_bad "PermitEmptyPasswords ${val}（允许空密码！）"; warn_n=$((warn_n + 1))
        fi
        ;;
      maxauthtries)
        if [[ "$val" =~ ^[0-9]+$ ]] && (( val <= 4 )); then
          mark_ok "MaxAuthTries ${val}"; pass=$((pass + 1))
        else
          mark_warn "MaxAuthTries ${val}（建议 <= 4）"; warn_n=$((warn_n + 1))
        fi
        ;;
      x11forwarding)
        if [[ "$val" == "no" ]]; then
          mark_ok "X11Forwarding ${val}"; pass=$((pass + 1))
        else
          mark_warn "X11Forwarding ${val}（服务器建议关闭）"; warn_n=$((warn_n + 1))
        fi
        ;;
      usedns)
        if [[ "$val" == "no" ]]; then
          mark_ok "UseDNS ${val}"; pass=$((pass + 1))
        else
          mark_warn "UseDNS ${val}（建议 no，加快连接）"; warn_n=$((warn_n + 1))
        fi
        ;;
    esac
  done

  echo ""
  hr
  print_kv "通过项" "$pass"
  print_kv "警告项" "$warn_n"
  if (( warn_n == 0 )); then
    mark_ok "SSH 配置整体安全"
  else
    mark_warn "存在 ${warn_n} 项可优化，可执行 ./lops.sh ssh harden 一键加固"
  fi
}

# ---------- 动作分发 ----------
mod_ssh_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_ssh_help; return 1; }
  shift || true

  case "$action" in
    keygen)   ssh__keygen ;;
    pushkey)  ssh__pushkey "$@" ;;
    harden)   ssh__harden ;;
    audit)    ssh__audit ;;
    *)
      err "未知动作: ssh ${action}"
      mod_ssh_help
      return 1
      ;;
  esac
}

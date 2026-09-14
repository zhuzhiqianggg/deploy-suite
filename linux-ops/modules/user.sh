#!/usr/bin/env bash
# ==============================================================================
# lops 模块: user — 用户与权限管理
# ==============================================================================

LOPS_USER_PASS_DIR="/root/.lops-user-pass"

mod_user_desc() {
  echo "用户管理（创建/删除/密码重置/sudo 免密/用户清单）"
}

mod_user_actions() {
  cat <<'EOF'
add|创建用户并设置随机密码（可选加入指定组）
del|删除用户及其家目录（二次确认，禁删系统用户）
passwd|重置用户密码为新的随机密码
sudo|为用户配置 sudo 免密（visudo 校验）
list|列出所有可登录用户及所属组
EOF
}

mod_user_help() {
  cat <<EOF
lops user — 用户与权限管理
==============================================================================
覆盖日常用户生命周期：创建（自动生成随机密码并落盘）、删除、密码重置、
sudo 免密配置、用户清单查看。所有密码操作均生成 20 位随机密码，
并保存到 /root/.lops-user-pass/<用户名>.pass（仅 root 可读）。

用法:
  ./lops.sh user <action> [参数]

动作说明:
  add <username> [group]   创建用户（useradd -m -s /bin/bash），
                           指定 group 时自动创建缺失的用户组并加入。
                           自动生成 20 位随机密码并 chpasswd 设置。
  del <username>           userdel -r 删除用户及家目录。执行前显示
                           用户名/uid/家目录并要求二次确认。
                           禁止删除 root 及 uid < 1000 的系统用户。
  passwd <username>        重置为新的 20 位随机密码（二次确认），
                           新密码更新到 /root/.lops-user-pass/。
  sudo <username>          写入 /etc/sudoers.d/<username> 免密 sudo，
                           写入后 visudo -cf 校验，校验失败自动删除并报错。
  list                     列出 uid >= 1000 或 shell 可登录的用户，
                           显示 uid/家目录/shell/所属组。只读。

示例:
  ./lops.sh user add zhangsan dev        # 创建 zhangsan 并加入 dev 组
  ./lops.sh user add testuser            # 创建 testuser（默认组）
  ./lops.sh user passwd zhangsan         # 重置 zhangsan 的密码
  ./lops.sh user sudo zhangsan           # 给 zhangsan 配 sudo 免密
  ./lops.sh user del zhangsan            # 删除 zhangsan（需确认）
  ./lops.sh user list                    # 查看用户清单

前置条件:
  - add/del/passwd/sudo 需要 root 权限；list 只读无需 root

注意事项:
  - 随机密码保存在 /root/.lops-user-pass/（目录 700 / 文件 600），
    请通过安全渠道告知用户并提醒首次登录后修改。
  - del 会连带删除家目录，不可恢复，请确认家目录无重要数据。
  - sudo 免密属于高危授权，请遵循最小权限原则按需分配。
EOF
}

# ---------- 动作实现 ----------

user__save_pass() {
  local user="$1" pass="$2"
  mkdir -p "${LOPS_USER_PASS_DIR}"
  chmod 0700 "${LOPS_USER_PASS_DIR}"
  umask 077
  echo "${pass}" > "${LOPS_USER_PASS_DIR}/${user}.pass"
  chmod 0600 "${LOPS_USER_PASS_DIR}/${user}.pass"
  umask 022
}

user__add() {
  require_root
  local username="${1:-}"
  local group="${2:-}"
  [[ -z "$username" ]] && { err "用法: lops.sh user add <username> [group]"; return 1; }

  if id "$username" >/dev/null 2>&1; then
    err "用户 ${username} 已存在"
    return 1
  fi

  if [[ -n "$group" ]]; then
    if ! getent group "$group" >/dev/null 2>&1; then
      groupadd "$group"
      log "已创建用户组: ${group}"
    fi
    useradd -m -s /bin/bash -G "$group" "$username"
  else
    useradd -m -s /bin/bash "$username"
  fi

  local pass
  pass="$(gen_password 20)"
  echo "${username}:${pass}" | chpasswd
  user__save_pass "$username" "$pass"

  log "用户 ${username} 创建成功"
  print_kv "用户名" "$username"
  print_kv "所属组" "$(id -nG "$username")"
  print_kv "随机密码" "$pass"
  print_kv "密码存档" "${LOPS_USER_PASS_DIR}/${username}.pass"
  warn "请通过安全渠道将密码告知用户，并提醒首次登录后修改"
}

user__del() {
  require_root
  local username="${1:-}"
  [[ -z "$username" ]] && { err "用法: lops.sh user del <username>"; return 1; }

  if ! id "$username" >/dev/null 2>&1; then
    err "用户 ${username} 不存在"
    return 1
  fi

  local uid home_dir
  uid="$(id -u "$username")"
  home_dir="$(eval echo "~${username}")"

  if [[ "$uid" -lt 1000 || "$username" == "root" ]]; then
    err "拒绝删除系统用户: ${username} (uid=${uid})"
    return 1
  fi

  echo ""
  print_kv "将删除用户" "$username"
  print_kv "UID" "$uid"
  print_kv "家目录" "$home_dir"
  echo ""
  if ! confirm "确认删除该用户及其家目录？此操作不可恢复"; then
    log "已取消删除"
    return 0
  fi

  userdel -r "$username"
  rm -f "${LOPS_USER_PASS_DIR}/${username}.pass" 2>/dev/null || true
  log "用户 ${username} 及其家目录已删除"
}

user__passwd() {
  require_root
  local username="${1:-}"
  [[ -z "$username" ]] && { err "用法: lops.sh user passwd <username>"; return 1; }

  if ! id "$username" >/dev/null 2>&1; then
    err "用户 ${username} 不存在"
    return 1
  fi

  if ! confirm "确认重置 ${username} 的密码？"; then
    log "已取消"
    return 0
  fi

  local pass
  pass="$(gen_password 20)"
  echo "${username}:${pass}" | chpasswd
  user__save_pass "$username" "$pass"

  log "密码已重置"
  print_kv "用户名" "$username"
  print_kv "新密码" "$pass"
}

user__sudo() {
  require_root
  local username="${1:-}"
  [[ -z "$username" ]] && { err "用法: lops.sh user sudo <username>"; return 1; }

  if ! id "$username" >/dev/null 2>&1; then
    err "用户 ${username} 不存在"
    return 1
  fi

  local f="/etc/sudoers.d/${username}"
  echo "${username} ALL=(ALL) NOPASSWD:ALL" > "$f"
  chmod 0440 "$f"

  if command -v visudo >/dev/null 2>&1; then
    if ! visudo -cf "$f" >/dev/null; then
      rm -f "$f"
      die "sudoers 校验失败，已回滚（未写入 $f）"
    fi
  fi
  log "已配置 ${username} sudo 免密: ${f}"
}

user__list() {
  section "可登录用户清单"
  printf "  %-16s %-8s %-24s %-16s %s\n" "用户" "UID" "家目录" "SHELL" "所属组"
  hr
  local user uid shell home groups
  while IFS=':' read -r user _ uid _ _ home shell; do
    [[ "$shell" == */nologin || "$shell" == */false ]] && [[ "$uid" -lt 1000 ]] && continue
    groups="$(id -nG "$user" 2>/dev/null | tr '\n' ' ')"
    printf "  %-16s %-8s %-24s %-16s %s\n" "$user" "$uid" "$home" "$(basename "$shell")" "$groups"
  done < /etc/passwd
}

# ---------- 动作分发 ----------
mod_user_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_user_help; return 1; }
  shift || true

  case "$action" in
    add)     user__add "$@" ;;
    del)     user__del "$@" ;;
    passwd)  user__passwd "$@" ;;
    sudo)    user__sudo "$@" ;;
    list)    user__list ;;
    *)
      err "未知动作: user ${action}"
      mod_user_help
      return 1
      ;;
  esac
}

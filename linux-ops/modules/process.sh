#!/usr/bin/env bash
# ==============================================================================
# lops 模块: process — 进程与端口排查
# ==============================================================================

mod_process_desc() {
  echo "进程端口排查（资源Top10/端口占用/终止进程/僵尸/进程树）"
}

mod_process_actions() {
  cat <<'EOF'
top|CPU/内存占用 Top10（着色标注）
port|端口占用查询（全表或按端口过滤，给出进程与 PID）
kill|按端口或名称终止进程（先展示后确认，TERM 可选升级 KILL）
zombies|僵尸进程查找及父进程处理建议
tree|进程树展示（pstree -p 截取关键层）
EOF
}

mod_process_help() {
  cat <<'EOF'
lops process — 进程与端口排查
==============================================================================
"机器慢了谁在吃资源、端口被谁占了、进程杀不死怎么办" —— 五个动作覆盖
进程排查的日常场景。查询类全部只读；终止类先展示后确认，绝不盲杀。

用法:
  ./lops.sh process <action> [参数]

动作说明:
  top      CPU / 内存占用 Top10（ps 排序，着色标注）:
             - CPU >=90% 红色 / >=50% 黄色 / 其余绿色
             - %CPU 是进程启动以来的平均值（非实时），瞬时高峰请用 htop
  port     端口占用查询（TCP+UDP 监听端口，给出进程与 PID）:
             - 无参数: 列出全部监听端口（ss -tulnp 全表）
             - 带参数: 只看指定端口，精确匹配（如 port 8080）
             - 非 root 只能看到自己进程的名字与 PID，建议 sudo
  kill     按端口或名称终止进程（纯数字按端口，其余按进程名）:
             流程: 匹配并展示进程清单 → 二次确认 → kill -TERM（礼貌
             请求退出）→ 等 2 秒 → 仍存活则询问是否 kill -KILL（强杀）
             自动剔除 lops 自身进程; 对 bash/sshd 等关键系统进程名
             额外警告，防止误杀所有会话
  zombies  僵尸进程查找（进程状态为 Z）及父进程提示:
             僵尸 = 已退出的进程，但"档案"（进程表项）还没被父进程回收，
             不占 CPU/内存、只占一条 PID 记录; 少量无害，持续增长说明
             父程序有 bug（没调用 wait 收尸）。结尾给出按序处理建议。
  tree     进程树展示（pstree -p 截取关键层）:
             - 无参数: 全系统进程树的前 45 行（带 PID）
             - 带参数: 指定 PID 的完整子树（如 tree 1 看 systemd 全家谱）
             - pstree 缺失时自动回退 ps --forest（并提示安装 psmisc）

示例:
  ./lops.sh process top             # 机器卡，先看谁在吃资源
  ./lops.sh process port 8080       # 端口冲突/被占，查是谁
  ./lops.sh process port            # 全表浏览监听端口
  sudo ./lops.sh process kill 8080  # 按端口终止（TERM → 可选 KILL）
  ./lops.sh process kill nginx      # 按进程名终止
  ./lops.sh process zombies         # 僵尸进程排查
  ./lops.sh process tree 1          # 从 PID 1 看进程全树

前置条件:
  - top / port / zombies / tree 只读，普通用户可执行
  - port / kill 涉及"别人的"进程时需要 root（否则看不到或杀不掉）
  - tree 的 pstree 依赖 psmisc 包（缺失自动回退，体验略降）

注意事项:
  - 信号通俗理解: TERM(15) = "请你退出"（程序可保存数据后体面退出）;
    KILL(9) = "立即消失"（程序没机会保存，可能丢数据）。永远先 TERM。
  - kill 按进程名使用精确匹配（pgrep -x）; 内核中进程名最长 15 字符，
    超长会被截断，输入名字时不要超过 15 个字符（Java 应用通常叫 java）
  - D 状态（不可中断休眠，多在等磁盘 IO）的进程连 KILL 都杀不掉，
    只能修复底层 IO 问题或重启机器
  - 杀进程前先想"为什么杀": 正常停服务用 systemctl stop <服务名>;
    本模块适用于失控进程、残留进程等无法正常停止的场景
EOF
}

# ==============================================================================
# top — CPU/内存占用 Top10
# ==============================================================================

process__top() {
  banner "lops process top — CPU/内存占用 Top10"

  section "CPU 占用 Top10"
  # %CPU 为进程启动以来的平均值; --sort=-%cpu 按百分比降序
  # awk 全量读取再截取行（不用 head，避免 pipefail 下 SIGPIPE 提前退出）
  ps -eo pid,user,%cpu,%mem,rss,comm --sort=-%cpu | \
    awk -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v bold="$BOLD" -v nc="$NC" '
      NR==1 {
        printf "%s%-8s %-10s %6s %6s %10s  %s%s\n", bold, "PID", "USER", "%CPU", "%MEM", "RSS(MB)", "COMMAND", nc
        next
      }
      NR<=11 {
        if ($3+0 >= 90)      c=red
        else if ($3+0 >= 50) c=yellow
        else                 c=green
        printf "%-8s %-10s %s%6s%s %6s %10.1f  %s\n", $1, $2, c, $3, nc, $4, $5/1024, $6
      }'

  echo ""
  section "内存占用 Top10"
  # 按常驻内存 RSS 降序（-rss），同时给出 %MEM
  ps -eo pid,user,%cpu,%mem,rss,comm --sort=-rss | \
    awk -v green="$GREEN" -v yellow="$YELLOW" -v red="$RED" -v bold="$BOLD" -v nc="$NC" '
      NR==1 {
        printf "%s%-8s %-10s %6s %6s %10s  %s%s\n", bold, "PID", "USER", "%CPU", "%MEM", "RSS(MB)", "COMMAND", nc
        next
      }
      NR<=11 {
        if ($5+0 >= 1048576)      c=red      # >1GB
        else if ($5+0 >= 524288)  c=yellow   # >512MB
        else                      c=green
        printf "%-8s %-10s %6s %s%6s%s %10.1f  %s\n", $1, $2, $3, c, $4, nc, $5/1024, $6
      }'
  echo ""
  log "说明: %CPU 为进程启动以来的平均值; 单看实时高峰可用 top / htop"
}

# ==============================================================================
# port — 端口占用查询
# ==============================================================================

process__port() {
  local port="${1:-}"
  require_cmd ss || return 1

  if [[ -n "$port" ]]; then
    # 按端口精确过滤
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
      err "端口号需为数字: ${port}"
      return 1
    fi
    section "端口 ${port} 占用情况（TCP+UDP 监听）"
    # $5 为 Local Address:Port 列; 正则 ":端口$" 做结尾精确匹配
    # （避免查 80 时匹配到 8080）
    local out
    out="$(ss -tulnp 2>/dev/null | awk -v p=":${port}$" 'NR==1 || $5 ~ p' || true)"
    if [[ -n "$(printf '%s' "$out" | awk 'NR>1')" ]]; then
      echo "$out"
      echo ""
      log "读表: Local Address:Port 为监听地址与端口（0.0.0.0/:: = 所有网卡）"
      log "      Process 列格式 进程名(pid=PID)，即占用该端口的进程"
    else
      mark_ok "端口 ${port} 当前无监听"
    fi
  else
    section "全部监听端口（TCP+UDP）"
    ss -tulnp
    echo ""
    log "读表: State 列 LISTEN 为 TCP 监听; UNCONN 为 UDP（无连接概念）"
    log "      Process 列为空通常是权限不足看不到他人进程，可 sudo 重试"
  fi

  if [[ "${EUID}" -ne 0 ]]; then
    warn "非 root 仅能看到自己进程的进程名/PID，建议 sudo 执行获取完整视图"
  fi
}

# ==============================================================================
# kill — 按端口或名称终止进程
# ==============================================================================

process__kill() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    err "用法: lops.sh process kill <端口号|进程名>"
    err "示例: lops.sh process kill 8080    # 按端口终止"
    err "      lops.sh process kill nginx    # 按进程名终止"
    return 1
  fi

  local pids=() matched_desc=""
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    # ---- 纯数字: 按端口定位进程 ----
    require_cmd ss || return 1
    if (( target < 1 || target > 65535 )); then
      err "无效端口号: ${target}（应为 1-65535）"
      return 1
    fi
    local listen
    listen="$(ss -tlnp "sport = :${target}" 2>/dev/null || true)"
    # 注意: ss 无匹配时仍输出表头行，须过滤表头后再判断是否真的在监听
    if [[ -z "$(printf '%s' "$listen" | awk 'NR>1')" ]]; then
      mark_ok "端口 ${target} 无 TCP 监听进程"
      return 0
    fi
    echo "$listen"
    # 从 users:(("nginx",pid=890,fd=6)) 中提取 pid
    local pid
    while read -r pid; do
      [[ -n "$pid" ]] && pids+=("$pid")
    done < <(printf '%s\n' "$listen" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    if (( ${#pids[@]} == 0 )); then
      err "端口 ${target} 在监听但拿不到 PID（通常需要 root 权限），请 sudo 重试"
      return 1
    fi
    matched_desc="端口 ${target}"
  else
    # ---- 非数字: 按进程名精确匹配 ----
    require_cmd pgrep || return 1
    case "$target" in
      bash|sh|zsh|sshd|systemd|sudo|su|init)
        warn "${target} 为关键系统进程名，可能匹配到所有会话/系统进程，请仔细核对下方清单!"
        ;;
    esac
    local pid
    while read -r pid; do
      [[ -n "$pid" ]] && pids+=("$pid")
    done < <(pgrep -x -- "$target" || true)
    if (( ${#pids[@]} == 0 )); then
      mark_ok "未找到名为 ${target} 的进程"
      return 0
    fi
    matched_desc="进程名 ${target}"
  fi

  # 防误杀: 剔除 lops 自身进程（当前 shell 与其父进程）
  local self_pid=$$ self_ppid=$PPID filtered=() p
  for p in "${pids[@]}"; do
    [[ "$p" == "$self_pid" || "$p" == "$self_ppid" ]] && continue
    filtered+=("$p")
  done
  if (( ${#filtered[@]} == 0 )); then
    warn "匹配到的均为当前脚本自身相关进程，已跳过"
    return 0
  fi

  # 展示匹配进程，人工核对后再确认
  section "匹配进程（${matched_desc}）"
  ps -o pid,user,etime,%cpu,%mem,args -p "$(IFS=,; echo "${filtered[*]}")"

  echo ""
  if ! confirm "确认向以上 ${#filtered[@]} 个进程发送 TERM 信号（礼貌退出请求）?"; then
    log "已取消，未发送任何信号"
    return 0
  fi

  kill -TERM "${filtered[@]}" 2>/dev/null \
    || warn "部分进程终止失败（可能权限不足），可 sudo 重试"
  sleep 2

  # 存活复查
  local alive=()
  for p in "${filtered[@]}"; do
    if kill -0 "$p" 2>/dev/null; then
      alive+=("$p")
    fi
  done
  if (( ${#alive[@]} == 0 )); then
    mark_ok "全部进程已终止（TERM）"
    return 0
  fi

  warn "以下进程仍存活: $(IFS=' '; echo "${alive[*]}")（可能正在收尾，或忽略 TERM）"
  if confirm "是否升级为 KILL 信号强制终止?（强杀，进程无机会保存数据）"; then
    kill -KILL "${alive[@]}" 2>/dev/null || { err "KILL 发送失败（权限不足?）"; return 1; }
    sleep 1
    local rest=()
    for p in "${alive[@]}"; do
      if kill -0 "$p" 2>/dev/null; then
        rest+=("$p")
      fi
    done
    if (( ${#rest[@]} == 0 )); then
      mark_ok "已全部强制终止（KILL）"
    else
      err "仍未能终止: $(IFS=' '; echo "${rest[*]}")（可能为 D 状态进程，只能修复 IO 或重启）"
    fi
  else
    log "保留存活进程，未发送 KILL（稍后可重跑观察）"
  fi
}

# ==============================================================================
# zombies — 僵尸进程查找
# ==============================================================================

process__zombies() {
  banner "lops process zombies — 僵尸进程排查"

  local zcnt
  # STAT 首列为 Z 即僵尸（已退出、未被父进程回收）
  zcnt="$(ps -eo stat | grep -c '^Z' || true)"
  if (( zcnt == 0 )); then
    mark_ok "当前无僵尸进程"
    return 0
  fi

  mark_bad "发现 ${zcnt} 个僵尸进程"
  echo ""
  ps -eo pid,ppid,user,stat,etime,comm | awk 'NR==1 || $4 ~ /^Z/'

  # 僵尸的处理钥匙在其父进程手里
  echo ""
  section "僵尸进程的父进程（应由其负责回收）"
  local parents p
  parents="$(ps -eo ppid,stat | awk '$2 ~ /^Z/ {print $1}' | sort -u)"
  while read -r p; do
    [[ -z "$p" ]] && continue
    ps -p "$p" -o pid,user,comm,args --no-headers 2>/dev/null || true
  done <<<"$parents"

  echo ""
  log "僵尸进程 = 已退出但进程表项未被父进程回收（不占 CPU/内存，只占 PID 记录）"
  log "少量僵尸无害; 数量持续增长说明父程序有 bug（未调用 wait 回收子进程）"
  log "处理建议（按顺序尝试）:"
  echo "  1. kill -s SIGCHLD <父PID>   # 礼貌提醒父进程收尸（多数程序不响应）"
  echo "  2. 重启父进程所属服务         # 根治: systemctl restart <服务名>"
  echo "  3. 最后手段: 终止父进程       # 僵尸将由 init(PID 1)/systemd 接管回收"
}

# ==============================================================================
# tree — 进程树展示
# ==============================================================================

process__tree() {
  local pid="${1:-}"

  if [[ -n "$pid" ]]; then
    # 展示指定 PID 的完整子树
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
      err "PID 需为数字: ${pid}"
      return 1
    fi
    if ! ps -p "$pid" >/dev/null 2>&1; then
      err "进程 ${pid} 不存在"
      return 1
    fi
    section "进程 ${pid} 子树"
    if command -v pstree >/dev/null 2>&1; then
      pstree -p "$pid" || true
    else
      warn "pstree 未安装（psmisc 包），仅显示该进程与直接子进程"
      ps -o pid,ppid,user,comm --forest -p "$pid" --ppid "$pid" 2>/dev/null || true
      log "完整子树请安装: yum install psmisc 或 apt install psmisc"
    fi
    return 0
  fi

  section "进程树（全系统，截取前 45 行）"
  if command -v pstree >/dev/null 2>&1; then
    # awk 全量读取再截取（避免 head 提前关管道触发 SIGPIPE/141）
    pstree -p | awk 'NR<=45'
    echo ""
    log "已截取前 45 行; 查看完整树: pstree -p | less"
    log "深入某个进程的子树: lops.sh process tree <PID>（如 tree 1 看 systemd 全家谱）"
  else
    warn "pstree 未安装（psmisc 包），回退 ps --forest 展示前 60 行"
    ps -ef --forest | awk 'NR<=60'
    log "体验更佳请安装: yum install psmisc 或 apt install psmisc"
  fi
}

# ==============================================================================
# 动作分发
# ==============================================================================

mod_process_run() {
  local action="${1:-}"
  [[ -z "$action" ]] && { mod_process_help; return 1; }
  shift || true

  case "$action" in
    top)     process__top ;;
    port)    process__port "$@" ;;
    kill)    process__kill "$@" ;;
    zombies) process__zombies ;;
    tree)    process__tree "$@" ;;
    *)
      err "未知动作: process ${action}"
      mod_process_help
      return 1
      ;;
  esac
}

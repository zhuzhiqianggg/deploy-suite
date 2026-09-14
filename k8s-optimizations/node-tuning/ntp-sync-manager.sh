#!/bin/bash
# ============================================================================
# ntp-sync-manager.sh — Kubernetes 集群 NTP 时间同步 检查/一键修复 脚本
# ============================================================================
# 用途: 在 master01(可免密 SSH 所有节点)上运行, 对集群全部 Ready 节点:
#   check: 检查时间同步状态, 输出逐节点报告(只读, 不做任何变更)
#   fix  : 检查 + 一键修复(安装 chrony / 统一配置 / 纠偏 / 排除干扰项)
#
# 设计原则(踩坑记录见文件尾部):
#   1. NTP 源: 华为云为主(ntp.myhuaweicloud.com), 阿里云/腾讯为辅, 自动探测
#   2. 逐节点串行操作, 每台修复验证通过再处理下一台
#   3. 所有变更均有备份(*.ntpbak.*), 幂等可重复执行
#   4. 全部远端命令带超时, SSH 带重试(抗慢节点)
#   5. 本机节点直接本地执行(不走 SSH), 无需对本机配置免密
#   6. 时间同步健康的节点不强改配置(单源也算健康, 不强推多源);
#      仅"完全重配"(未装/旧版/服务挂/未同步/偏差大/源不可信)时统一多源
#
# 用法:
#   ./ntp-sync-manager.sh check              # 仅检查
#   ./ntp-sync-manager.sh fix                # 检查+修复
#   ./ntp-sync-manager.sh fix --user root    # 指定 SSH 用户(默认 root)
#
# 依赖: kubectl(节点发现), ssh/scp 免密, 节点为 Ubuntu(apt), 本机 python3
# 退出码: 0=全部正常  1=存在未修复问题  2=环境错误
# ============================================================================
set -u

SSH_USER="root"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes"
REMOTE_TIMEOUT=120
SSH_RETRY=3
SYNC_WAIT_MAX=150
OFFSET_OK_MS=100

NTP_CANDIDATES=(
  "ntp.myhuaweicloud.com"
  "ntp.aliyun.com"
  "ntp1.aliyun.com"
  "ntp2.aliyun.com"
  "ntp.tencent.com"
)
NTP_PICK=4

MODE="${1:-check}"
if [ "$MODE" != "check" ] && [ "$MODE" != "fix" ]; then
  echo "用法: $0 [check|fix] [--user USER]"; exit 2
fi
shift 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --user) SSH_USER="$2"; shift 2;;
    *) echo "未知参数: $1"; exit 2;;
  esac
done

log() { echo -e "$*"; }

ssh_node() {  # ssh_node <ip> <cmd> — 重试+超时
  local ip="$1" cmd="$2" i out
  for i in $(seq 1 $SSH_RETRY); do
    out=$(timeout $REMOTE_TIMEOUT ssh $SSH_OPTS "${SSH_USER}@${ip}" "$cmd" 2>/dev/null) && { echo "$out"; return 0; }
    sleep 3
  done
  return 1
}

scp_node() {  # scp_node <ip> <local> <remote>
  local ip="$1" l="$2" r="$3" i
  for i in $(seq 1 $SSH_RETRY); do
    timeout 60 scp -q $SSH_OPTS "$l" "${SSH_USER}@${ip}:$r" 2>/dev/null && return 0
    sleep 3
  done
  return 1
}

# 本机地址集合(用于识别"自己": 本机直接本地执行, 不绕 SSH, 无需对本机配免密)
LOCAL_IPS=$({ ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
             hostname -I 2>/dev/null | tr ' ' '\n'; } | grep -v '^$' | sort -u)

is_local() {  # is_local <ip> — 该 IP 是否本机
  local ip="$1"
  echo "$LOCAL_IPS" | grep -qx "$ip"
}

run_remote() {  # run_remote <ip> <cmd> — 本机 bash 直执行, 远端走 SSH(重试+超时)
  local ip="$1" cmd="$2"
  if is_local "$ip"; then bash -c "$cmd" 2>/dev/null; return $?; fi
  ssh_node "$ip" "$cmd"
}

copy_remote() {  # copy_remote <ip> <local> <remote> — 本机 cp, 远端 scp
  local ip="$1" l="$2" r="$3"
  if is_local "$ip"; then cp "$l" "$r" 2>/dev/null; return $?; fi
  scp_node "$ip" "$l" "$r"
}

# 内嵌 Python NTP 探测器: 独立向 NTP 服务器查询真实偏移(不依赖 chrony 自报)
NTP_PROBE_PY="/tmp/.ntp_probe.$$.py"
cat > "$NTP_PROBE_PY" <<'PYEOF'
import socket, struct, sys, time
SERVER = sys.argv[1]
DELTA = 2208988800
def query():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
    t0 = time.time()
    s.sendto(b'\x1b' + 47*b'\0', (SERVER, 123))
    data, _ = s.recvfrom(1024)
    t3 = time.time()
    f = struct.unpack('!12I', data)
    t1 = f[8] - DELTA + f[9]/2**32
    t2 = f[10] - DELTA + f[11]/2**32
    s.close()
    return ((t1-t0)+(t2-t3))/2, (t3-t0)-(t2-t1)
for _ in range(3):
    try:
        o, r = query()
        print(f"{o*1000:+.1f}|{r*1000:.0f}"); break
    except Exception:
        pass
else:
    print("FAIL|FAIL")
PYEOF

probe_ntp() { timeout 12 python3 "$NTP_PROBE_PY" "$1" 2>/dev/null; }

# ============================================================================
log "=================================================================="
log " NTP 时间同步管理  模式=$MODE  用户=$SSH_USER  $(date '+%F %T')"
log " 本机: $(hostname)"
log "=================================================================="

command -v kubectl >/dev/null || { log "❌ kubectl 不可用"; exit 2; }
command -v python3 >/dev/null || { log "❌ 本机缺 python3"; exit 2; }

NODES=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\t"}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
[ -z "$NODES" ] && { log "❌ 未发现任何节点"; exit 2; }

NODE_LIST=()
while IFS=$'\t' read -r ip name ready; do
  [ "$ready" = "True" ] && NODE_LIST+=("$name|$ip")
done <<< "$NODES"
log "发现 ${#NODE_LIST[@]} 个 Ready 节点"
log ""

# 阶段 1: NTP 源探测
log "---- 阶段 1: NTP 源探测(华为云优先, 不可达自动回退) ----"
NTP_SERVERS=()
for srv in "${NTP_CANDIDATES[@]}"; do
  res=$(probe_ntp "$srv")
  off=$(echo "$res" | cut -d'|' -f1); rtt=$(echo "$res" | cut -d'|' -f2)
  if [ "$off" != "FAIL" ] && [ "$rtt" != "FAIL" ]; then
    log "  ✓ $srv  可达  rtt=${rtt}ms"
    NTP_SERVERS+=("$srv")
  else
    log "  ✗ $srv  不可达(DNS/UDP123 被阻), 跳过"
  fi
  [ ${#NTP_SERVERS[@]} -ge $NTP_PICK ] && break
done
[ ${#NTP_SERVERS[@]} -eq 0 ] && { log "❌ 所有 NTP 候选源均不可达"; rm -f "$NTP_PROBE_PY"; exit 2; }
log "选定 ${#NTP_SERVERS[@]} 个源: ${NTP_SERVERS[*]}"
NTP_PRIMARY="${NTP_SERVERS[0]}"
EXPECTED_SRVS=$(for s in "${NTP_SERVERS[@]}"; do echo "$s"; done | sort | tr "\n" ",")

WORKDIR=$(mktemp -d /tmp/ntp-mgr.XXXXXX)
CONF_TARGET="$WORKDIR/chrony.conf"
{
  echo "# 由 ntp-sync-manager.sh 生成 $(date '+%F %T')"
  echo "# 架构: 全节点直连公共 NTP(多源互备, chrony 自动择优)"
  for s in "${NTP_SERVERS[@]}"; do echo "server $s iburst"; done
  echo "# 启动后前 3 次轮询内偏差>1s 直接步进校正, 之后仅平滑微调"
  echo "makestep 1.0 3"
  echo "driftfile /var/lib/chrony/chrony.drift"
  echo "rtcsync"
  echo "logdir /var/log/chrony"
} > "$CONF_TARGET"
log "目标配置已生成"
log ""

# ============================================================================
# 阶段 2: 逐节点检查与修复
# ============================================================================
log "---- 阶段 2: 逐节点$MODE ----"

RESULT_LINES=()
FIXED_NODES=()
FAIL_COUNT=0

check_one_node() {  # 参数: ip; 设置 STATUS/DETAIL
  local ip="$1" out
  STATUS="UNKNOWN"; DETAIL=""
  out=$(run_remote "$ip" '
    OS_CN=$(. /etc/os-release 2>/dev/null; echo $VERSION_CODENAME)
    VER=$(chronyd --version 2>/dev/null | grep -oE "version [0-9]+" | awk "{print \$2}")
    SVC=$(systemctl is-active chrony 2>/dev/null)
    SYNCED=$(chronyc sources 2>/dev/null | grep -c "^\^\*")
    OFF=$(chronyc tracking 2>/dev/null | awk "/System time/{gsub(/ .*/,\"\",\$4); printf \"%.0f\", \$4*1000}")
    VT=$(vmware-toolbox-cmd timesync status 2>/dev/null | head -1)
    [ -z "$VT" ] && VT="N/A"
    BAD=no
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
      [ -f "$f" ] || continue
      if grep -qE "focal|bionic|xenial" "$f" && ! grep -q "$OS_CN" "$f"; then BAD="$f"; break; fi
    done
    TSD=$(systemctl is-active systemd-timesyncd 2>/dev/null)
    SRVS=$(grep "^server " /etc/chrony/chrony.conf 2>/dev/null | awk "{print \$2}" | sort | tr "\n" ",")
    echo "$VER|$SVC|$SYNCED|${OFF:-NA}|$VT|$BAD|$TSD|$SRVS"')
  [ -z "$out" ] && { STATUS="SSH_FAIL"; DETAIL="SSH 连接失败"; return; }
  IFS='|' read -r VER SVC SYNCED OFF VT BAD TSD SRVS <<< "$(echo "$out" | head -1)"
  DETAIL="chrony=${VER:-未装} svc=$SVC sync=$SYNCED offset=${OFF}ms vmtools=$VT timesyncd=$TSD aptbad=$BAD srvs=${SRVS:-无}"

  # 判定原则: 时间同步健康(active + 已同步 + 偏差达标)即 OK,
  # 不因"只配了单源"判故障(尊重现状; 单源同步正常也是可用状态)
  if   [ "$VT" = "Enabled" ];  then STATUS="VMTOOLS_ON"
  elif [ "$BAD" != "no" ];     then STATUS="APT_MISMATCH"
  elif [ "$TSD" = "active" ];  then STATUS="TIMESYNCD_ON"
  elif [ -z "$VER" ];          then STATUS="NOT_INSTALLED"
  elif [[ "$VER" =~ ^[0-3]\. ]]; then STATUS="OLD_VERSION"
  elif [ "$SVC" != "active" ]; then STATUS="SVC_DOWN"
  elif ! python3 -c "exit(0 if abs(float('${OFF:-99999}')) < $OFFSET_OK_MS else 1)" 2>/dev/null; then STATUS="OFFSET_BIG"
  elif [ "$SYNCED" = "0" ] && [ "$OFF" = "NA" ]; then STATUS="NOT_SYNCED"
  else STATUS="OK"
  fi
}

wait_sync() {  # wait_sync <name> <ip> — 轮询等待 chrony 同步且偏差达标
  local name="$1" ip="$2" waited=0 ok=0 st synced offms
  log "  [$name] 等待同步(最长 ${SYNC_WAIT_MAX}s)..."
  while [ $waited -lt $SYNC_WAIT_MAX ]; do
    sleep 10; waited=$((waited+10))
    st=$(run_remote "$ip" 'chronyc sources 2>/dev/null | grep -c "^\^\*"; chronyc tracking 2>/dev/null | awk "/System time/{gsub(/ .*/,\"\",\$4); printf \"%.0f\", \$4*1000}"')
    synced=$(echo "$st" | sed -n 1p); offms=$(echo "$st" | sed -n 2p)
    if [ "${synced:-0}" -ge 1 ] 2>/dev/null; then
      if python3 -c "exit(0 if abs(int('${offms:-99999}')) < $OFFSET_OK_MS else 1)" 2>/dev/null; then ok=1; break; fi
    fi
    [ $((waited % 60)) -eq 0 ] && run_remote "$ip" 'chronyc makestep >/dev/null 2>&1' >/dev/null
  done
  if [ $ok -eq 1 ]; then log "  [$name] ✓ 已同步(${waited}s 收敛)"; return 0
  else log "  [$name] ⚠ 超时未收敛, 请稍后复查"; return 1; fi
}

fix_one_node() {  # 参数: name ip; 依赖全局 STATUS/VER/SRVS(check_one_node 所设)
  local name="$1" ip="$2"
  log "  >>> [$name] 修复: $STATUS"

  # 修复策略二选一:
  #   完全重配(full=yes): 时间真有问题(未装/旧版/服务挂/未同步/偏差大)
  #                       或现有源全不在候选集(不可信) → 统一多源模板
  #   轻修(full=no):     仅干扰项、时间本身健康 → 只关干扰项,
  #                       保留现有配置不重启服务(不扰动在跑的 chrony)
  local full=no _s _c has_cand=no
  case "$STATUS" in
    NOT_INSTALLED|OLD_VERSION|SVC_DOWN|NOT_SYNCED|OFFSET_BIG) full=yes;;
  esac
  [ -z "${VER:-}" ] && full=yes
  IFS=',' read -ra _fa <<< "${SRVS%,}"
  for _s in "${_fa[@]:-}"; do
    for _c in "${NTP_CANDIDATES[@]}"; do
      [ "$_s" = "$_c" ] && { has_cand=yes; break 2; }
    done
  done
  [ "$has_cand" = "no" ] && full=yes
  if [ "$full" = "yes" ]; then log "  [$name] 策略: 完全重配(统一多源模板)"
  else log "  [$name] 策略: 轻修(时间健康, 保留现有 NTP 源配置)"; fi

  # 2a. 修复 apt 源代号错配(focal 源跑在 jammy 系统等)
  if [ "$STATUS" = "APT_MISMATCH" ] || [ "$STATUS" = "NOT_INSTALLED" ] || [ "$STATUS" = "OLD_VERSION" ]; then
    log "  [$name] 检查/修正 apt 源代号..."
    run_remote "$ip" '
      CN=$(. /etc/os-release; echo $VERSION_CODENAME); TS=$(date +%Y%m%d-%H%M%S)
      for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] || continue
        if grep -qE "focal|bionic|xenial" "$f" && ! grep -q "$CN" "$f"; then
          cp "$f" "$f.ntpbak.$TS"; sed -i -E "s/(focal|bionic|xenial)/$CN/g" "$f"
          echo "    修正 $f → $CN (备份 $f.ntpbak.$TS)"
        fi
      done' | grep -v '^$'
  fi

  # 2b. 安装/升级 chrony(仅未装/旧版本)
  if [ "$STATUS" = "NOT_INSTALLED" ] || [ "$STATUS" = "OLD_VERSION" ]; then
    log "  [$name] 安装 chrony 4.x..."
    local inst
    inst=$(run_remote "$ip" '
      export DEBIAN_FRONTEND=noninteractive
      if ! timeout 100 apt-get install -y chrony >/tmp/.ntp_apt.log 2>&1; then
        timeout 150 apt-get update >>/tmp/.ntp_apt.log 2>&1 || {
          TS=$(date +%Y%m%d-%H%M%S)
          for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
            [ -f "$f" ] || continue
            if grep -qE "mirrors.aliyun.com|cn.archive.ubuntu.com|archive.ubuntu.com" "$f"; then
              cp "$f" "$f.ntpbak.$TS"
              sed -i -E "s#https?://(mirrors.aliyun.com|cn.archive.ubuntu.com|archive.ubuntu.com)#http://mirrors.tuna.tsinghua.edu.cn#g" "$f"
            fi
          done
          timeout 150 apt-get update >>/tmp/.ntp_apt.log 2>&1
        }
        timeout 100 apt-get install -y chrony >>/tmp/.ntp_apt.log 2>&1
      fi
      chronyd --version 2>/dev/null | grep -oE "version [0-9.]+([0-9]+)?"')
    if echo "$inst" | grep -q "version 4"; then
      log "  [$name] ✓ chrony 安装成功: $inst"
    else
      log "  [$name] ✗ chrony 安装失败(节点上 /tmp/.ntp_apt.log)"; return 1
    fi
  fi

  # 2c. 推送统一多源配置(仅完全重配时; 先比对, 不一致才覆盖并备份)
  if [ "$full" = "yes" ]; then
    local rmd5 lmd5
    rmd5=$(run_remote "$ip" 'md5sum /etc/chrony/chrony.conf 2>/dev/null | cut -d" " -f1')
    lmd5=$(md5sum "$CONF_TARGET" | cut -d" " -f1)
    if [ "$rmd5" != "$lmd5" ]; then
      run_remote "$ip" 'cp /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.ntpbak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null' >/dev/null
      copy_remote "$ip" "$CONF_TARGET" /etc/chrony/chrony.conf || { log "  [$name] ✗ 配置推送失败"; return 1; }
      log "  [$name] ✓ 配置已统一为多源(旧配置已备份 chrony.conf.ntpbak.*)"
    else
      log "  [$name] 配置一致, 跳过"
    fi
  fi

  # 2d. 排除干扰项(所有修复节点); driftfile 仅完全重配时清理(健康节点保留漂移系数)
  run_remote "$ip" '
    command -v vmware-toolbox-cmd >/dev/null 2>&1 && \
      vmware-toolbox-cmd timesync disable >/dev/null 2>&1 && \
      echo "    vmtools timesync → $(vmware-toolbox-cmd timesync status)"
    systemctl disable --now systemd-timesyncd >/dev/null 2>&1' | grep -v '^$'
  [ "$full" = "yes" ] && run_remote "$ip" 'rm -f /var/lib/chrony/chrony.drift' >/dev/null

  # 2e. 轻修路径: chrony 已 active 且已同步 → 不重启不扰动, 仅验证偏差达标
  if [ "$full" = "no" ]; then
    local svcnow offv
    svcnow=$(run_remote "$ip" 'systemctl is-active chrony 2>/dev/null; chronyc sources 2>/dev/null | grep -c "^\^\*"')
    if [ "$(echo "$svcnow" | sed -n 1p)" = "active" ] && [ "$(echo "$svcnow" | sed -n 2p)" -ge 1 ] 2>/dev/null; then
      offv=$(run_remote "$ip" 'chronyc tracking 2>/dev/null | awk "/System time/{gsub(/ .*/,\"\",\$4); printf \"%.0f\", \$4*1000}"')
      if python3 -c "exit(0 if abs(int('${offv:-99999}')) < $OFFSET_OK_MS else 1)" 2>/dev/null; then
        log "  [$name] ✓ chrony 正常(偏差 ${offv}ms), 未重启未改配置"
        return 0
      fi
      log "  [$name] 偏差 ${offv:-NA}ms 未达标, 升级为重启收敛"
    fi
  fi

  # 2f. 重启 chrony 并等待同步收敛
  run_remote "$ip" 'systemctl enable chrony >/dev/null 2>&1; systemctl restart chrony' || { log "  [$name] ✗ chrony 重启失败"; return 1; }
  wait_sync "$name" "$ip" || return 1
}

for entry in "${NODE_LIST[@]}"; do
  name="${entry%%|*}"; ip="${entry##*|}"
  check_one_node "$ip"
  if [ "$STATUS" = "OK" ]; then
    log "  [OK]      $name ($ip): $DETAIL"
    RESULT_LINES+=("OK|$name|$ip"); continue
  fi
  if [ "$STATUS" = "SSH_FAIL" ]; then
    log "  [SSHFAIL] $name ($ip)"
    FAIL_COUNT=$((FAIL_COUNT+1)); RESULT_LINES+=("SSHFAIL|$name|$ip"); continue
  fi
  log "  [NEEDFIX] $name ($ip): $STATUS ($DETAIL)"
  if [ "$MODE" = "fix" ]; then
    if fix_one_node "$name" "$ip"; then RESULT_LINES+=("FIXED|$name|$ip"); FIXED_NODES+=("$name|$ip")
    else FAIL_COUNT=$((FAIL_COUNT+1)); RESULT_LINES+=("FIXFAIL|$name|$ip"); fi
  else
    FAIL_COUNT=$((FAIL_COUNT+1)); RESULT_LINES+=("NEEDFIX|$name|$ip")
  fi
done

# 阶段 3(fix 模式): 独立 NTP 实测验证(仅本次实际修复过的节点, 健康节点不打扰)
if [ "$MODE" = "fix" ]; then
  log ""
  if [ ${#FIXED_NODES[@]} -eq 0 ]; then
    log "---- 阶段 3: 本次无修复节点, 跳过实测 ----"
  else
    log "---- 阶段 3: 独立 NTP 实测(对 $NTP_PRIMARY, 共 ${#FIXED_NODES[@]} 个修复节点) ----"
    for entry in "${FIXED_NODES[@]}"; do
      name="${entry%%|*}"; ip="${entry##*|}"
      copy_remote "$ip" "$NTP_PROBE_PY" /tmp/.ntp_probe.py >/dev/null 2>&1
      pass=0; off=""; res=""; round=0
      for round in 1 2 3; do
        res=$(run_remote "$ip" "timeout 15 python3 /tmp/.ntp_probe.py $NTP_PRIMARY" 2>/dev/null)
        off=$(echo "$res" | cut -d'|' -f1)
        if [ "$off" != "FAIL" ] && python3 -c "exit(0 if abs(float('$off')) < $OFFSET_OK_MS else 1)" 2>/dev/null; then
          log "  ✓ $name: 实测偏差 ${off}ms"; pass=1; break
        fi
        # 未达标: 触发步进后等待复测(兜住 vmtools 残留周期同步/慢收敛)
        log "  ⚠ $name: 第${round}轮实测 ${off}ms 未达标, 触发 makestep 30s 后复测..."
        run_remote "$ip" 'chronyc makestep >/dev/null 2>&1' >/dev/null
        sleep 30
      done
      [ $pass -eq 1 ] || { log "  ✗ $name: 3 轮实测均未达标"; FAIL_COUNT=$((FAIL_COUNT+1)); }
    done
  fi
fi

# 汇总
log ""
log "=================================================================="
log " 汇总: ${#NODE_LIST[@]} 节点"
for l in "${RESULT_LINES[@]}"; do
  IFS='|' read -r st name ip <<< "$l"
  case "$st" in
    OK)      mark="✓ 正常";;
    FIXED)   mark="✓ 本次已修复";;
    NEEDFIX) mark="✗ 需修复(执行: $0 fix)";;
    FIXFAIL) mark="✗ 修复失败(看上方日志)";;
    SSHFAIL) mark="✗ SSH 不通";;
    *)       mark="?";;
  esac
  log "   $mark  $name ($ip)"
done
log "=================================================================="
rm -rf "$WORKDIR" "$NTP_PROBE_PY"
if [ $FAIL_COUNT -eq 0 ]; then log "✅ 全部节点时间同步正常"; exit 0
else log "❌ $FAIL_COUNT 个节点存在问题"; exit 1; fi

# ============================================================================
# 踩坑记录(脚本已内置对应处理):
#  1. VMware Tools timesync 与 chrony 拉锯(时钟被拉回宿主机时间, 宿主机可偏10min+)
#  2. apt 源代号与系统不符(jammy 配 focal 源) → 装到 chrony 3.5, 5.15 内核
#     seccomp 下 SIGSYS core-dump
#  3. systemd-timesyncd 纠偏弱(≤500ppm), 秒级存量偏差修不动 → 换 chrony
#  4. driftfile 被时钟拉锯污染 → 修复时清理重建
#  5. 慢节点 SSH/apt 卡死 → 全部 timeout 包裹 + 重试
#  6. 华为云 NTP 仅 VPC 内可达(需内网 DNS 解析), 混合环境自动回退阿里云/腾讯
#  7. 本机走 SSH 反而失败(未对自己分发密钥) → 本机 IP 直接本地执行
#  8. 时间同步健康的节点不强推多源模板 → 仅"完全重配"场景才统一多源;
#     轻修(仅干扰项)只关干扰、不动配置、不重启在跑的 chrony
# ============================================================================

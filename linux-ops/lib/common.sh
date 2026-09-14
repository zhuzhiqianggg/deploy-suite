#!/usr/bin/env bash
# ==============================================================================
# lops 公共函数库
# 提供颜色输出、统一日志、OS 检测、权限校验、依赖检查、交互确认等基础能力。
# 所有 modules/*.sh 与 lops.sh 共享本文件，模块内不要重复实现。
# ==============================================================================

# ---------- 颜色（非终端输出时自动禁用） ----------
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' NC=''
fi

# ---------- 统一日志 ----------
LOPS_LOG_DIR="${LOPS_LOG_DIR:-/var/log/lops}"

_lops_write_log() {
  local level="$1"
  shift
  if mkdir -p "${LOPS_LOG_DIR}" 2>/dev/null && [[ -w "${LOPS_LOG_DIR}" ]]; then
    echo "[${level}] $(date '+%F %T') $*" >> "${LOPS_LOG_DIR}/lops.log"
  fi
}

log() {
  echo -e "${GREEN}[INFO]${NC} $*"
  _lops_write_log INFO "$*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
  _lops_write_log WARN "$*"
}

err() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  _lops_write_log ERROR "$*"
}

die() {
  err "$*"
  exit 1
}

# ---------- 版面输出 ----------
banner() {
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  printf "║ %-60s ║\n" "$1"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

section() {
  echo -e "\n${MAGENTA}${BOLD}── $* ──${NC}"
}

hr() {
  echo "----------------------------------------------------------------"
}

# ---------- 权限与依赖 ----------
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "此操作需要 root 权限，请使用 sudo 执行"
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    err "缺少依赖命令: ${cmd}"
    return 1
  fi
}

# ---------- OS 检测 ----------
# 结果变量: LOPS_OS_ID / LOPS_OS_VERSION / LOPS_PKG_MGR / LOPS_OS_FAMILY
detect_os() {
  if [[ -z "${LOPS_OS_ID:-}" ]]; then
    if [[ -f /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      LOPS_OS_ID="${ID:-unknown}"
      LOPS_OS_VERSION="${VERSION_ID:-unknown}"
    else
      die "无法识别当前操作系统（缺少 /etc/os-release）"
    fi
  fi

  case "${LOPS_OS_ID}" in
    ubuntu|debian)
      LOPS_PKG_MGR="apt"
      LOPS_OS_FAMILY="debian"
      ;;
    centos|rhel|rocky|almalinux|fedora|openEuler)
      # shellcheck disable=SC2034  # 结果变量，供调用方使用
      LOPS_PKG_MGR="yum"
      LOPS_OS_FAMILY="redhat"
      ;;
    *)
      die "暂不支持的发行版: ${LOPS_OS_ID}（支持 Ubuntu/Debian/CentOS/RHEL/Rocky/AlmaLinux）"
      ;;
  esac
  echo -e "${BLUE}[OS]${NC} ${LOPS_OS_ID} ${LOPS_OS_VERSION} (${LOPS_OS_FAMILY} 系)"
}

is_debian_family() { [[ "${LOPS_OS_FAMILY:-}" == "debian" ]]; }
is_redhat_family() { [[ "${LOPS_OS_FAMILY:-}" == "redhat" ]]; }

# 跨发行版软件包安装: pkg_install pkg1 [pkg2 ...]
pkg_install() {
  detect_os
  if is_debian_family; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y "$@"
  else
    yum install -y "$@"
  fi
}

# ---------- 交互 ----------
# 危险操作二次确认，输入 y/Y 才继续；默认拒绝
confirm() {
  local prompt="$1"
  local ans
  read -r -p "$(echo -e "${YELLOW}${prompt} [y/N]: ${NC}")" ans
  [[ "${ans}" =~ ^[Yy]$ ]]
}

# 交互式获取参数值: ask_value "提示" [默认值]
ask_value() {
  local prompt="$1" default="${2:-}"
  local input
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " input
    echo "${input:-$default}"
  else
    read -r -p "${prompt}: " input
    echo "$input"
  fi
}

# 生成随机密码（默认 20 位字母数字）
# 注意: 不能用 "tr < /dev/urandom | fold | head" 型无限流管道——
# pipefail 下 SIGPIPE(141) 会让整个脚本静默退出
gen_password() {
  local len="${1:-20}"
  local chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  local raw n out=""
  # head 按字节数读取后正常退出，od/tr 处理有限输入，全程无 SIGPIPE
  raw="$(head -c $(( len * 4 + 64 )) /dev/urandom | od -An -tu1 | tr -s ' \n' ' ')"
  for n in $raw; do
    out+="${chars:n % 62:1}"
    if (( ${#out} >= len )); then break; fi
  done
  printf '%s\n' "$out"
}

# ---------- 报表输出（提取自 os-hardware-info.sh / log_echo.sh，通用化） ----------
# 对齐键值输出: print_kv "CPU 核数" "16"
print_kv() {
  printf "  ${BOLD}%-24s${NC} %s\n" "$1:" "$2"
}

# 状态标记: mark_ok "正常" / mark_bad "异常" / mark_warn "警告"
mark_ok()   { echo -e "${GREEN}✓ $*${NC}"; }
mark_bad()  { echo -e "${RED}✘ $*${NC}"; }
mark_warn() { echo -e "${YELLOW}⚠ $*${NC}"; }

# 按阈值输出带颜色的百分比（<80 绿 / <90 黄 / >=90 红）
# 用法: pct_color 85
pct_color() {
  local p="$1"
  if (( $(echo "$p >= 90" | awk '{print ($1>=90)?1:0}') )); then
    echo -e "${RED}${p}%${NC}"
  elif (( $(echo "$p >= 80" | awk '{print ($1>=80)?1:0}') )); then
    echo -e "${YELLOW}${p}%${NC}"
  else
    echo -e "${GREEN}${p}%${NC}"
  fi
}

# 表格行: table_row "列1" "列2" ... （配合 table_header 使用，宽度自动对齐第一个参数列）
table_header() {
  echo -e "${BOLD}$*${NC}"
  hr
}

# ---------- 文件操作 ----------
# 修改系统文件前备份: backup_file /etc/fstab -> /etc/fstab.bak.20260901-120000
backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local bak
  bak="${f}.bak.$(date '+%Y%m%d-%H%M%S')"
  cp -a "$f" "$bak"
  log "已备份: ${f} -> ${bak}"
}

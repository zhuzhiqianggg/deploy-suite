#!/usr/bin/env bash
# 启用 kubectl 命令行自动补全功能
# 支持 bash 和 zsh

set -euo pipefail

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

if ! command -v kubectl >/dev/null 2>&1; then
  log "kubectl 未安装，跳过 autocompletion 配置"
  exit 0
fi

# 1. bash 自动补全
setup_bash_completion() {
  log "配置 bash 自动补全..."

  if ! grep -q "kubectl completion bash" /root/.bashrc 2>/dev/null; then
    cat >> /root/.bashrc <<'BASH_RC'

# kubectl bash completion
source <(kubectl completion bash)
alias k=kubectl
complete -F __start_kubectl k
BASH_RC
    log "已添加到 /root/.bashrc"
  else
    log "/root/.bashrc 已包含 kubectl completion"
  fi

  # 同时为所有用户配置
  if [[ -d /etc/bash_completion.d ]]; then
    kubectl completion bash > /etc/bash_completion.d/kubectl 2>/dev/null || true
    log "已生成 /etc/bash_completion.d/kubectl"
  fi
}

# 2. zsh 自动补全
setup_zsh_completion() {
  log "配置 zsh 自动补全..."

  if ! grep -q "kubectl completion zsh" /root/.zshrc 2>/dev/null; then
    cat >> /root/.zshrc <<'ZSH_RC'

# kubectl zsh completion
source <(kubectl completion zsh)
alias k=kubectl
ZSH_RC
    log "已添加到 /root/.zshrc"
  else
    log "/root/.zshrc 已包含 kubectl completion"
  fi
}

main() {
  log "========================================"
  log "配置 kubectl 自动补全"
  log "========================================"

  setup_bash_completion
  setup_zsh_completion

  log "========================================"
  log "完成"
  log "========================================"
  log "使用方式:"
  log "  - 重新登录或执行: source /root/.bashrc"
  log "  - 使用别名: k get pods"
  log "  - 完整命令: kubectl get pods [Tab]"
}

main "$@"

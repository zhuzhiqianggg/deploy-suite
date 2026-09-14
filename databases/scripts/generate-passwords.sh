#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 密码生成脚本 — 为所有数据库服务创建 K8s Secrets
#
# 用法: sudo bash generate-passwords.sh
#       sudo bash generate-passwords.sh --force   # 强制重建
#
# 生成的 Secrets (namespace: database):
#   db-secrets       — 通用密码集合
#   mysql-creds      — mysql-root-password, mysql-password, mysql-replication-password
#   redis-creds      — redis-password
#   kafka-creds      — kafka-password + SASL 全部凭证
#   kibana-creds     — kibana-password, es-username
#
# 同时导出到 ./passwords.env (source 即可在 shell 中使用)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_NS="database"
OUTPUT_ENV="$SCRIPT_DIR/passwords.env"
FORCE="${1:-}"

# —— 工具函数 ——
randpw() {
  # 生成 24 字符随机密码, 避免特殊字符 (K8s Secret 对大部分字符 OK, 但保守起见)
  tr -dc 'A-Za-z0-9_!@#%^&*+=.-' </dev/urandom | head -c 24 || true
  echo
}

ensure_ns() {
  kubectl get namespace "$K8S_NS" >/dev/null 2>&1 || {
    echo "[INFO] 创建 namespace: $K8S_NS"
    kubectl create namespace "$K8S_NS"
  }
}

# —— 检查是否已存在 ——
exists() { kubectl get secret "$1" -n "$K8S_NS" >/dev/null 2>&1; }

# —— 主流程 ——
ensure_ns

echo "==========================================="
echo "  数据库密码生成 (namespace: $K8S_NS)"
echo "  Force: ${FORCE:-no}"
echo "==========================================="

# ========= 1) db-secrets (通用) =========
if exists db-secrets && [[ "$FORCE" != "--force" ]]; then
  echo "[SKIP] db-secrets 已存在 (--force 可重建)"
else
  echo "[GEN ] db-secrets"
  DB_ROOT_PW="$(randpw)"
  DB_USER_PW="$(randpw)"
  DB_REPL_PW="$(randpw)"
  REDIS_PW="$(randpw)"
  KIBANA_PW="$(randpw)"
  ES_USER="elastic"
  KAFKA_CLIENT_PW="$(randpw)"
  KAFKA_IB_PW="$(randpw)"
  KAFKA_CTL_PW="$(randpw)"
  KAFKA_IB_SK="$(randpw)"
  KAFKA_CTL_SK="$(randpw)"
  KAFKA_GENERAL_PW="$(randpw)"
  RABBITMQ_PW="$(randpw)"
  MONGO_PW="$(randpw)"

  kubectl create secret generic db-secrets \
    -n "$K8S_NS" \
    --from-literal=db-root-password="$DB_ROOT_PW" \
    --from-literal=db-user-password="$DB_USER_PW" \
    --from-literal=db-replication-password="$DB_REPL_PW" \
    --from-literal=redis-password="$REDIS_PW" \
    --from-literal=elasticsearch-username="$ES_USER" \
    --from-literal=kibana-password="$KIBANA_PW" \
    --from-literal=kafka-password="$KAFKA_GENERAL_PW" \
    --from-literal=rabbitmq-password="$RABBITMQ_PW" \
    --from-literal=mongodb-password="$MONGO_PW" \
    --dry-run=client -o yaml | kubectl apply -f -

  # 把所有密码缓存到文件供后续使用
  cat > "$OUTPUT_ENV" <<EOF
# 自动生成 — $(date)
export DB_ROOT_PASSWORD="$DB_ROOT_PW"
export DB_USER_PASSWORD="$DB_USER_PW"
export DB_REPLICATION_PASSWORD="$DB_REPL_PW"
export REDIS_PASSWORD="$REDIS_PW"
export ELASTICSEARCH_USERNAME="$ES_USER"
export KIBANA_PASSWORD="$KIBANA_PW"
export KAFKA_PASSWORD="$KAFKA_GENERAL_PW"
export KAFKA_CLIENT_PASSWORD="$KAFKA_CLIENT_PW"
export KAFKA_IB_PASSWORD="$KAFKA_IB_PW"
export KAFKA_CTL_PASSWORD="$KAFKA_CTL_PW"
export KAFKA_IB_SECRET="$KAFKA_IB_SK"
export KAFKA_CTL_SECRET="$KAFKA_CTL_SK"
export RABBITMQ_PASSWORD="$RABBITMQ_PW"
export MONGODB_PASSWORD="$MONGO_PW"
EOF
  chmod 600 "$OUTPUT_ENV"
  echo "       已写入 $OUTPUT_ENV"
fi

# 加载缓存 (如果已有 db-secrets 存在则从 K8s 读取)
if [[ -f "$OUTPUT_ENV" ]]; then
  # shellcheck disable=SC1091
  source "$OUTPUT_ENV"
else
  # 从 K8s 中 db-secrets 读取
  echo "[INFO] 从已存在的 db-secrets 读取密码"
  DB_ROOT_PW="$(kubectl get secret db-secrets -n "$K8S_NS" -o jsonpath='{.data.db-root-password}' | base64 -d)"
  DB_USER_PW="$(kubectl get secret db-secrets -n "$K8S_NS" -o jsonpath='{.data.db-user-password}' | base64 -d)"
  DB_REPL_PW="$(kubectl get secret db-secrets -n "$K8S_NS" -o jsonpath='{.data.db-replication-password}' | base64 -d)"
  REDIS_PW="$(kubectl get secret db-secrets -n "$K8S_NS" -o jsonpath='{.data.redis-password}' | base64 -d)"
  ES_USER="$(kubectl get secret db-secrets -n "$K8S_NS" -o jsonpath='{.data.elasticsearch-username}' | base64 -d)"
  KIBANA_PW="$(kubectl get secret db-secrets -n "$K8S_NS" -o jsonpath='{.data.kibana-password}' | base64 -d)"
  KAFKA_GENERAL_PW="$(kubectl get secret db-secrets -n "$K8S_NS" -o jsonpath='{.data.kafka-password}' | base64 -d)"
  # Kafka SASL 专用密码如果没有单独生成, 复用 kafka-password
  KAFKA_CLIENT_PW="${KAFKA_CLIENT_PW:-$KAFKA_GENERAL_PW}"
  KAFKA_IB_PW="${KAFKA_IB_PW:-$KAFKA_GENERAL_PW}"
  KAFKA_CTL_PW="${KAFKA_CTL_PW:-$KAFKA_GENERAL_PW}"
  KAFKA_IB_SK="${KAFKA_IB_SK:-$KAFKA_GENERAL_PW}"
  KAFKA_CTL_SK="${KAFKA_CTL_SK:-$KAFKA_GENERAL_PW}"
fi

# ========= 2) mysql-creds =========
if exists mysql-creds && [[ "$FORCE" != "--force" ]]; then
  echo "[SKIP] mysql-creds 已存在"
else
  echo "[GEN ] mysql-creds  (mysql-root-password, mysql-password, mysql-replication-password)"
  kubectl create secret generic mysql-creds \
    -n "$K8S_NS" \
    --from-literal=mysql-root-password="${DB_ROOT_PW}" \
    --from-literal=mysql-password="${DB_USER_PW}" \
    --from-literal=mysql-replication-password="${DB_REPL_PW}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ========= 3) redis-creds =========
if exists redis-creds && [[ "$FORCE" != "--force" ]]; then
  echo "[SKIP] redis-creds 已存在"
else
  echo "[GEN ] redis-creds  (redis-password)"
  kubectl create secret generic redis-creds \
    -n "$K8S_NS" \
    --from-literal=redis-password="${REDIS_PW}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ========= 4) kafka-creds =========
# bitnami/kafka chart 的 sasl.existingSecret 需要的 keys:
#   client-passwords       (逗号分隔的 client 用户密码, 至少一个)
#   inter-broker-password
#   inter-broker-client-secret
#   controller-password
#   controller-client-secret
# 额外加 kafka-password 作为通用引用
if exists kafka-creds && [[ "$FORCE" != "--force" ]]; then
  echo "[SKIP] kafka-creds 已存在"
else
  echo "[GEN ] kafka-creds  (kafka-password + SASL 全部凭证)"
  kubectl create secret generic kafka-creds \
    -n "$K8S_NS" \
    --from-literal=kafka-password="${KAFKA_GENERAL_PW}" \
    --from-literal=client-passwords="${KAFKA_CLIENT_PW}" \
    --from-literal=inter-broker-password="${KAFKA_IB_PW}" \
    --from-literal=inter-broker-client-secret="${KAFKA_IB_SK}" \
    --from-literal=controller-password="${KAFKA_CTL_PW}" \
    --from-literal=controller-client-secret="${KAFKA_CTL_SK}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ========= 5) kibana-creds =========
# elastic 官方 chart 不支持 existingSecret, Kibana/ES 都用 extraEnvs 引用此 Secret
# keys: kibana-password, es-username (= elastic), es-password (如果开启 security)
if exists kibana-creds && [[ "$FORCE" != "--force" ]]; then
  echo "[SKIP] kibana-creds 已存在"
else
  echo "[GEN ] kibana-creds  (kibana-password, es-username)"
  kubectl create secret generic kibana-creds \
    -n "$K8S_NS" \
    --from-literal=kibana-password="${KIBANA_PW}" \
    --from-literal=es-username="${ES_USER}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ========= 汇总 =========
echo ""
echo "==========================================="
echo "  [OK] 密码生成完成"
echo "==========================================="
kubectl get secrets -n "$K8S_NS" -o wide 2>/dev/null | grep -E 'NAME|db-secrets|mysql-creds|redis-creds|kafka-creds|kibana-creds' || true
echo ""
echo "  使用示例:"
echo "    source $OUTPUT_ENV"
echo "    kubectl get secret mysql-creds -n $K8S_NS -o yaml"

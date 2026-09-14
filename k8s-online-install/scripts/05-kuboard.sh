#!/usr/bin/env bash
# ============================================================================
# 05 —— Kuboard v4 部署（K8s 多集群管理界面）
#
# 架构（v4 与 v3 不同：v4 用 MySQL 持久化，无需 etcd）：
#   - kuboard 命名空间自包含：kuboard + 内置 MySQL（配置全部内置于本命名空间）
#   - MySQL: mysql:8.4，数据落 NFS PVC
#   - kuboard: eipwork/kuboard:v4（官方镜像，arm64 已验证）
#     DB 连接信息通过 kuboard-config Secret 注入（DB_DRIVER/DB_URL/DB_USERNAME/DB_PASSWORD）
#   - Service NodePort 30080 对外
#
# 镜像来源：images-manager.sh sync → SWR → load2k8s 注入（打回官方名 docker.io/eipwork/kuboard:v4）
#           同步命令: bash /home/ubuntu/deploy/delivery-tools/images-manager.sh sync eipwork
#           注入命令: bash /home/ubuntu/deploy/delivery-tools/images-manager.sh load2k8s kuboard
#
# 首次登录: admin / Kuboard123（登录后立即改密）
# 导入集群: Kuboard 界面 → 添加集群 → 粘贴 /etc/kubernetes/admin.conf 内容
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPT_DIR}/../common.sh"

log_step "05. Kuboard v4 部署（内置 MySQL，NodePort 30080）"

check_root

# ── 1. 预拉镜像（走 SWR 注入的官方名本地镜像；拉不动不阻塞，等 load2k8s）──────
log_info "[1/4] 检查本地镜像..."
full_ref() {  # 短名 → kubelet 查找的完整引用
    case "$1" in */*) echo "docker.io/$1" ;; *) echo "docker.io/library/$1" ;; esac
}
KUBOARD_FULL_REF="$(full_ref "${KUBOARD_IMAGE}")"
MYSQL_FULL_REF="$(full_ref "${KUBOARD_MYSQL_IMAGE}")"
for pair in "${KUBOARD_FULL_REF}" "${MYSQL_FULL_REF}"; do
    if sudo ctr -n k8s.io images ls -q 2>/dev/null | grep -q "^${pair}$"; then
        log_ok "  本地已有: ${pair}"
    else
        log_warn "  本地缺失: ${pair}（需先执行 images-manager.sh sync + load2k8s，或等待自动拉取）"
    fi
done

# ── 2. 部署内置 MySQL（kuboard 命名空间，数据落 NFS）──────────────────────────
log_info "[2/4] 部署内置 MySQL（数据落 NFS PVC）..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: kuboard
---
apiVersion: v1
kind: Secret
metadata:
  name: kuboard-mysql-secret
  namespace: kuboard
type: Opaque
stringData:
  MYSQL_ROOT_PASSWORD: "${KUBOARD_MYSQL_ROOT_PASSWORD}"
  MYSQL_DATABASE: "kuboard"
  MYSQL_USER: "kuboard"
  MYSQL_PASSWORD: "${KUBOARD_MYSQL_PASSWORD}"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: kuboard-mysql-data
  namespace: kuboard
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: nfs-client
  resources:
    requests:
      storage: ${KUBOARD_MYSQL_STORAGE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kuboard-mysql
  namespace: kuboard
spec:
  replicas: 1
  strategy:
    type: Recreate          # NFS/单节点场景避免双挂
  selector:
    matchLabels:
      app: kuboard-mysql
  template:
    metadata:
      labels:
        app: kuboard-mysql
    spec:
      tolerations:
      - operator: Exists
      containers:
      - name: mysql
        image: ${KUBOARD_MYSQL_IMAGE}
        imagePullPolicy: IfNotPresent
        envFrom:
        - secretRef:
            name: kuboard-mysql-secret
        args:
        - --character-set-server=utf8mb4
        - --collation-server=utf8mb4_unicode_ci
        ports:
        - containerPort: 3306
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
        livenessProbe:
          exec:
            command: ["mysqladmin", "ping", "-h", "127.0.0.1", "-uroot", "-p\$(MYSQL_ROOT_PASSWORD)"]
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
        readinessProbe:
          exec:
            command: ["mysqladmin", "ping", "-h", "127.0.0.1", "-uroot", "-p\$(MYSQL_ROOT_PASSWORD)"]
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 5
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            cpu: "2"
            memory: 1Gi
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: kuboard-mysql-data
---
apiVersion: v1
kind: Service
metadata:
  name: kuboard-mysql
  namespace: kuboard
spec:
  type: ClusterIP
  selector:
    app: kuboard-mysql
  ports:
  - port: 3306
    targetPort: 3306
EOF

wait_for "MySQL Deployment Available" 300 5 \
    bash -c "kubectl -n kuboard get deployment kuboard-mysql -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' | grep -q True"

# ── 3. 部署 Kuboard v4 ──────────────────────────────────────────────────────
log_info "[3/4] 部署 Kuboard v4..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kuboard-config
  namespace: kuboard
type: Opaque
stringData:
  TZ: "Asia/Shanghai"
  DB_DRIVER: "com.mysql.cj.jdbc.Driver"
  DB_URL: "jdbc:mysql://kuboard-mysql.kuboard.svc.cluster.local:3306/kuboard?serverTimezone=Asia/Shanghai&useUnicode=true&characterEncoding=UTF-8&useSSL=false&allowPublicKeyRetrieval=true"
  DB_USERNAME: "kuboard"
  DB_PASSWORD: "${KUBOARD_MYSQL_PASSWORD}"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kuboard-v4
  namespace: kuboard
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kuboard-v4
  template:
    metadata:
      labels:
        app: kuboard-v4
    spec:
      tolerations:
      - operator: Exists
      containers:
      - name: kuboard
        image: ${KUBOARD_IMAGE}
        imagePullPolicy: IfNotPresent
        envFrom:
        - secretRef:
            name: kuboard-config
        ports:
        - containerPort: 80    # web
        - containerPort: 443   # web (TLS)
        readinessProbe:
          tcpSocket:
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: 80
          initialDelaySeconds: 60
          periodSeconds: 20
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            cpu: "2"
            memory: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: kuboard-v4
  namespace: kuboard
spec:
  type: NodePort
  selector:
    app: kuboard-v4
  ports:
  - name: web
    port: 80
    targetPort: 80
    nodePort: 30080
  - name: web-tls
    port: 443
    targetPort: 443
    nodePort: 30443
EOF

# ── 4. 等待就绪 + 输出访问信息 ────────────────────────────────────────────────
log_info "[4/4] 等待 Kuboard 就绪..."
wait_for "Kuboard Deployment Available" 300 5 \
    bash -c "kubectl -n kuboard get deployment kuboard-v4 -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' | grep -q True"

log_step "✅ Kuboard v4 部署完成"
log_info "访问地址:   http://${NODE_IP}:30080"
log_info "默认账号:   admin"
log_info "默认密码:   Kuboard123（登录后立即修改！）"
log_info "导入集群:   界面 → 添加集群 → 粘贴 /etc/kubernetes/admin.conf 内容"
log_info "内置 MySQL: kuboard-mysql.kuboard.svc:3306（库 kuboard，数据在 /data/nfs NFS PVC）"
kubectl get pods,svc -n kuboard

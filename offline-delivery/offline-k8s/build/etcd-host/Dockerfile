FROM docker.io/library/busybox:1.36 AS builder

# 复制所需的脚本和文件
COPY docker-entrypoint.sh /tmp/docker-entrypoint.sh
COPY audit-policy-once.yaml /tmp/audit-policy-once.yaml
RUN chmod +x /tmp/docker-entrypoint.sh

# 最终镜像: 基于 busybox (提供 shell) + etcd 二进制
FROM docker.io/library/busybox:1.36

# 复制 etcd 二进制从官方镜像
COPY --from=quay.io/coreos/etcd:v3.5.21 /usr/local/bin/etcd /usr/local/bin/etcd
COPY --from=quay.io/coreos/etcd:v3.5.21 /usr/local/bin/etcdctl /usr/local/bin/etcdctl

# 复制 entrypoint 和 audit 脚本
COPY --from=builder /tmp/docker-entrypoint.sh /docker-entrypoint.sh
COPY --from=builder /tmp/audit-policy-once.yaml /init-etcd-scripts/audit-policy-once.yaml

# 创建数据目录
RUN mkdir -p /data

# 暴露端口 (与 eipwork/etcd-host 一致)
EXPOSE 3381 3382

# 使用 docker-entrypoint.sh 启动 etcd (支持 ETCD_* 环境变量配置端口)
ENTRYPOINT ["/docker-entrypoint.sh"]

# 阶段 1: 从官方 etcd 镜像取出 etcd 二进制
FROM quay.io/coreos/etcd:v3.5.21 AS etcd-src

# 阶段 2: alpine 3.20 base
FROM docker.io/library/alpine:3.20

# 安装基础工具
RUN apk add --no-cache ca-certificates curl jq bash

# 从 etcd 镜像复制 etcd 二进制
COPY --from=etcd-src /usr/local/bin/etcd /usr/local/bin/etcd
COPY --from=etcd-src /usr/local/bin/etcdctl /usr/local/bin/etcdctl
COPY --from=etcd-src /usr/local/bin/etcdutl /usr/local/bin/etcdutl

# 启动脚本
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 3381 3382
ENTRYPOINT ["/docker-entrypoint.sh"]

#!/bin/sh
set -e

# eipwork/etcd-host 的入口逻辑
# 使用 fieldRef 注入的 HOSTIP, 端口从 env var 读取
HOST_IP=${HOSTIP:-127.0.0.1}
HOST_NAME=${HOSTNAME:-etcd}
CLIENT_PORT=${ETCD_CLIENT_PORT:-3381}
PEER_PORT=${ETCD_PEER_PORT:-3382}

# 数据目录
DATA_DIR=${DATA_DIR:-/data}
mkdir -p "$DATA_DIR"

# etcd 配置 - URL 在容器启动时动态构建
ETCD_DATA_DIR="$DATA_DIR"
ETCD_NAME=${ETCD_NAME:-${HOST_NAME}}
ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:${CLIENT_PORT}"
ETCD_ADVERTISE_CLIENT_URLS="http://${HOST_IP}:${CLIENT_PORT}"
ETCD_LISTEN_PEER_URLS="http://0.0.0.0:${PEER_PORT}"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${HOST_IP}:${PEER_PORT}"
ETCD_INITIAL_CLUSTER=${ETCD_INITIAL_CLUSTER:-${ETCD_NAME}=http://${HOST_IP}:${PEER_PORT}}
ETCD_INITIAL_CLUSTER_TOKEN=${ETCD_INITIAL_CLUSTER_TOKEN:-etcd-cluster}
ETCD_INITIAL_CLUSTER_STATE=${ETCD_INITIAL_CLUSTER_STATE:-new}

log() { echo "[$(date '+%F %T')] $*"; }

log "Starting etcd-host"
log "  Name: $ETCD_NAME"
log "  Data Dir: $ETCD_DATA_DIR"
log "  Host IP: $HOST_IP"
log "  Client Port: $CLIENT_PORT"
log "  Peer Port: $PEER_PORT"
log "  Listen Client: $ETCD_LISTEN_CLIENT_URLS"
log "  Listen Peer: $ETCD_LISTEN_PEER_URLS"
log "  Advertise Client: $ETCD_ADVERTISE_CLIENT_URLS"

# 启动 etcd
exec /usr/local/bin/etcd \
    --data-dir="$ETCD_DATA_DIR" \
    --name="$ETCD_NAME" \
    --listen-client-urls="$ETCD_LISTEN_CLIENT_URLS" \
    --advertise-client-urls="$ETCD_ADVERTISE_CLIENT_URLS" \
    --listen-peer-urls="$ETCD_LISTEN_PEER_URLS" \
    --initial-advertise-peer-urls="$ETCD_INITIAL_ADVERTISE_PEER_URLS" \
    --initial-cluster="$ETCD_INITIAL_CLUSTER" \
    --initial-cluster-token="$ETCD_INITIAL_CLUSTER_TOKEN" \
    --initial-cluster-state="$ETCD_INITIAL_CLUSTER_STATE" \
    --log-level=info \
    --logger=zap \
    --log-outputs=stderr

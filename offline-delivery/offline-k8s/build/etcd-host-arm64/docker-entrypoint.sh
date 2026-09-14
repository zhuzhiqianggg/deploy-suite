#!/bin/sh
set -e

CLIENT_PORT=${ETCD_CLIENT_PORT:-3381}
PEER_PORT=${ETCD_PEER_PORT:-3382}
HOST_IP=${HOSTIP:-127.0.0.1}
HOST_NAME=${HOSTNAME:-etcd}

mkdir -p /data

exec /usr/local/bin/etcd \
  --data-dir=/data \
  --name="${HOST_NAME}" \
  --listen-client-urls="http://0.0.0.0:${CLIENT_PORT}" \
  --advertise-client-urls="http://${HOST_IP}:${CLIENT_PORT}" \
  --listen-peer-urls="http://0.0.0.0:${PEER_PORT}" \
  --initial-advertise-peer-urls="http://${HOST_IP}:${PEER_PORT}" \
  --initial-cluster="${HOST_NAME}=http://${HOST_IP}:${PEER_PORT}" \
  --initial-cluster-token=etcd-cluster \
  --initial-cluster-state=new \
  --log-level=info \
  --logger=zap

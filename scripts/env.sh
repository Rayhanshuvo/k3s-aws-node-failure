#!/usr/bin/env bash
# Reads the Pulumi stack outputs and writes .env.mk (used by the Makefile) and ssh/config.
# Run it again after a worker is stopped and started: its PUBLIC IP changes (private IP stays).
set -euo pipefail
cd "$(dirname "$0")/.."
KEY_DIR="${KEY_DIR:-$PWD/infra}"

out() { (cd infra && pulumi stack output "$1"); }

NGINX_IP=$(out nginxPublicIp)
MASTER_IP=$(out masterPublicIp)
MASTER_PRIV=$(out masterPrivateIp)
WORKER1_IP=$(out worker1PublicIp)
WORKER1_PRIV=$(out worker1PrivateIp)
WORKER2_IP=$(out worker2PublicIp)
WORKER2_PRIV=$(out worker2PrivateIp)
WORKER2_ID=$(out worker2InstanceId)

cat > .env.mk <<MK
NGINX_IP=$NGINX_IP
MASTER_IP=$MASTER_IP
MASTER_PRIV=$MASTER_PRIV
WORKER1_PRIV=$WORKER1_PRIV
WORKER2_PRIV=$WORKER2_PRIV
WORKER2_ID=$WORKER2_ID
MK

sed -e "s#NGINX_IP#$NGINX_IP#" -e "s#MASTER_IP#$MASTER_IP#" \
    -e "s#WORKER1_IP#$WORKER1_IP#" -e "s#WORKER2_IP#$WORKER2_IP#" \
    -e "s#KEY_DIR#$KEY_DIR#" ssh/config.template > ssh/config

echo "Wrote .env.mk and ssh/config"
cat .env.mk

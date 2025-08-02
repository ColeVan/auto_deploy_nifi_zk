#!/bin/bash
set -euo pipefail
LOG_FILE="/var/log/nifi_deploy.log"
CONFIG_FILE="./cluster_config.env"

echo "$(date '+%F %T') | Configuring deployment mode..." | tee -a "$LOG_FILE"

read -rp "Is this a Single Node or Cluster deployment? (single/cluster): " DEPLOY_MODE

> "$CONFIG_FILE"  # Clear or create file
echo "DEPLOY_MODE=$DEPLOY_MODE" >> "$CONFIG_FILE"

if [[ "$DEPLOY_MODE" == "cluster" ]]; then
    read -rp "How many nodes in the cluster?: " NODE_COUNT
    echo "NODE_COUNT=$NODE_COUNT" >> "$CONFIG_FILE"

    for (( i=1; i<=NODE_COUNT; i++ )); do
        read -rp "Enter hostname for node $i: " NODE_HOST
        read -rp "Enter IP for node $i: " NODE_IP
        read -rp "Enter SSH username for $NODE_HOST: " NODE_USER
        echo "NODE_${i}_HOST=$NODE_HOST" >> "$CONFIG_FILE"
        echo "NODE_${i}_IP=$NODE_IP" >> "$CONFIG_FILE"
        echo "NODE_${i}_USER=$NODE_USER" >> "$CONFIG_FILE"
    done
else
    echo "NODE_COUNT=1" >> "$CONFIG_FILE"
    echo "NODE_1_HOST=$(hostname)" >> "$CONFIG_FILE"
    echo "NODE_1_IP=$(hostname -I | awk '{print $1}')" >> "$CONFIG_FILE"
    echo "NODE_1_USER=$(whoami)" >> "$CONFIG_FILE"
fi

echo "$(date '+%F %T') | ✅ Cluster configuration saved to $CONFIG_FILE" | tee -a "$LOG_FILE"

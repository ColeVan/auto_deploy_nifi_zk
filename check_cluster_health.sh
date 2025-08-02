#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/cluster_health.log"
CONFIG_FILE="./cluster_config.env"
ZOOKEEPER_DIR="/opt/zookeeper"
NIFI_DIR="/opt/nifi"

echo "$(date '+%F %T') | Starting Cluster Health Check with Auto-Restart..." | tee -a "$LOG_FILE"

# Ensure cluster config exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "$(date '+%F %T') | ❌ Cluster configuration not found. Run cluster_setup.sh first." | tee -a "$LOG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# Using SSH key-based authentication
echo "$(date '+%F %T') | 🔑 Using SSH key-based authentication" | tee -a "$LOG_FILE"

SERVER_IPS=()
SERVER_USERS=()
SERVER_HOSTS=()
for (( i=1; i<=NODE_COUNT; i++ )); do
    IP_VAR="NODE_${i}_IP"
    USER_VAR="NODE_${i}_USER"
    HOST_VAR="NODE_${i}_HOST"
    SERVER_IPS+=("${!IP_VAR}")
    SERVER_USERS+=("${!USER_VAR}")
    SERVER_HOSTS+=("${!HOST_VAR}")
done

# Function: Check and restart Zookeeper if needed
check_zookeeper_node() {
    local ip="$1"
    local user="$2"
    echo "🔍 Checking Zookeeper on $ip ..." | tee -a "$LOG_FILE"

    STATUS_OUTPUT=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "sudo $ZOOKEEPER_DIR/bin/zkServer.sh status" 2>&1 || true)
    echo "$STATUS_OUTPUT" | tee -a "$LOG_FILE"

    if ! echo "$STATUS_OUTPUT" | grep -q "Mode:"; then
        echo "⚠️ Zookeeper seems down on $ip. Attempting restart..." | tee -a "$LOG_FILE"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "sudo systemctl restart zookeeper"
        sleep 5
        STATUS_OUTPUT=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "sudo $ZOOKEEPER_DIR/bin/zkServer.sh status" 2>&1 || true)
        echo "$STATUS_OUTPUT" | tee -a "$LOG_FILE"
    else
        echo "✅ Zookeeper is running on $ip" | tee -a "$LOG_FILE"
    fi
}

# Function: Check and restart NiFi if needed
check_nifi_node() {
    local ip="$1"
    local user="$2"
    echo "🔍 Checking NiFi on $ip ..." | tee -a "$LOG_FILE"

    STATUS_OUTPUT=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "sudo $NIFI_DIR/bin/nifi.sh status" 2>&1 || true)
    echo "$STATUS_OUTPUT" | tee -a "$LOG_FILE"

    if ! echo "$STATUS_OUTPUT" | grep -q "Status: UP"; then
        echo "⚠️ NiFi is NOT UP on $ip. Attempting restart..." | tee -a "$LOG_FILE"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "sudo systemctl restart nifi"
        sleep 10
        STATUS_OUTPUT=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "sudo $NIFI_DIR/bin/nifi.sh status" 2>&1 || true)
        echo "$STATUS_OUTPUT" | tee -a "$LOG_FILE"
        if echo "$STATUS_OUTPUT" | grep -q "Status: UP"; then
            echo "✅ NiFi restarted successfully on $ip" | tee -a "$LOG_FILE"
        else
            echo "❌ NiFi failed to start on $ip" | tee -a "$LOG_FILE"
        fi
    else
        echo "✅ NiFi is UP on $ip" | tee -a "$LOG_FILE"
    fi
}

# --- Zookeeper Checks ---
echo "$(date '+%F %T') | ===== Checking Zookeeper Cluster =====" | tee -a "$LOG_FILE"
for (( i=1; i<=NODE_COUNT; i++ )); do
    check_zookeeper_node "${SERVER_IPS[i-1]}" "${SERVER_USERS[i-1]}"
done

# --- NiFi Checks ---
echo "$(date '+%F %T') | ===== Checking NiFi Cluster =====" | tee -a "$LOG_FILE"
for (( i=1; i<=NODE_COUNT; i++ )); do
    check_nifi_node "${SERVER_IPS[i-1]}" "${SERVER_USERS[i-1]}"
done

echo "$(date '+%F %T') | ✅ Cluster health check with auto-restart completed." | tee -a "$LOG_FILE"

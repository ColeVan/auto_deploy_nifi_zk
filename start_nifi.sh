#!/bin/bash
set -euo pipefail
LOG_FILE="/var/log/nifi_deploy.log"
NIFI_DIR="/opt/nifi"
MAX_RETRIES=30
SLEEP_TIME=5

echo "$(date '+%Y-%m-%d %H:%M:%S') | Starting NiFi..." | tee -a "$LOG_FILE"

sudo ufw allow 8443/tcp
sudo $NIFI_DIR/bin/nifi.sh start
sleep 10

# === Health Check using native status ===
echo "$(date '+%Y-%m-%d %H:%M:%S') | Checking NiFi process status..." | tee -a "$LOG_FILE"

for ((i=1; i<=MAX_RETRIES; i++)); do
    STATUS_OUTPUT=$(sudo $NIFI_DIR/bin/nifi.sh status || true)

    if echo "$STATUS_OUTPUT" | grep -q "Status: UP"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | ✅ NiFi reported as UP" | tee -a "$LOG_FILE"
        echo "$STATUS_OUTPUT" | tee -a "$LOG_FILE"
        exit 0
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') | Waiting for NiFi... Attempt $i/$MAX_RETRIES" | tee -a "$LOG_FILE"
    sleep $SLEEP_TIME
done

echo "$(date '+%Y-%m-%d %H:%M:%S') | ❌ NiFi did not report 'Status: UP' after $((MAX_RETRIES * SLEEP_TIME)) seconds." | tee -a "$LOG_FILE"
sudo $NIFI_DIR/bin/nifi.sh status || true
exit 1

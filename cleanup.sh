#!/bin/bash
set -euo pipefail
LOG_FILE="/var/log/nifi_deploy.log"
NIFI_DIR="/opt/nifi"
CERT_DIR="/opt/nifi-certs"

echo "$(date '+%Y-%m-%d %H:%M:%S') | Cleaning old NiFi installation..." | tee -a "$LOG_FILE"

# Stop NiFi if it exists
if [[ -x "$NIFI_DIR/bin/nifi.sh" ]]; then
    sudo "$NIFI_DIR/bin/nifi.sh" stop || true
fi

# Remove old installation and certs
sudo rm -rf "$NIFI_DIR" "$CERT_DIR"

# Safely remove JAVA_HOME and PATH entries from user's bashrc
USER_HOME=$(eval echo ~$SUDO_USER)
sudo sed -i '/JAVA_HOME/d' "$USER_HOME/.bashrc"
sudo sed -i '/PATH=\$PATH:\$JAVA_HOME\/bin/d' "$USER_HOME/.bashrc"

echo "$(date '+%Y-%m-%d %H:%M:%S') | Cleanup complete." | tee -a "$LOG_FILE"

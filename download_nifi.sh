#!/bin/bash
set -euo pipefail
LOG_FILE="/var/log/nifi_deploy.log"
NIFI_DIR="/opt/nifi"

VERSION="$1"
URL="https://dlcdn.apache.org/nifi/${VERSION}/nifi-${VERSION}-bin.zip"

echo "$(date '+%Y-%m-%d %H:%M:%S') | Downloading NiFi $VERSION..." | tee -a "$LOG_FILE"
wget -q "$URL" -O nifi.zip || { echo "Download failed" | tee -a "$LOG_FILE"; exit 1; }
unzip -q nifi.zip
sudo mkdir -p "$NIFI_DIR"
sudo cp -r nifi-*/. "$NIFI_DIR/"
rm -rf nifi-* nifi.zip
sudo chmod -R 755 "$NIFI_DIR"

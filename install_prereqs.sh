#!/bin/bash
set -euo pipefail
LOG_FILE="/var/log/nifi_deploy.log"
JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64"

echo "$(date '+%Y-%m-%d %H:%M:%S') | Installing prerequisites..." | tee -a "$LOG_FILE"
sudo apt-get update -y
sudo apt-get install -y openjdk-21-jdk unzip wget ufw jq openssl

if ! grep -q "JAVA_HOME=" ~/.bashrc; then
    echo "export JAVA_HOME=$JAVA_HOME" >> ~/.bashrc
    echo "export PATH=\\$PATH:\\$JAVA_HOME/bin" >> ~/.bashrc
fi

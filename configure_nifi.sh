#!/bin/bash
set -euo pipefail
LOG_FILE="/var/log/nifi_deploy.log"
CERT_DIR="/opt/nifi-certs"
NIFI_DIR="/opt/nifi"

source "$CERT_DIR/passwords.env"
HOST=$(hostname)
CERT_PATH="$CERT_DIR/$HOST"
CONFIG_FILE="$NIFI_DIR/conf/nifi.properties"

echo "$(date '+%Y-%m-%d %H:%M:%S') | Configuring NiFi properties..." | tee -a "$LOG_FILE"

sudo sed -i "s|nifi.web.https.host=.*|nifi.web.https.host=$HOST|" "$CONFIG_FILE"
sudo sed -i "s|nifi.security.keystore=.*|nifi.security.keystore=${CERT_PATH}/keystore.jks|" "$CONFIG_FILE"
sudo sed -i "s|nifi.security.keystoreType=.*|nifi.security.keystoreType=jks|" "$CONFIG_FILE"
sudo sed -i "s|nifi.security.keystorePasswd=.*|nifi.security.keystorePasswd=$KEYSTORE_PASS|" "$CONFIG_FILE"
sudo sed -i "s|nifi.security.keyPasswd=.*|nifi.security.keyPasswd=$KEYSTORE_PASS|" "$CONFIG_FILE"
sudo sed -i "s|nifi.security.truststore=.*|nifi.security.truststore=${CERT_PATH}/truststore.jks|" "$CONFIG_FILE"
sudo sed -i "s|nifi.security.truststoreType=.*|nifi.security.truststoreType=jks|" "$CONFIG_FILE"
sudo sed -i "s|nifi.security.truststorePasswd=.*|nifi.security.truststorePasswd=$TRUSTSTORE_PASS|" "$CONFIG_FILE"

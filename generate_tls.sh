#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/generate_tls.log"
CONFIG_FILE="./cluster_config.env"
CERT_DIR="/opt/nifi-certs"
KEYSTORE_PASS="$(openssl rand -hex 12)"
TRUSTSTORE_PASS="$KEYSTORE_PASS"

echo "$(date '+%F %T') | Generating TLS certificates for NiFi cluster..." | tee -a "$LOG_FILE"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "$(date '+%F %T') | ❌ Cluster configuration not found. Run cluster_setup.sh first." | tee -a "$LOG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# Prompt for SSH password
read -srp "Enter SSH password for all remote nodes: " SSH_PASS
echo

sudo mkdir -p "$CERT_DIR/CA"
if [[ ! -f "$CERT_DIR/CA/nifi-rootCA.key" ]]; then
    echo "$(date '+%F %T') | Generating root CA..." | tee -a "$LOG_FILE"
    sudo openssl genrsa -out "$CERT_DIR/CA/nifi-rootCA.key" 4096
    sudo openssl req -x509 -new -nodes -key "$CERT_DIR/CA/nifi-rootCA.key" -sha256 -days 825 \
        -out "$CERT_DIR/CA/nifi-rootCA.pem" -subj "/CN=NiFi-Root-CA/O=NiFi"
fi

# Generate cert for each node and distribute if remote
for (( i=1; i<=NODE_COUNT; i++ )); do
    HOST_VAR="NODE_${i}_HOST"
    IP_VAR="NODE_${i}_IP"
    USER_VAR="NODE_${i}_USER"
    HOST=${!HOST_VAR}
    IP=${!IP_VAR}
    USER=${!USER_VAR}
    NODE_DIR="$CERT_DIR/$HOST"

    sudo mkdir -p "$NODE_DIR"
    echo "$(date '+%F %T') | Generating cert for $HOST ($IP)" | tee -a "$LOG_FILE"

    sudo openssl genrsa -out "$NODE_DIR/nifi.key" 2048
    cat <<EOF | sudo tee "$NODE_DIR/nifi.cnf" >/dev/null
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
CN = $HOST
O = NiFi

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = $HOST
IP.1 = $IP
EOF

    sudo openssl req -new -key "$NODE_DIR/nifi.key" -out "$NODE_DIR/nifi.csr" -config "$NODE_DIR/nifi.cnf"
    sudo openssl x509 -req -in "$NODE_DIR/nifi.csr" -CA "$CERT_DIR/CA/nifi-rootCA.pem" \
        -CAkey "$CERT_DIR/CA/nifi-rootCA.key" -CAcreateserial -out "$NODE_DIR/nifi.crt" -days 825 \
        -sha256 -extfile "$NODE_DIR/nifi.cnf" -extensions req_ext

    sudo openssl pkcs12 -export -in "$NODE_DIR/nifi.crt" -inkey "$NODE_DIR/nifi.key" \
        -out "$NODE_DIR/keystore.p12" -name nifi -CAfile "$CERT_DIR/CA/nifi-rootCA.pem" \
        -caname root -password pass:$KEYSTORE_PASS

    sudo keytool -importkeystore -deststorepass $KEYSTORE_PASS -destkeypass $KEYSTORE_PASS \
        -destkeystore "$NODE_DIR/keystore.jks" -srckeystore "$NODE_DIR/keystore.p12" \
        -srcstoretype PKCS12 -srcstorepass $KEYSTORE_PASS -alias nifi

    sudo keytool -import -trustcacerts -alias root -file "$CERT_DIR/CA/nifi-rootCA.pem" \
        -keystore "$NODE_DIR/truststore.jks" -storepass $TRUSTSTORE_PASS -noprompt

    # Distribute to remote nodes if not localhost
    if [[ "$HOST" != "$(hostname)" ]]; then
        sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "$NODE_DIR/keystore.p12" "$USER@$IP:/tmp/nifi${i}-keystore.p12"
        sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "$CERT_DIR/CA/nifi-rootCA.pem" "$USER@$IP:/tmp/nifi-truststore.p12"
    fi
done

sudo tee "$CERT_DIR/passwords.env" >/dev/null <<EOF
KEYSTORE_PASS=$KEYSTORE_PASS
TRUSTSTORE_PASS=$TRUSTSTORE_PASS
EOF

echo "$(date '+%F %T') | ✅ TLS certificate generation and distribution complete." | tee -a "$LOG_FILE"

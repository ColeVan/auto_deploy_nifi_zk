#!/bin/bash

setup_local_node() {
    local id="$1"
    echo "$(date '+%F %T') | 🖥️ Setting up local NiFi node $id..." | tee -a "$LOG_FILE"

    # First check if NiFi directory already exists at the destination
    if [[ -d "$NIFI_DIR" && -f "$NIFI_DIR/bin/nifi.sh" ]]; then
        echo "$(date '+%F %T') | ℹ️ NiFi directory already exists at $NIFI_DIR" | tee -a "$LOG_FILE"
        echo "$(date '+%F %T') | ℹ️ Using existing NiFi installation" | tee -a "$LOG_FILE"
        NIFI_VERSION=$(basename "$NIFI_DIR")
        
        # Create a service file
        echo "$(date '+%F %T') | ℹ️ Creating NiFi service file..." | tee -a "$LOG_FILE"
        
        # Determine which user/group to use
        SERVICE_USER="$NIFI_USER"
        SERVICE_GROUP="$NIFI_GROUP"
        
        if [[ "$RUN_AS_ROOT" == "true" ]]; then
            echo "$(date '+%F %T') | ⚠️ Warning: Running NiFi as root is not recommended for production environments" | tee -a "$LOG_FILE"
            SERVICE_USER="root"
            SERVICE_GROUP="root"
        fi
        
        cat > /tmp/nifi.service <<SERVICE
[Unit]
Description=Apache NiFi
After=network.target
[Service]
User=$SERVICE_USER
Group=$SERVICE_GROUP
ExecStart=/bin/bash -c 'export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 && $NIFI_DIR/bin/nifi.sh start'
ExecStop=/bin/bash -c 'export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 && $NIFI_DIR/bin/nifi.sh stop'
Restart=on-failure
RestartSec=10
TimeoutSec=300
PIDFile=$NIFI_DIR/run/nifi.pid
LimitNOFILE=50000
[Install]
WantedBy=multi-user.target
SERVICE

        # Skip to certificate setup
        echo "$(date '+%F %T') | ℹ️ Skipping extraction and cleanup as we're using existing installation" | tee -a "$LOG_FILE"
        
        # Create NiFi certs directory
        echo "$(date '+%F %T') | ℹ️ Creating NiFi certs directory..." | tee -a "$LOG_FILE"
        sudo mkdir -p "$NIFI_DIR/certs"
        
        # Debug: Show hostname and SERVER_HOSTS array
        echo "$(date '+%F %T') | ℹ️ Current hostname: $(hostname)" | tee -a "$LOG_FILE"
        echo "$(date '+%F %T') | ℹ️ Current IP: $CURRENT_IP" | tee -a "$LOG_FILE"
        echo "$(date '+%F %T') | ℹ️ Node ID: $id" | tee -a "$LOG_FILE"
        echo "$(date '+%F %T') | ℹ️ SERVER_HOSTS array:" | tee -a "$LOG_FILE"
        for ((j=0; j<${#SERVER_HOSTS[@]}; j++)); do
            echo "$(date '+%F %T') | ℹ️   SERVER_HOSTS[$j]: ${SERVER_HOSTS[j]}" | tee -a "$LOG_FILE"
        done
        
        # Debug: List certificate directories
        echo "$(date '+%F %T') | ℹ️ Listing certificate directories:" | tee -a "$LOG_FILE"
        ls -la "$CERT_DIR/" | tee -a "$LOG_FILE"
        
        # Check if certificate files exist
        echo "$(date '+%F %T') | ℹ️ Checking certificate files..." | tee -a "$LOG_FILE"
        echo "$(date '+%F %T') | ℹ️ Keystore path: $CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12" | tee -a "$LOG_FILE"
        echo "$(date '+%F %T') | ℹ️ Truststore path: $CERT_DIR/CA/nifi-rootCA.pem" | tee -a "$LOG_FILE"
        
        if [[ ! -f "$CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12" ]]; then
            echo "$(date '+%F %T') | ❌ ERROR: Keystore file not found: $CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12" | tee -a "$LOG_FILE"
            
            # Try to find the keystore file in other directories
            echo "$(date '+%F %T') | ℹ️ Searching for keystore files in certificate directory..." | tee -a "$LOG_FILE"
            find "$CERT_DIR" -name "keystore.p12" | tee -a "$LOG_FILE"
            
            # List all subdirectories in CERT_DIR
            echo "$(date '+%F %T') | ℹ️ Listing all subdirectories in $CERT_DIR:" | tee -a "$LOG_FILE"
            find "$CERT_DIR" -type d | tee -a "$LOG_FILE"
            
            # Try using the current hostname directly
            if [[ -f "$CERT_DIR/$(hostname)/keystore.p12" ]]; then
                echo "$(date '+%F %T') | ℹ️ Found keystore using current hostname: $CERT_DIR/$(hostname)/keystore.p12" | tee -a "$LOG_FILE"
                KEYSTORE_PATH="$CERT_DIR/$(hostname)/keystore.p12"
            else
                echo "$(date '+%F %T') | ❌ ERROR: Could not find keystore file" | tee -a "$LOG_FILE"
                exit 1
            fi
        else
            KEYSTORE_PATH="$CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12"
        fi
        
        if [[ ! -f "$CERT_DIR/CA/nifi-rootCA.pem" ]]; then
            echo "$(date '+%F %T') | ❌ ERROR: Truststore file not found: $CERT_DIR/CA/nifi-rootCA.pem" | tee -a "$LOG_FILE"
            
            # Try to find the truststore file
            echo "$(date '+%F %T') | ℹ️ Searching for truststore files in certificate directory..." | tee -a "$LOG_FILE"
            find "$CERT_DIR" -name "nifi-rootCA.pem" | tee -a "$LOG_FILE"
            
            echo "$(date '+%F %T') | ❌ ERROR: Could not find truststore file" | tee -a "$LOG_FILE"
            exit 1
        fi
        
        echo "$(date '+%F %T') | ℹ️ Copying certificate files..." | tee -a "$LOG_FILE"
        sudo cp "$KEYSTORE_PATH" "$NIFI_DIR/certs/nifi${id}-keystore.p12" || {
            echo "$(date '+%F %T') | ❌ ERROR: Failed to copy keystore file" | tee -a "$LOG_FILE"
            exit 1
        }
        
        # Create a proper PKCS12 truststore from the CA certificate
        echo "$(date '+%F %T') | ℹ️ Creating PKCS12 truststore from CA certificate..." | tee -a "$LOG_FILE"
        
        # Create a temporary truststore using Java keytool (more reliable than OpenSSL for Java compatibility)
        sudo rm -f /tmp/nifi-truststore.p12
        
        # First create a temporary JKS truststore
        sudo rm -f /tmp/temp-truststore.jks
        sudo keytool -import -trustcacerts -noprompt -alias "nifi-ca" \
            -file "$CERT_DIR/CA/nifi-rootCA.pem" \
            -keystore /tmp/temp-truststore.jks \
            -storepass "$KEYSTORE_PASS" || {
            echo "$(date '+%F %T') | ❌ ERROR: Failed to create JKS truststore" | tee -a "$LOG_FILE"
            exit 1
        }
        
        # Then convert JKS to PKCS12
        sudo keytool -importkeystore \
            -srckeystore /tmp/temp-truststore.jks -srcstoretype JKS -srcstorepass "$KEYSTORE_PASS" \
            -destkeystore /tmp/nifi-truststore.p12 -deststoretype PKCS12 -deststorepass "$KEYSTORE_PASS" || {
            echo "$(date '+%F %T') | ❌ ERROR: Failed to convert JKS to PKCS12 truststore" | tee -a "$LOG_FILE"
            exit 1
        }
        
        # Verify the PKCS12 file
        echo "$(date '+%F %T') | ℹ️ Verifying PKCS12 truststore..." | tee -a "$LOG_FILE"
        sudo keytool -list -keystore /tmp/nifi-truststore.p12 -storepass "$KEYSTORE_PASS" -storetype PKCS12 || {
            echo "$(date '+%F %T') | ❌ ERROR: PKCS12 truststore verification failed" | tee -a "$LOG_FILE"
            exit 1
        }
        
        # Copy the truststore to the NiFi directory
        sudo cp "/tmp/nifi-truststore.p12" "$NIFI_DIR/certs/nifi-truststore.p12" || {
            echo "$(date '+%F %T') | ❌ ERROR: Failed to copy truststore file" | tee -a "$LOG_FILE"
            exit 1
        }
        
        # Verify certificate files were copied
        echo "$(date '+%F %T') | ℹ️ Verifying certificate files were copied..." | tee -a "$LOG_FILE"
        ls -la "$NIFI_DIR/certs/" | tee -a "$LOG_FILE"
        sudo cp /tmp/nifi.service /etc/systemd/system/nifi.service
        rm -f /tmp/nifi.service
        
        # Verify certificate settings in nifi.properties
        echo "$(date '+%F %T') | ℹ️ Verifying certificate settings in nifi.properties..." | tee -a "$LOG_FILE"
        sudo grep -E "nifi.security.(keystore|truststore)" "$NIFI_DIR/conf/nifi.properties" | tee -a "$LOG_FILE"
        
        configure_nifi_properties "$id" "$CURRENT_IP" "nifi${id}-keystore.p12" "nifi-truststore.p12"
        
        # Start NiFi
        sudo systemctl daemon-reload
        sudo systemctl enable nifi
        sudo systemctl start nifi
        echo "$(date '+%F %T') | ✅ Local NiFi setup complete." | tee -a "$LOG_FILE"
        
        return 0
    else
        # Debug: Check if NiFi tarball exists
        echo "$(date '+%F %T') | ℹ️ Checking NiFi tarball: $NIFI_TARBALL" | tee -a "$LOG_FILE"
        if [[ ! -f "$NIFI_TARBALL" ]]; then
            echo "$(date '+%F %T') | ❌ ERROR: NiFi tarball not found: $NIFI_TARBALL" | tee -a "$LOG_FILE"
            exit 1
        fi
        
        # Debug: Check tarball file type
        echo "$(date '+%F %T') | ℹ️ Verifying NiFi tarball file type..." | tee -a "$LOG_FILE"
        file "$NIFI_TARBALL" | tee -a "$LOG_FILE"
        
        # Create a service file
        echo "$(date '+%F %T') | ℹ️ Creating NiFi service file..." | tee -a "$LOG_FILE"
        
        # Determine which user/group to use
        SERVICE_USER="$NIFI_USER"
        SERVICE_GROUP="$NIFI_GROUP"
        
        if [[ "$RUN_AS_ROOT" == "true" ]]; then
            echo "$(date '+%F %T') | ⚠️ Warning: Running NiFi as root is not recommended for production environments" | tee -a "$LOG_FILE"
            SERVICE_USER="root"
            SERVICE_GROUP="root"
        fi
        
        cat > /tmp/nifi.service <<SERVICE
[Unit]
Description=Apache NiFi
After=network.target
[Service]
User=$SERVICE_USER
Group=$SERVICE_GROUP
ExecStart=/bin/bash -c 'export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 && $NIFI_DIR/bin/nifi.sh start'
ExecStop=/bin/bash -c 'export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 && $NIFI_DIR/bin/nifi.sh stop'
Restart=on-failure
RestartSec=10
TimeoutSec=300
PIDFile=$NIFI_DIR/run/nifi.pid
LimitNOFILE=50000
[Install]
WantedBy=multi-user.target
SERVICE
        
        # Perform comprehensive NiFi cleanup
        echo "$(date '+%F %T') | 🧹 Performing comprehensive NiFi cleanup..." | tee -a "$LOG_FILE"

        # Stop and disable NiFi service if it exists
        echo "$(date '+%F %T') | ℹ️ Checking for existing NiFi service..." | tee -a "$LOG_FILE"
        if sudo systemctl list-unit-files | grep -q "^nifi.service"; then
            echo "$(date '+%F %T') | ℹ️ Stopping and disabling existing NiFi service..." | tee -a "$LOG_FILE"
            sudo systemctl stop nifi || true
            sudo systemctl disable nifi || true
            sudo rm -f /etc/systemd/system/nifi.service
            # Remove any systemd override files
            sudo rm -rf /etc/systemd/system/nifi.service.d/
            sudo systemctl daemon-reload
            echo "$(date '+%F %T') | ✅ NiFi service removed" | tee -a "$LOG_FILE"
        else
            echo "$(date '+%F %T') | ℹ️ No existing NiFi service found" | tee -a "$LOG_FILE"
        fi

        # Kill any running NiFi processes
        echo "$(date '+%F %T') | ℹ️ Killing any running NiFi processes..." | tee -a "$LOG_FILE"

        # Skip kill operation if SKIP_KILL is true
        if [[ "$SKIP_KILL" == "true" ]]; then
            echo "$(date '+%F %T') | ℹ️ Skipping kill operation as SKIP_KILL is set to true" | tee -a "$LOG_FILE"
        else
            # Use the external kill script if available
            if [[ -f "./kill_n
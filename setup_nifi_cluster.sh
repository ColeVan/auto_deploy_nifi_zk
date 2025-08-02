#!/bin/bash
# Re-enable strict error handling with better error handling around critical sections
set -euo pipefail

# Define log file first
LOG_FILE="/var/log/nifi_cluster_setup.log"

# Error handling function
handle_error() {
    local exit_code=$1
    local error_message=$2
    local error_source=${3:-"unknown"}
    
    echo "$(date '+%F %T') | ❌ ERROR ($exit_code) in $error_source: $error_message" | tee -a "$LOG_FILE"
    
    # Cleanup any temporary files
    rm -f /tmp/nifi_setup_commands.sh 2>/dev/null || true
    
    exit $exit_code
}

# Define trap functions
term_handler() {
    echo "$(date '+%F %T') | ⚠️ Script received SIGTERM signal" | tee -a "$LOG_FILE"
    exit 143
}

int_handler() {
    echo "$(date '+%F %T') | ⚠️ Script received SIGINT signal" | tee -a "$LOG_FILE"
    exit 130
}

# Trap errors and signals
trap 'handle_error $? "Unexpected error occurred" "${BASH_SOURCE[0]}:${LINENO}"' ERR
trap term_handler TERM
trap int_handler INT
CONFIG_FILE="./cluster_config.env"
NIFI_DIR="/opt/nifi"
NIFI_TARBALL="/tmp/nifi-2.5.0-bin.zip"
NIFI_URL="https://dlcdn.apache.org/nifi/2.5.0/nifi-2.5.0-bin.zip"
NIFI_VERSION="nifi-2.5.0"
CERT_DIR="/opt/nifi-certs"
KEYSTORE_PASS_FILE="$CERT_DIR/passwords.env"
# Custom NAR files configuration
CUSTOM_NAR_DIR=${CUSTOM_NAR_DIR:-"./custom_nars"}  # Default directory for custom NAR files
CUSTOM_NAR_FILES=${CUSTOM_NAR_FILES:-""}  # Comma-separated list of specific NAR files to copy
SKIP_CUSTOM_NARS=${SKIP_CUSTOM_NARS:-false}  # Set to true to skip copying custom NAR files
PLUGINS_DIR=${PLUGINS_DIR:-"./plugins"}  # Legacy directory for NAR files (for backward compatibility)

# Initialize variables to avoid unbound variable errors
JAR_COUNT=0
nar_file=""
EXTRACTED_DIR=""
SKIP_EXTRACTION=false
nifi_pids=""
still_running=""
nifi_sh_pids=""
KEYSTORE_PATH=""
total_mem_mb=4096  # Default to 4GB - Initialize early to avoid unbound variable errors
init_heap_mb=1024  # Default to 1GB
max_heap_mb=2048   # Default to 2GB
init_heap_gb=1     # Default to 1GB
max_heap_gb=2      # Default to 2GB
init_heap="1g"     # Default to 1GB
max_heap="2g"      # Default to 2GB
usable_mem_mb=3072 # Default to 3GB (75% of 4GB)

# User/Group configuration
NIFI_USER=${NIFI_USER:-"nifi"}  # User to run NiFi as
NIFI_GROUP=${NIFI_GROUP:-"nifi"}  # Group for NiFi user
CREATE_USER=${CREATE_USER:-true}  # Set to false to skip creating NiFi user/group
RUN_AS_ROOT=${RUN_AS_ROOT:-false}  # Set to true to run NiFi as root (not recommended)

# Memory configuration
AUTO_MEMORY=${AUTO_MEMORY:-true}  # Set to false to use fixed memory settings
NIFI_HEAP_INIT=${NIFI_HEAP_INIT:-""}  # Initial heap size (e.g., "4g")
NIFI_HEAP_MAX=${NIFI_HEAP_MAX:-""}  # Maximum heap size (e.g., "8g")
NIFI_MEMORY_PERCENT=${NIFI_MEMORY_PERCENT:-75}  # Percentage of system memory to use (when AUTO_MEMORY=true)

# Repository retention configuration
CONTENT_REPO_RETENTION=${CONTENT_REPO_RETENTION:-"24 hours"}  # Content repository retention period
PROVENANCE_REPO_RETENTION=${PROVENANCE_REPO_RETENTION:-"7 days"}  # Provenance repository retention period
ENABLE_REPO_CLEANUP=${ENABLE_REPO_CLEANUP:-true}  # Enable repository cleanup

# Command aliases configuration
INSTALL_ALIASES=${INSTALL_ALIASES:-true}  # Set to false to skip installing command aliases

SKIP_SSH_SETUP=${SKIP_SSH_SETUP:-false}  # Set to true to skip SSH key setup
DEBUG_MODE=${DEBUG_MODE:-false}  # Set to true for more verbose debugging
SKIP_KILL=${SKIP_KILL:-true}  # Set to true to skip killing NiFi processes (default: true to avoid termination issues)
# Track whether a service file was located
SERVICE_FILE_FOUND=false

# Debug function
debug() {
    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo "$(date '+%F %T') | 🔍 DEBUG: $1" | tee -a "$LOG_FILE"
    fi
}

# Print script execution environment for debugging
debug "Script started with PID $$"
debug "Current user: $(whoami)"
debug "Current directory: $(pwd)"
debug "Bash version: $BASH_VERSION"

echo "$(date '+%F %T') | Starting multi-node NiFi cluster setup..." | tee -a "$LOG_FILE"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "$(date '+%F %T') | ❌ Cluster configuration not found." | tee -a "$LOG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

if [[ ! -f "$KEYSTORE_PASS_FILE" ]]; then
    echo "$(date '+%F %T') | ❌ TLS password file not found ($KEYSTORE_PASS_FILE)." | tee -a "$LOG_FILE"
    exit 1
fi
source "$KEYSTORE_PASS_FILE"

# Verify certificate directory exists
if [[ ! -d "$CERT_DIR" ]]; then
    echo "$(date '+%F %T') | ❌ Certificate directory not found: $CERT_DIR" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | ℹ️ Please run the certificate generation script first." | tee -a "$LOG_FILE"
    exit 1
fi

# Check if CA directory exists
if [[ ! -d "$CERT_DIR/CA" ]]; then
    echo "$(date '+%F %T') | ❌ CA directory not found: $CERT_DIR/CA" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | ℹ️ Please run the certificate generation script first." | tee -a "$LOG_FILE"
    exit 1
fi

# Check if CA certificate exists
if [[ ! -f "$CERT_DIR/CA/nifi-rootCA.pem" ]]; then
    echo "$(date '+%F %T') | ❌ Root CA certificate not found: $CERT_DIR/CA/nifi-rootCA.pem" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | ℹ️ Please run the certificate generation script first." | tee -a "$LOG_FILE"
    exit 1
fi

# Build Zookeeper connect string
ZK_CONNECT=""
for (( i=1; i<=NODE_COUNT; i++ )); do
    IP_VAR="NODE_${i}_IP"
    ZK_CONNECT+="${!IP_VAR}:2181"
    [[ $i -lt $NODE_COUNT ]] && ZK_CONNECT+=","
done

# Initialize SERVER arrays
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

CURRENT_HOST=$(hostname)
CURRENT_IP=$(hostname -I | awk '{print $1}')

# Function to verify certificate files
verify_certificate_files() {
    echo "$(date '+%F %T') | 🔍 Verifying certificate files..." | tee -a "$LOG_FILE"
    
    # Check if any certificate directories exist for the nodes
    local cert_dirs_found=false
    
    # Debug: Print all SERVER_HOSTS values
    echo "$(date '+%F %T') | ℹ️ Checking for certificate directories for hosts:" | tee -a "$LOG_FILE"
    if [[ ${#SERVER_HOSTS[@]} -eq 0 ]]; then
        echo "$(date '+%F %T') | ⚠️ Warning: SERVER_HOSTS array is empty" | tee -a "$LOG_FILE"
    else
        for ((i=0; i<${#SERVER_HOSTS[@]}; i++)); do
            echo "$(date '+%F %T') | ℹ️   SERVER_HOSTS[$i]: ${SERVER_HOSTS[i]}" | tee -a "$LOG_FILE"
        done
    fi
    
    # List all certificate directories for debugging
    echo "$(date '+%F %T') | ℹ️ Available certificate directories:" | tee -a "$LOG_FILE"
    ls -la "$CERT_DIR/" | tee -a "$LOG_FILE"
    
    for host in "${SERVER_HOSTS[@]}"; do
        # Try exact match first
        if [[ -d "$CERT_DIR/$host" ]]; then
            cert_dirs_found=true
            echo "$(date '+%F %T') | ✅ Found certificate directory for host: $host" | tee -a "$LOG_FILE"
        else
            # Try case-insensitive match or partial match with more flexibility
            # Remove any hyphens or special characters for more flexible matching
            local clean_host=$(echo "$host" | tr -d '-')
            local found=false
            
            # List all directories and try to find a match
            while IFS= read -r dir; do
                local dir_name=$(basename "$dir")
                local clean_dir=$(echo "$dir_name" | tr -d '-')

                # Check if the directory name contains the host name (ignoring case and special chars)
                if [[ "${clean_dir,,}" == *"${clean_host,,}"* || "${clean_host,,}" == *"${clean_dir,,}"* ]]; then
                    cert_dirs_found=true
                    found=true
                    echo "$(date '+%F %T') | ✅ Found certificate directory for host $host: $dir_name" | tee -a "$LOG_FILE"
                    break
                fi
            done < <(find "$CERT_DIR" -maxdepth 1 -type d ! -path "$CERT_DIR" ! -name 'CA')

            # If still not found, try a more general approach
            if [[ "$found" == "false" ]]; then
                local found_dir=$(find "$CERT_DIR" -maxdepth 1 -type d ! -path "$CERT_DIR" ! -name 'CA' | head -n 1)
                if [[ -n "$found_dir" ]]; then
                    cert_dirs_found=true
                    echo "$(date '+%F %T') | ✅ Using available certificate directory for host $host: $(basename "$found_dir")" | tee -a "$LOG_FILE"
                fi
            fi
        fi
    done
    
    if [[ "$cert_dirs_found" == "false" ]]; then
        echo "$(date '+%F %T') | ⚠️ Warning: No certificate directories found for any hosts" | tee -a "$LOG_FILE"
        echo "$(date '+%F %T') | ℹ️ Available certificate directories:" | tee -a "$LOG_FILE"
        ls -la "$CERT_DIR/" | tee -a "$LOG_FILE"
        
        # List all subdirectories for better debugging
        echo "$(date '+%F %T') | ℹ️ Listing all subdirectories in $CERT_DIR:" | tee -a "$LOG_FILE"
        find "$CERT_DIR" -maxdepth 1 -type d | tee -a "$LOG_FILE"
    fi
    
    # Check if CA certificate exists
    if [[ ! -f "$CERT_DIR/CA/nifi-rootCA.pem" ]]; then
        echo "$(date '+%F %T') | ⚠️ Warning: Root CA certificate not found at expected path" | tee -a "$LOG_FILE"
        # Try to find it elsewhere
        local ca_certs=$(find "$CERT_DIR" -name "nifi-rootCA.pem")
        if [[ -n "$ca_certs" ]]; then
            echo "$(date '+%F %T') | ✅ Found CA certificate(s) at:" | tee -a "$LOG_FILE"
            echo "$ca_certs" | tee -a "$LOG_FILE"
        else
            echo "$(date '+%F %T') | ❌ No CA certificate found in certificate directory" | tee -a "$LOG_FILE"
            return 1
        fi
    else
        echo "$(date '+%F %T') | ✅ CA certificate found at: $CERT_DIR/CA/nifi-rootCA.pem" | tee -a "$LOG_FILE"
    fi
    
    echo "$(date '+%F %T') | ✅ Certificate verification completed" | tee -a "$LOG_FILE"
    return 0
}

echo "$(date '+%F %T') | ✅ Certificate directory verified: $CERT_DIR" | tee -a "$LOG_FILE"
verify_certificate_files || {
    echo "$(date '+%F %T') | ❌ Certificate verification failed. Please check certificate files." | tee -a "$LOG_FILE"
    exit 1
}

# Function to check if SSH keys are set up and run setup_ssh_keys.sh if needed
setup_ssh_keys_if_needed() {
    # Skip if there's only one node (local)
    if [[ ${#SERVER_IPS[@]} -le 1 ]]; then
        echo "$(date '+%F %T') | ℹ️ Single node setup, no SSH keys needed." | tee -a "$LOG_FILE"
        return 0
    fi
    
    # Find a remote node to test
    local test_node_ip=""
    local test_node_user=""
    for (( i=0; i<${#SERVER_IPS[@]}; i++ )); do
        if [[ "${SERVER_HOSTS[i]}" != "$(hostname)" && "${SERVER_IPS[i]}" != "$(hostname -I | awk '{print $1}')" ]]; then
            test_node_ip="${SERVER_IPS[i]}"
            test_node_user="${SERVER_USERS[i]}"
            break
        fi
    done
    
    # If no remote node found, no SSH keys needed
    if [[ -z "$test_node_ip" ]]; then
        echo "$(date '+%F %T') | ℹ️ No remote nodes found, no SSH keys needed." | tee -a "$LOG_FILE"
        return 0
    fi
    
    # Try to SSH to the remote node without password
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$test_node_user@$test_node_ip" "echo 'SSH keys working'" &>/dev/null; then
        echo "$(date '+%F %T') | ✅ SSH keys already set up and working." | tee -a "$LOG_FILE"
        return 0
    else
        echo "$(date '+%F %T') | ℹ️ SSH keys not set up or not working. Running setup_ssh_keys.sh..." | tee -a "$LOG_FILE"
        # Run the SSH key setup script
        ./setup_ssh_keys.sh
        
        # Verify it worked
        if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$test_node_user@$test_node_ip" "echo 'SSH keys working'" &>/dev/null; then
            echo "$(date '+%F %T') | ❌ SSH key setup failed. Please run setup_ssh_keys.sh manually." | tee -a "$LOG_FILE"
            exit 1
        fi
    fi
}

# Download NiFi if missing
if [[ ! -f "$NIFI_TARBALL" ]]; then
    echo "$(date '+%F %T') | Downloading NiFi tarball..." | tee -a "$LOG_FILE"
    # Add timeout and retry for download
    for attempt in {1..3}; do
        echo "$(date '+%F %T') | ℹ️ Download attempt $attempt..." | tee -a "$LOG_FILE"
        if sudo wget --timeout=30 --tries=3 -O "$NIFI_TARBALL" "$NIFI_URL"; then
            echo "$(date '+%F %T') | ✅ Download successful" | tee -a "$LOG_FILE"
            break
        else
            echo "$(date '+%F %T') | ⚠️ Download attempt $attempt failed, retrying..." | tee -a "$LOG_FILE"
            sleep 5
        fi
        
        if [[ $attempt -eq 3 ]]; then
            handle_error 1 "Failed to download NiFi tarball after 3 attempts" "download_tarball"
        fi
    done
    
    # Verify the downloaded file
    echo "$(date '+%F %T') | ℹ️ Verifying downloaded file..." | tee -a "$LOG_FILE"
    if [[ ! -f "$NIFI_TARBALL" ]]; then
        handle_error 1 "Downloaded file not found at $NIFI_TARBALL" "verify_tarball"
    fi
    
    if ! file "$NIFI_TARBALL" | grep -q "Zip archive data"; then
        handle_error 1 "Downloaded file is not a valid ZIP archive" "verify_tarball"
    fi
    
    echo "$(date '+%F %T') | ✅ NiFi tarball verified: $NIFI_TARBALL" | tee -a "$LOG_FILE"
else
    echo "$(date '+%F %T') | ℹ️ Using existing NiFi tarball: $NIFI_TARBALL" | tee -a "$LOG_FILE"
    
    # Verify the existing file
    if [[ ! -f "$NIFI_TARBALL" ]]; then
        echo "$(date '+%F %T') | ⚠️ Existing tarball not found, will download again" | tee -a "$LOG_FILE"
        rm -f "$NIFI_TARBALL" 2>/dev/null || true
        
        echo "$(date '+%F %T') | ℹ️ Downloading NiFi tarball..." | tee -a "$LOG_FILE"
        for attempt in {1..3}; do
            echo "$(date '+%F %T') | ℹ️ Download attempt $attempt..." | tee -a "$LOG_FILE"
            if sudo wget --timeout=30 --tries=3 -O "$NIFI_TARBALL" "$NIFI_URL"; then
                echo "$(date '+%F %T') | ✅ Download successful" | tee -a "$LOG_FILE"
                break
            else
                echo "$(date '+%F %T') | ⚠️ Download attempt $attempt failed, retrying..." | tee -a "$LOG_FILE"
                sleep 5
            fi
            
            if [[ $attempt -eq 3 ]]; then
                handle_error 1 "Failed to download NiFi tarball after 3 attempts" "download_tarball"
            fi
        done
        
        # Verify the downloaded file
        echo "$(date '+%F %T') | ℹ️ Verifying downloaded file..." | tee -a "$LOG_FILE"
        if [[ ! -f "$NIFI_TARBALL" ]]; then
            handle_error 1 "Downloaded file not found at $NIFI_TARBALL" "verify_tarball"
        fi
        
        if ! file "$NIFI_TARBALL" | grep -q "Zip archive data"; then
            handle_error 1 "Downloaded file is not a valid ZIP archive" "verify_tarball"
        fi
    else
        echo "$(date '+%F %T') | ✅ Existing NiFi tarball found" | tee -a "$LOG_FILE"
    fi
fi

# These arrays and variables are already initialized earlier in the script
# This section is now redundant and can be removed

# Set up SSH keys if needed (after arrays are populated)
if [[ "$SKIP_SSH_SETUP" == "true" ]]; then
    echo "$(date '+%F %T') | ℹ️ Skipping SSH key setup as requested" | tee -a "$LOG_FILE"
else
    setup_ssh_keys_if_needed
fi

# Using SSH key-based authentication
echo "$(date '+%F %T') | 🔑 Using SSH key-based authentication" | tee -a "$LOG_FILE"

# Configure NiFi properties
configure_nifi_properties() {
    local node_id="$1"
    local ip="$2"
    local cert_keystore="$3"
    local cert_truststore="$4"
    local config_dir="$NIFI_DIR/conf"

    echo "$(date '+%F %T') | 🛠️ Configuring NiFi properties on $ip..." | tee -a "$LOG_FILE"

    # Generate a random sensitive properties key
    local sensitive_props_key=$(openssl rand -hex 16)

    declare -a sed_cmds=(
        "s|nifi.sensitive.props.key=.*|nifi.sensitive.props.key=$sensitive_props_key|"
        "s|nifi.web.https.host=.*|nifi.web.https.host=${ip#/}|"
        "s|nifi.web.https.port=.*|nifi.web.https.port=8443|"
        "s|nifi.security.keystore=.*|nifi.security.keystore=$NIFI_DIR/certs/$cert_keystore|"
        "s|nifi.security.keystoreType=.*|nifi.security.keystoreType=PKCS12|"
        "s|nifi.security.keystore.certificate=.*|nifi.security.keystore.certificate=nifi-key|"
        "s|nifi.security.keystore.privateKey=.*|nifi.security.keystore.privateKey=nifi-key|"
        "s|nifi.security.truststore=.*|nifi.security.truststore=$NIFI_DIR/certs/$cert_truststore|"
        "s|nifi.security.truststoreType=.*|nifi.security.truststoreType=PKCS12|"
        # Remove the truststore certificate property as it's not needed for PKCS12 truststores
        # and can cause the "Some truststore properties are populated but not valid" warning
        "s|nifi.security.truststore.certificate=.*|# nifi.security.truststore.certificate is not needed for PKCS12 truststores|"
        "s|nifi.security.keystorePasswd=.*|nifi.security.keystorePasswd=$KEYSTORE_PASS|"
        "s|nifi.security.keyPasswd=.*|nifi.security.keyPasswd=$KEYSTORE_PASS|"
        "s|nifi.security.truststorePasswd=.*|nifi.security.truststorePasswd=$KEYSTORE_PASS|"
        "s|nifi.cluster.is.node=false|nifi.cluster.is.node=true|"
        "s|nifi.cluster.protocol.is.secure=false|nifi.cluster.protocol.is.secure=true|"
        "s|nifi.cluster.node.address=.*|nifi.cluster.node.address=${ip#/}|"
        "s|nifi.cluster.node.protocol.port=.*|nifi.cluster.node.protocol.port=11443|"
        "s|nifi.zookeeper.connect.string=.*|nifi.zookeeper.connect.string=$ZK_CONNECT|"
    )

    for pattern in "${sed_cmds[@]}"; do
        sudo sed -i "$pattern" "$config_dir/nifi.properties"
    done
    
    # Fix repository paths to use absolute paths instead of relative paths
    echo "$(date '+%F %T') | ℹ️ Setting absolute paths for repositories..." | tee -a "$LOG_FILE"
    sudo sed -i "s|nifi.flowfile.repository.directory=.*|nifi.flowfile.repository.directory=$NIFI_DIR/flowfile_repository|" "$config_dir/nifi.properties"
    sudo sed -i "s|nifi.content.repository.directory.default=.*|nifi.content.repository.directory.default=$NIFI_DIR/content_repository|" "$config_dir/nifi.properties"
    sudo sed -i "s|nifi.provenance.repository.directory.default=.*|nifi.provenance.repository.directory.default=$NIFI_DIR/provenance_repository|" "$config_dir/nifi.properties"
    sudo sed -i "s|nifi.state.management.provider.local.directory=.*|nifi.state.management.provider.local.directory=$NIFI_DIR/state/local|" "$config_dir/nifi.properties"
    sudo sed -i "s|nifi.database.directory=.*|nifi.database.directory=$NIFI_DIR/database_repository|" "$config_dir/nifi.properties"

    sudo sed -i \
        "s|<property name=\"Connect String\"></property>|<property name=\"Connect String\">$ZK_CONNECT</property>|" \
        "$config_dir/state-management.xml"

    # Configure memory settings
    echo "$(date '+%F %T') | 🧠 Configuring memory settings..." | tee -a "$LOG_FILE"
    
    # Determine memory settings
    # Note: memory variables are already initialized at the beginning of the script
    if [[ "$AUTO_MEMORY" == "true" ]]; then
        # Skip memory detection entirely and use hardcoded values
        echo "$(date '+%F %T') | ℹ️ Using default memory setting: ${total_mem_mb}MB" | tee -a "$LOG_FILE"
        
        # Calculate memory to use based on percentage
        usable_mem_mb=$((total_mem_mb * NIFI_MEMORY_PERCENT / 100))
        echo "$(date '+%F %T') | ℹ️ Usable memory (${NIFI_MEMORY_PERCENT}%): ${usable_mem_mb}MB" | tee -a "$LOG_FILE"
        
        # Set initial heap to 40% of usable memory
        init_heap_mb=$((usable_mem_mb * 40 / 100))
        # Set max heap to 80% of usable memory
        max_heap_mb=$((usable_mem_mb * 80 / 100))
        
        # Convert to GB for readability, with minimum values
        init_heap_gb=$(( init_heap_mb < 1024 ? 1 : init_heap_mb / 1024 ))
        max_heap_gb=$(( max_heap_mb < 2048 ? 2 : max_heap_mb / 1024 ))
        
        # Ensure max is at least 1GB more than init
        if (( max_heap_gb - init_heap_gb < 1 )); then
            max_heap_gb=$((init_heap_gb + 1))
        fi
        
        echo "$(date '+%F %T') | ℹ️ Auto-configured memory: Initial=${init_heap_gb}g, Max=${max_heap_gb}g" | tee -a "$LOG_FILE"
        
        # Set the values
        init_heap="${init_heap_gb}g"
        max_heap="${max_heap_gb}g"
    else
        # Use provided values or defaults
        init_heap=${NIFI_HEAP_INIT:-"4g"}
        max_heap=${NIFI_HEAP_MAX:-"8g"}
        echo "$(date '+%F %T') | ℹ️ Using configured memory: Initial=${init_heap}, Max=${max_heap}" | tee -a "$LOG_FILE"
    fi
    
    # Update bootstrap.conf with memory settings
    sudo sed -i "s|java.arg.2=-Xms[0-9]*[kmg]|java.arg.2=-Xms${init_heap}|" "$config_dir/bootstrap.conf"
    sudo sed -i "s|java.arg.3=-Xmx[0-9]*[kmg]|java.arg.3=-Xmx${max_heap}|" "$config_dir/bootstrap.conf"
    
    # Add or update garbage collection settings
    if ! sudo grep -q "java.arg.13=-XX:+UseG1GC" "$config_dir/bootstrap.conf"; then
        echo "$(date '+%F %T') | ℹ️ Adding G1GC garbage collector settings..." | tee -a "$LOG_FILE"
        echo "java.arg.13=-XX:+UseG1GC" | sudo tee -a "$config_dir/bootstrap.conf" > /dev/null
        echo "java.arg.14=-XX:+ExplicitGCInvokesConcurrent" | sudo tee -a "$config_dir/bootstrap.conf" > /dev/null
        echo "java.arg.15=-XX:+ParallelRefProcEnabled" | sudo tee -a "$config_dir/bootstrap.conf" > /dev/null
        echo "java.arg.16=-XX:+DisableExplicitGC" | sudo tee -a "$config_dir/bootstrap.conf" > /dev/null
        echo "java.arg.17=-XX:+AlwaysPreTouch" | sudo tee -a "$config_dir/bootstrap.conf" > /dev/null
    fi
    
    # Add JAVA_HOME to bootstrap.conf if not already present
    if ! sudo grep -q "^java.home=" "$config_dir/bootstrap.conf"; then
        echo "$(date '+%F %T') | ℹ️ Adding JAVA_HOME to bootstrap.conf..." | tee -a "$LOG_FILE"
        echo "java.home=$JAVA_HOME" | sudo tee -a "$config_dir/bootstrap.conf" > /dev/null
    fi

    # Enhanced custom NAR files handling
    if [[ "$SKIP_CUSTOM_NARS" == "false" ]]; then
        echo "$(date '+%F %T') | ℹ️ Checking for custom NAR files..." | tee -a "$LOG_FILE"
        
        # Create directory for custom NARs if it doesn't exist
        if [[ ! -d "$CUSTOM_NAR_DIR" ]]; then
            echo "$(date '+%F %T') | ℹ️ Creating custom NAR directory: $CUSTOM_NAR_DIR" | tee -a "$LOG_FILE"
            mkdir -p "$CUSTOM_NAR_DIR"
        fi
        
        # Check if specific NAR files were specified
        if [[ -n "$CUSTOM_NAR_FILES" ]]; then
            echo "$(date '+%F %T') | ℹ️ Processing specified NAR files: $CUSTOM_NAR_FILES" | tee -a "$LOG_FILE"
            IFS=',' read -ra NAR_FILES <<< "$CUSTOM_NAR_FILES"
            for nar_file in "${NAR_FILES[@]}"; do
                # Trim whitespace
                nar_file=$(echo "$nar_file" | xargs)
                
                # Check if the file exists
                if [[ -f "$nar_file" ]]; then
                    echo "$(date '+%F %T') | ✅ Copying NAR file: $nar_file" | tee -a "$LOG_FILE"
                    sudo cp "$nar_file" "$NIFI_DIR/lib/" || {
                        echo "$(date '+%F %T') | ⚠️ Failed to copy NAR file: $nar_file" | tee -a "$LOG_FILE"
                    }
                elif [[ -f "$CUSTOM_NAR_DIR/$nar_file" ]]; then
                    echo "$(date '+%F %T') | ✅ Copying NAR file from custom directory: $CUSTOM_NAR_DIR/$nar_file" | tee -a "$LOG_FILE"
                    sudo cp "$CUSTOM_NAR_DIR/$nar_file" "$NIFI_DIR/lib/" || {
                        echo "$(date '+%F %T') | ⚠️ Failed to copy NAR file: $CUSTOM_NAR_DIR/$nar_file" | tee -a "$LOG_FILE"
                    }
                else
                    echo "$(date '+%F %T') | ⚠️ NAR file not found: $nar_file" | tee -a "$LOG_FILE"
                fi
            done
        else
            # Copy all NAR files from the custom NAR directory
            echo "$(date '+%F %T') | ℹ️ Checking for NAR files in $CUSTOM_NAR_DIR" | tee -a "$LOG_FILE"
            if find "$CUSTOM_NAR_DIR" -name "*.nar" -type f | grep -q .; then
                echo "$(date '+%F %T') | ✅ Found NAR files in $CUSTOM_NAR_DIR" | tee -a "$LOG_FILE"
                # Initialize nar_file to avoid unbound variable error
                nar_file=""
                find "$CUSTOM_NAR_DIR" -name "*.nar" -type f -print | while read -r nar_file; do
                    echo "$(date '+%F %T') | ✅ Copying NAR file: $nar_file" | tee -a "$LOG_FILE"
                    sudo cp "$nar_file" "$NIFI_DIR/lib/" || {
                        echo "$(date '+%F %T') | ⚠️ Failed to copy NAR file: $nar_file" | tee -a "$LOG_FILE"
                    }
                done
            else
                echo "$(date '+%F %T') | ℹ️ No NAR files found in $CUSTOM_NAR_DIR" | tee -a "$LOG_FILE"
                
                # For backward compatibility, check the old plugins directory
                if [[ -d "$PLUGINS_DIR" ]] && compgen -G "$PLUGINS_DIR/*.nar" > /dev/null; then
                    echo "$(date '+%F %T') | ℹ️ Found NAR files in legacy directory $PLUGINS_DIR" | tee -a "$LOG_FILE"
                    while IFS= read -r legacy_nar; do
                        sudo cp "$legacy_nar" "$NIFI_DIR/lib/" || {
                            echo "$(date '+%F %T') | ⚠️ Failed to copy NAR file: $legacy_nar" | tee -a "$LOG_FILE"
                        }
                    done < <(find "$PLUGINS_DIR" -maxdepth 1 -type f -name "*.nar")
                fi
            fi
        fi

        # Verify NAR files were copied
        echo "$(date '+%F %T') | ℹ️ Verifying NAR files in NiFi lib directory..." | tee -a "$LOG_FILE"
        nar_count=$(find "$NIFI_DIR/lib" -name "*.nar" | wc -l)
        echo "$(date '+%F %T') | ✅ Found $nar_count NAR files in $NIFI_DIR/lib" | tee -a "$LOG_FILE"
    else
        echo "$(date '+%F %T') | ℹ️ Skipping custom NAR files as requested" | tee -a "$LOG_FILE"
    fi
    
    echo "$(date '+%F %T') | ✅ NiFi properties configured on $ip" | tee -a "$LOG_FILE"
}

setup_remote_node() {
    local id="$1"
    local host="$2"
    local ip="$3"
    local user="$4"
    local SERVICE_FILE_PATH=""  # Initialize SERVICE_FILE_PATH to avoid unbound variable error
    local SERVICE_FILE_FOUND=false  # Track if service file is located for this node

    echo "$(date '+%F %T') | 🖥️ Setting up remote NiFi node $id on $ip..." | tee -a "$LOG_FILE"
    
    # First, ensure Java is installed on the remote node
    echo "$(date '+%F %T') | ℹ️ Ensuring Java is installed on remote node..." | tee -a "$LOG_FILE"
    ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "
        if ! command -v java &> /dev/null; then
            echo 'Java not found, installing...'
            sudo apt-get update
            sudo apt-get install -y openjdk-21-jdk
        else
            echo 'Java is already installed'
            java -version
        fi
        
        # Set JAVA_HOME in system-wide environment
        if ! grep -q 'JAVA_HOME=' /etc/environment; then
            echo 'Setting JAVA_HOME in /etc/environment'
            echo 'JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64' | sudo tee -a /etc/environment
        fi
        
        # Set JAVA_HOME in user's bashrc
        if ! grep -q 'JAVA_HOME=' ~/.bashrc; then
            echo 'Setting JAVA_HOME in ~/.bashrc'
            echo 'export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64' >> ~/.bashrc
            echo 'export PATH=\$PATH:\$JAVA_HOME/bin' >> ~/.bashrc
        fi
    "
    
    # Create a script with all the commands to run on the remote node
    cat > /tmp/nifi_setup_commands.sh <<EOF
    #!/bin/bash
    set -euo pipefail
    
    # Initialize all variables to avoid unbound variable errors
    JAR_COUNT=0
    nar_file=""
    NIFI_VERSION=""
    EXTRACTED_DIR=""
    SKIP_EXTRACTION=false
    SERVICE_FILE_FOUND=false
    nifi_pids=""
    still_running=""
    nifi_sh_pids=""
    total_mem_mb=4096  # Default to 4GB - Initialize early to avoid unbound variable errors
    
    # Pass environment variables from parent script
    SKIP_KILL="${SKIP_KILL:-false}"
    NIFI_USER="${NIFI_USER:-nifi}"
    NIFI_GROUP="${NIFI_GROUP:-nifi}"
    CREATE_USER="${CREATE_USER:-true}"
    RUN_AS_ROOT="${RUN_AS_ROOT:-false}"
    AUTO_MEMORY="${AUTO_MEMORY:-true}"
    NIFI_HEAP_INIT="${NIFI_HEAP_INIT:-""}"
    NIFI_HEAP_MAX="${NIFI_HEAP_MAX:-""}"
    NIFI_MEMORY_PERCENT="${NIFI_MEMORY_PERCENT:-75}"
    
    # Initialize SKIP_EXTRACTION to false by default
    SKIP_EXTRACTION=false
    
    # Check if NiFi directory exists
    if [[ -d "$NIFI_DIR" ]]; then
        echo "NiFi directory exists at $NIFI_DIR"
        
        # Check if it's a complete installation
        if [[ -f "$NIFI_DIR/bin/nifi.sh" ]]; then
            echo "Found complete NiFi installation"
            NIFI_VERSION=\$(basename "$NIFI_DIR")
            # We'll decide whether to skip extraction after cleanup
        else
            echo "Found incomplete NiFi installation - will reinstall"
        fi
        
        # Perform comprehensive NiFi cleanup
        echo "Performing comprehensive NiFi cleanup..."

# Check for processes using NiFi ports
echo "Checking for processes using NiFi ports..."
NIFI_PORTS=(8443 11443)
for port in "${NIFI_PORTS[@]}"; do
    pid=$(lsof -t -i:$port 2>/dev/null)
    if [[ -n "$pid" ]]; then
        echo "Found process using port $port: PID $pid"
        echo "Process details:"
        ps -f -p $pid
        
        # Kill the process
        echo "Killing process using port $port..."
        kill -15 $pid 2>/dev/null || true
        sleep 2
        
        # Force kill if still running
        if lsof -t -i:$port 2>/dev/null; then
            echo "Process still using port $port, force killing..."
            kill -9 $pid 2>/dev/null || true
        fi
    else
        echo "Port $port is available"
    fi
done

# Stop and disable NiFi service if it exists
if systemctl list-unit-files | grep -q "^nifi.service"; then
    echo "Stopping and disabling NiFi service..."
    systemctl stop nifi || true
    systemctl disable nifi || true
    rm -f /etc/systemd/system/nifi.service
    # Remove any systemd override files
    rm -rf /etc/systemd/system/nifi.service.d/
    systemctl daemon-reload
    echo "NiFi service removed."
else
    echo "No existing NiFi service found."
fi

# Kill any running NiFi processes
echo "Killing any running NiFi processes..."

# Skip kill operation if requested
if [[ "\${SKIP_KILL:-true}" == "true" ]]; then
    echo "Skipping kill operation as SKIP_KILL is set to true"
else
    # Find and kill all NiFi processes
    echo "Finding all NiFi processes..."
    
    # Find Java processes related to NiFi
    nifi_pids=\$(pgrep -f "java.*nifi" || echo "")
    if [[ -n "\$nifi_pids" ]]; then
        echo "Found NiFi Java processes: \$nifi_pids"
        for pid in \$nifi_pids; do
            echo "Killing NiFi Java process \$pid..."
            kill -15 \$pid 2>/dev/null || true
        done
        sleep 3
        
        # Check if processes are still running and force kill if necessary
        still_running=\$(pgrep -f "java.*nifi" || echo "")
        if [[ -n "\$still_running" ]]; then
            echo "Some NiFi processes still running, force killing: \$still_running"
            for pid in \$still_running; do
                kill -9 \$pid 2>/dev/null || true
            done
        fi
    fi
    
    # Find any nifi.sh processes
    nifi_sh_pids=\$(pgrep -f "nifi.sh" || echo "")
    if [[ -n "\$nifi_sh_pids" ]]; then
        echo "Found nifi.sh processes: \$nifi_sh_pids"
        for pid in \$nifi_sh_pids; do
            echo "Killing nifi.sh process \$pid..."
            kill -15 \$pid 2>/dev/null || true
        done
        sleep 2
        
        # Force kill if necessary
        still_running=\$(pgrep -f "nifi.sh" || echo "")
        if [[ -n "\$still_running" ]]; then
            echo "Some nifi.sh processes still running, force killing: \$still_running"
            for pid in \$still_running; do
                kill -9 \$pid 2>/dev/null || true
            done
        fi
    fi
    
    # Verify no NiFi processes are running
    if [[ -z "\$(pgrep -f 'java.*nifi\|nifi.sh' || echo '')" ]]; then
        echo "All NiFi processes successfully terminated."
    else
        echo "Warning: Some NiFi processes could not be terminated. Continuing anyway."
        echo "Running NiFi processes: \$(pgrep -f 'java.*nifi\|nifi.sh' || echo 'none')"
    fi
fi

echo "Proceeding with file cleanup..."

# Remove NiFi installation directory
echo "Removing NiFi installation directory..."
rm -rf "$NIFI_DIR"

# Special check for the case where only logs directory remains
if [[ -d "$NIFI_DIR" && "$(ls -A "$NIFI_DIR" 2>/dev/null | grep -v "logs")" == "" ]]; then
    echo "Found NiFi directory with only logs subdirectory - this is the issue we're fixing"
    echo "Preserving logs directory and removing parent directory..."
    
    # Temporarily move logs directory if it exists
    if [[ -d "$NIFI_DIR/logs" ]]; then
        mv "$NIFI_DIR/logs" "/tmp/nifi-logs-backup"
    fi
    
    # Remove the parent directory
    rm -rf "$NIFI_DIR"
    
    # Recreate the parent directory
    mkdir -p "$NIFI_DIR"
    
    # Restore logs directory if it was backed up
    if [[ -d "/tmp/nifi-logs-backup" ]]; then
        mv "/tmp/nifi-logs-backup" "$NIFI_DIR/logs"
    fi
    
    # Force extraction since we know the directory is incomplete
    SKIP_EXTRACTION=false
    echo "Handled the 'logs-only' directory case, will force extraction"
fi

# Check if directory was actually removed
if [[ ! -d "$NIFI_DIR" ]]; then
    echo "NiFi directory successfully removed"
    # Force extraction since directory is gone
    SKIP_EXTRACTION=false
else
    echo "Warning: NiFi directory still exists after removal attempt"
    # Check if it's a complete installation after removal attempt
    if [[ -f "$NIFI_DIR/bin/nifi.sh" && -d "$NIFI_DIR/lib" && -d "$NIFI_DIR/conf" ]]; then
        echo "Directory still contains a complete installation"
        # Verify critical files exist
        if [[ -f "$NIFI_DIR/conf/nifi.properties" && -f "$NIFI_DIR/conf/bootstrap.conf" ]]; then
            echo "All critical NiFi files verified, can use existing installation"
            SKIP_EXTRACTION=true
        else
            echo "Missing critical configuration files, will force extraction"
            SKIP_EXTRACTION=false
        fi
    else
        echo "Directory exists but installation is incomplete, will extract"
        SKIP_EXTRACTION=false
    fi
fi

# Remove NiFi data directories
echo "Removing NiFi data directories..."
rm -rf /var/lib/nifi
rm -rf /var/log/nifi
rm -rf /var/run/nifi
rm -rf /etc/nifi

# Remove NiFi user and group if they exist
if id "$NIFI_USER" &>/dev/null; then
    echo "Removing NiFi user ($NIFI_USER)..."
    userdel -r "$NIFI_USER" 2>/dev/null || true
fi
if getent group "$NIFI_GROUP" &>/dev/null; then
    echo "Removing NiFi group ($NIFI_GROUP)..."
    groupdel "$NIFI_GROUP" 2>/dev/null || true
fi

# Remove NiFi environment files
echo "Removing NiFi environment files..."
rm -f /etc/profile.d/nifi.sh
rm -f /etc/environment.d/nifi.conf

# Clean up temporary files
echo "Cleaning up temporary NiFi files..."
rm -rf /tmp/nifi*
rm -f /tmp/nifi-*.log
rm -f /tmp/nifi_*.pid

echo "NiFi cleanup completed."
echo "Setting up NiFi installation..."

# Check if we should skip extraction
if [[ "\$SKIP_EXTRACTION" == "true" && -d "$NIFI_DIR" && -f "$NIFI_DIR/bin/nifi.sh" ]]; then
    echo "Using existing complete NiFi installation, skipping extraction"
    NIFI_VERSION=$(basename "$NIFI_DIR")
else
    # If directory exists but is incomplete, or SKIP_EXTRACTION is false, proceed with extraction
    if [[ -d "$NIFI_DIR" && ! -f "$NIFI_DIR/bin/nifi.sh" ]]; then
        echo "NiFi directory exists but appears incomplete, forcing extraction"
        SKIP_EXTRACTION=false
    fi
    
    # Proceed with extraction
    # First check if tarball exists
    if [[ ! -f "/tmp/$(basename "$NIFI_TARBALL")" ]]; then
        echo "ERROR: NiFi tarball not found: /tmp/$(basename "$NIFI_TARBALL")"
        echo "Checking for any NiFi tarballs in /tmp:"
        ls -la /tmp/ | grep -i nifi
        exit 1
    fi
    
    # Backup the tarball to prevent it from being deleted during cleanup
    echo "Backing up NiFi tarball..."
    cp "/tmp/$(basename "$NIFI_TARBALL")" "/tmp/nifi-tarball-backup.zip"
    
    echo "Extracting NiFi to /tmp/..."
    
    # Check if extraction directory already exists and remove it
    if [[ -d "/tmp/$NIFI_VERSION" ]]; then
        echo "Removing existing extraction directory: /tmp/$NIFI_VERSION"
        rm -rf "/tmp/$NIFI_VERSION"
    fi
    
    # Check if unzip is installed, install if not
    if ! command -v unzip &> /dev/null; then
        echo "unzip command not found, installing..."
        apt-get update
        apt-get install -y unzip
    fi
    
    # Restore the tarball if it was deleted during cleanup
    if [[ ! -f "/tmp/$(basename "$NIFI_TARBALL")" && -f "/tmp/nifi-tarball-backup.zip" ]]; then
        echo "Restoring NiFi tarball from backup..."
        cp "/tmp/nifi-tarball-backup.zip" "/tmp/$(basename "$NIFI_TARBALL")"
    fi
    
    # Check if tarball exists again
    if [[ ! -f "/tmp/$(basename "$NIFI_TARBALL")" ]]; then
        echo "ERROR: NiFi tarball still not found after restoration attempt"
        echo "Checking for any NiFi tarballs in /tmp:"
        ls -la /tmp/ | grep -i nifi
        exit 1
    fi
    
    # Extract with more verbose output
    echo "Extracting tarball: /tmp/$(basename "$NIFI_TARBALL")"
    unzip -o /tmp/$(basename "$NIFI_TARBALL") -d /tmp/
    echo "Checking extracted files in /tmp/:"
    ls -la /tmp/ | grep nifi
    
    # Try to find the NiFi directory
    EXTRACTED_DIR=$(find /tmp -maxdepth 1 -type d -name "nifi*" | grep -v "nifi-certs" | head -n 1)
    
    if [[ -z "$EXTRACTED_DIR" ]]; then
        echo "WARNING: Could not find extracted NiFi directory"
        echo "Attempting extraction again with different method..."
        
        # Try alternative extraction method
        mkdir -p "/tmp/nifi-extract"
        unzip -o /tmp/$(basename "$NIFI_TARBALL") -d "/tmp/nifi-extract/"
        
        # Check again
        EXTRACTED_DIR=$(find /tmp -maxdepth 2 -type d -name "nifi*" | grep -v "nifi-certs" | head -n 1)
        
        if [[ -z "$EXTRACTED_DIR" ]]; then
            echo "ERROR: Still could not find extracted NiFi directory"
            exit 1
        fi
    fi
    
    echo "Found extracted NiFi directory: $EXTRACTED_DIR"
    NIFI_VERSION=$(basename "$EXTRACTED_DIR")
    SKIP_EXTRACTION=false
    
    # Remove existing NiFi directory if it exists
    if [[ -d "$NIFI_DIR" ]]; then
        echo "Removing existing NiFi directory: $NIFI_DIR"
        rm -rf "$NIFI_DIR"
    fi
    
    echo "Moving $EXTRACTED_DIR to $NIFI_DIR"
    mv "$EXTRACTED_DIR" "$NIFI_DIR" || {
        echo "Failed to move directory, trying copy method..."
        mkdir -p "$NIFI_DIR"
        cp -r "$EXTRACTED_DIR"/* "$NIFI_DIR/"
    }
fi
fi  # End of SKIP_EXTRACTION check

echo "Moved NiFi to $NIFI_DIR"
ls -la $NIFI_DIR

# Comprehensive verification of NiFi installation
echo "Performing comprehensive verification of NiFi installation..."

# Check if bin directory exists
if [[ ! -d "$NIFI_DIR/bin" ]]; then
    echo "ERROR: NiFi bin directory not found: $NIFI_DIR/bin"
    exit 1
fi

# Check if nifi.sh exists and is executable
if [[ ! -f "$NIFI_DIR/bin/nifi.sh" ]]; then
    echo "ERROR: NiFi script not found: $NIFI_DIR/bin/nifi.sh"
    exit 1
fi

# Make sure nifi.sh is executable
chmod +x "$NIFI_DIR/bin/nifi.sh"
ls -la "$NIFI_DIR/bin/nifi.sh"

# Check if conf directory exists
if [[ ! -d "$NIFI_DIR/conf" ]]; then
    echo "ERROR: NiFi conf directory not found: $NIFI_DIR/conf"
    exit 1
fi

# Check if key configuration files exist
if [[ ! -f "$NIFI_DIR/conf/nifi.properties" ]]; then
    echo "ERROR: nifi.properties not found: $NIFI_DIR/conf/nifi.properties"
    exit 1
fi

if [[ ! -f "$NIFI_DIR/conf/bootstrap.conf" ]]; then
    echo "ERROR: bootstrap.conf not found: $NIFI_DIR/conf/bootstrap.conf"
    exit 1
fi

# Check if lib directory exists and has content
if [[ ! -d "$NIFI_DIR/lib" ]]; then
    echo "ERROR: NiFi lib directory not found: $NIFI_DIR/lib"
    exit 1
fi

# Count JAR files in lib directory
JAR_COUNT=$(find "$NIFI_DIR/lib" -name "*.jar" | wc -l)
if [[ $JAR_COUNT -eq 0 ]]; then
    echo "WARNING: No JAR files found in $NIFI_DIR/lib"
else
    echo "Found $JAR_COUNT JAR files in $NIFI_DIR/lib"
fi

echo "NiFi installation verification completed successfully"

# Setup certificates
mkdir -p "$NIFI_DIR/certs"
cp /tmp/nifi${id}-keystore.p12 "$NIFI_DIR/certs/nifi${id}-keystore.p12"
cp /tmp/nifi-truststore.p12 "$NIFI_DIR/certs/nifi-truststore.p12"

# Set proper permissions on certificate files
chmod 644 "$NIFI_DIR/certs/nifi${id}-keystore.p12"
chmod 644 "$NIFI_DIR/certs/nifi-truststore.p12"

# Verify the certificate files were copied correctly
echo "Verifying certificate files in $NIFI_DIR/certs..."
ls -la "$NIFI_DIR/certs/"

# Verify the truststore is valid in final location
echo "Verifying truststore validity in final location..."
keytool -list -keystore "$NIFI_DIR/certs/nifi-truststore.p12" -storepass "$KEYSTORE_PASS" -storetype PKCS12 || {
    echo "ERROR: Truststore verification failed in final location"
    exit 1
}

# Verify the keystore is valid in final location
echo "Verifying keystore validity in final location..."
keytool -list -keystore "$NIFI_DIR/certs/nifi${id}-keystore.p12" -storepass "$KEYSTORE_PASS" -storetype PKCS12 || {
    echo "ERROR: Keystore verification failed in final location"
    exit 1
}

# Verify the truststore is valid
echo "Verifying truststore validity..."
keytool -list -keystore "$NIFI_DIR/certs/nifi-truststore.p12" -storepass "$KEYSTORE_PASS" -storetype PKCS12 || {
    echo "ERROR: Truststore verification failed"
    exit 1
}

# Copy custom NAR files if available
if [[ -d "/tmp/custom_nars" ]]; then
    echo "Copying custom NAR files from /tmp/custom_nars..."
    find "/tmp/custom_nars" -name "*.nar" -type f -print | while read -r nar_file; do
        echo "Copying NAR file: $(basename "$nar_file")"
        cp "$nar_file" "$NIFI_DIR/lib/"
    done
    echo "Custom NAR files copied."
fi

# Configure NiFi properties
config_dir="$NIFI_DIR/conf"
sensitive_props_key=\$(openssl rand -hex 16)

# Update nifi.properties
sed -i "s|nifi.sensitive.props.key=.*|nifi.sensitive.props.key=\$sensitive_props_key|" "\$config_dir/nifi.properties"

# Get the actual IP address of this node (the remote node)
ACTUAL_IP=\$(hostname -I | awk '{print \$1}')
echo "Remote node actual IP: \$ACTUAL_IP"
echo "IP passed from main script: $ip"

# Remove any leading slash from the IP address
ACTUAL_IP=\${ACTUAL_IP#/}
echo "Cleaned IP address: \$ACTUAL_IP"

# Use the actual IP of the remote node, not the one passed from the main script
echo "Setting web.https.host to the actual remote node IP: \$ACTUAL_IP"
sed -i "s|nifi.web.https.host=.*|nifi.web.https.host=\$ACTUAL_IP|" "\$config_dir/nifi.properties"
sed -i "s|nifi.web.https.port=.*|nifi.web.https.port=8443|" "\$config_dir/nifi.properties"
sed -i "s|nifi.security.keystore=.*|nifi.security.keystore=$NIFI_DIR/certs/nifi${id}-keystore.p12|" "\$config_dir/nifi.properties"
sed -i "s|nifi.security.keystoreType=.*|nifi.security.keystoreType=PKCS12|" "\$config_dir/nifi.properties"
# Set certificate and private key aliases
sed -i "s|nifi.security.keystore.certificate=.*|nifi.security.keystore.certificate=nifi-key|" "\$config_dir/nifi.properties"
sed -i "s|nifi.security.keystore.privateKey=.*|nifi.security.keystore.privateKey=nifi-key|" "\$config_dir/nifi.properties"
sed -i "s|nifi.security.truststore=.*|nifi.security.truststore=$NIFI_DIR/certs/nifi-truststore.p12|" "\$config_dir/nifi.properties"
sed -i "s|nifi.security.truststoreType=.*|nifi.security.truststoreType=PKCS12|" "\$config_dir/nifi.properties"
# Remove the truststore certificate property as it's not needed for PKCS12 truststores
# and can cause the "Some truststore properties are populated but not valid" warning
sed -i "s|nifi.security.truststore.certificate=.*|# nifi.security.truststore.certificate is not needed for PKCS12 truststores|" "\$config_dir/nifi.properties"
sed -i "s|nifi.security.keystorePasswd=.*|nifi.security.keystorePasswd=$KEYSTORE_PASS|" "\$config_dir/nifi.properties"
sed -i "s|nifi.security.keyPasswd=.*|nifi.security.keyPasswd=$KEYSTORE_PASS|" "\$config_dir/nifi.properties"
sed -i "s|nifi.security.truststorePasswd=.*|nifi.security.truststorePasswd=$KEYSTORE_PASS|" "\$config_dir/nifi.properties"
sed -i "s|nifi.cluster.is.node=false|nifi.cluster.is.node=true|" "\$config_dir/nifi.properties"
sed -i "s|nifi.cluster.protocol.is.secure=false|nifi.cluster.protocol.is.secure=true|" "\$config_dir/nifi.properties"
# Use the actual IP for cluster node address as well (ensure no leading slash)
sed -i "s|nifi.cluster.node.address=.*|nifi.cluster.node.address=\$ACTUAL_IP|" "\$config_dir/nifi.properties"
sed -i "s|nifi.cluster.node.protocol.port=.*|nifi.cluster.node.protocol.port=11443|" "\$config_dir/nifi.properties"
sed -i "s|nifi.zookeeper.connect.string=.*|nifi.zookeeper.connect.string=$ZK_CONNECT|" "\$config_dir/nifi.properties"

# Update state-management.xml
sed -i "s|<property name=\"Connect String\"></property>|<property name=\"Connect String\">$ZK_CONNECT</property>|" "\$config_dir/state-management.xml"

# Configure memory settings
echo "Configuring memory settings..."

# Determine memory settings
# Note: total_mem_mb is already initialized at the beginning of the script
if [[ "${AUTO_MEMORY:-true}" == "true" ]]; then
    # Skip memory detection entirely and use hardcoded values
    echo "Using default memory setting: ${total_mem_mb}MB"
    
    # Calculate memory to use based on percentage - with explicit initialization
    usable_mem_mb=$((total_mem_mb * ${NIFI_MEMORY_PERCENT:-75} / 100))
    echo "Usable memory (${NIFI_MEMORY_PERCENT:-75}%): ${usable_mem_mb}MB"
    
    # Initialize heap variables with defaults
    init_heap_mb=1024  # Default to 1GB
    max_heap_mb=2048   # Default to 2GB
    
    # Set initial heap to 40% of usable memory
    init_heap_mb=$((usable_mem_mb * 40 / 100))
    # Set max heap to 80% of usable memory
    max_heap_mb=$((usable_mem_mb * 80 / 100))
    
    # Initialize GB variables with defaults
    init_heap_gb=1  # Default to 1GB
    max_heap_gb=2   # Default to 2GB
    
    # Convert to GB for readability, with minimum values
    init_heap_gb=$(( init_heap_mb < 1024 ? 1 : init_heap_mb / 1024 ))
    max_heap_gb=$(( max_heap_mb < 2048 ? 2 : max_heap_mb / 1024 ))
    
    # Ensure max is at least 1GB more than init
    if (( max_heap_gb - init_heap_gb < 1 )); then
        max_heap_gb=$((init_heap_gb + 1))
    fi
    
    echo "Auto-configured memory: Initial=${init_heap_gb}g, Max=${max_heap_gb}g"
    
    # Initialize heap strings with defaults
    init_heap="1g"  # Default to 1GB
    max_heap="2g"   # Default to 2GB
    
    # Set the values
    init_heap="${init_heap_gb}g"
    max_heap="${max_heap_gb}g"
else
    # Initialize with defaults first
    init_heap="4g"
    max_heap="8g"
    
    # Use provided values or defaults
    init_heap=${NIFI_HEAP_INIT:-"4g"}
    max_heap=${NIFI_HEAP_MAX:-"8g"}
    echo "Using configured memory: Initial=${init_heap}, Max=${max_heap}"
fi

# Update bootstrap.conf with memory settings
sed -i "s|java.arg.2=-Xms[0-9]*[kmg]|java.arg.2=-Xms${init_heap}|" "\$config_dir/bootstrap.conf"
sed -i "s|java.arg.3=-Xmx[0-9]*[kmg]|java.arg.3=-Xmx${max_heap}|" "\$config_dir/bootstrap.conf"

# Add or update garbage collection settings
if ! grep -q "java.arg.13=-XX:+UseG1GC" "\$config_dir/bootstrap.conf"; then
    echo "Adding G1GC garbage collector settings..."
    echo "java.arg.13=-XX:+UseG1GC" >> "\$config_dir/bootstrap.conf"
    echo "java.arg.14=-XX:+ExplicitGCInvokesConcurrent" >> "\$config_dir/bootstrap.conf"
    echo "java.arg.15=-XX:+ParallelRefProcEnabled" >> "\$config_dir/bootstrap.conf"
    echo "java.arg.16=-XX:+DisableExplicitGC" >> "\$config_dir/bootstrap.conf"
    echo "java.arg.17=-XX:+AlwaysPreTouch" >> "\$config_dir/bootstrap.conf"
fi

# Add JAVA_HOME to bootstrap.conf if not already present
if ! grep -q "^java.home=" "\$config_dir/bootstrap.conf"; then
    echo "java.home=$JAVA_HOME" >> "\$config_dir/bootstrap.conf"
fi

# Determine which user/group to use
SERVICE_USER="$NIFI_USER"
SERVICE_GROUP="$NIFI_GROUP"

if [[ "\${RUN_AS_ROOT:-false}" == "true" ]]; then
    echo "Warning: Running NiFi as root is not recommended for production environments"
    SERVICE_USER="root"
    SERVICE_GROUP="root"
fi

# Create NiFi user and group if needed
if [[ "\${CREATE_USER:-true}" == "true" && "\${RUN_AS_ROOT:-false}" != "true" ]]; then
    echo "Creating NiFi user and group..."
    
    # Create group if it doesn't exist
    if ! getent group "$SERVICE_GROUP" &>/dev/null; then
        groupadd "$SERVICE_GROUP"
        echo "Created group: $SERVICE_GROUP"
    else
        echo "Group already exists: $SERVICE_GROUP"
    fi
    
    # Create user if it doesn't exist
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd -r -g "$SERVICE_GROUP" -d "$NIFI_DIR" -s /bin/bash "$SERVICE_USER"
        echo "Created user: $SERVICE_USER"
    else
        echo "User already exists: $SERVICE_USER"
    fi
    
    # Set proper permissions on NiFi directories
    echo "Setting proper permissions on NiFi directories..."
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$NIFI_DIR"
    chmod -R 750 "$NIFI_DIR"
    
    # Ensure sensitive directories have proper permissions
    chmod 700 "$NIFI_DIR/conf"
    chmod 700 "$NIFI_DIR/certs"
    
    # Create data directories with proper permissions
    echo "Creating NiFi data directories with proper permissions..."
    mkdir -p /var/lib/nifi /var/log/nifi /var/run/nifi
    chown -R "$SERVICE_USER:$SERVICE_GROUP" /var/lib/nifi /var/log/nifi /var/run/nifi
    chmod 750 /var/lib/nifi /var/log/nifi /var/run/nifi
    
    # Create repository directories with proper permissions
    echo "Creating NiFi repository directories with proper permissions..."
    mkdir -p "$NIFI_DIR/flowfile_repository" \
             "$NIFI_DIR/content_repository" \
             "$NIFI_DIR/provenance_repository" \
             "$NIFI_DIR/state/local" \
             "$NIFI_DIR/database_repository"
    chown -R "$SERVICE_USER:$SERVICE_GROUP" "$NIFI_DIR/flowfile_repository" \
                                          "$NIFI_DIR/content_repository" \
                                          "$NIFI_DIR/provenance_repository" \
                                          "$NIFI_DIR/state/local" \
                                          "$NIFI_DIR/database_repository"
    chmod -R 750 "$NIFI_DIR/flowfile_repository" \
                 "$NIFI_DIR/content_repository" \
                 "$NIFI_DIR/provenance_repository" \
                 "$NIFI_DIR/state/local" \
                 "$NIFI_DIR/database_repository"
    
    # Update bootstrap.conf to use the correct user
    echo "Updating bootstrap.conf to use the correct user..."
    if ! grep -q "^run.as=" "$NIFI_DIR/conf/bootstrap.conf"; then
        echo "run.as=$SERVICE_USER" >> "$NIFI_DIR/conf/bootstrap.conf"
    else
        sed -i "s|^run.as=.*|run.as=$SERVICE_USER|" "$NIFI_DIR/conf/bootstrap.conf"
    fi
fi

# Create service file
if [[ -f "/tmp/nifi.service" ]]; then
    echo "Found pre-created nifi.service file, using it."
    sudo cp /tmp/nifi.service /etc/systemd/system/nifi.service
    # Update the service file with the correct paths and user/group
    sudo sed -i "s|NIFI_DIR|$NIFI_DIR|g" /etc/systemd/system/nifi.service
    sudo sed -i "s|SERVICE_USER|$SERVICE_USER|g" /etc/systemd/system/nifi.service
    sudo sed -i "s|SERVICE_GROUP|$SERVICE_GROUP|g" /etc/systemd/system/nifi.service
else
    echo "Pre-created service file not found, creating dynamically."
    cat > /tmp/nifi.service << 'NIFISERVICE'
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
NIFISERVICE
    sudo cp /tmp/nifi.service /etc/systemd/system/nifi.service
    rm -f /tmp/nifi.service
fi

# Create a proper SysV init script as a fallback
cat > /etc/init.d/nifi <<NIFI_INIT
#!/bin/sh
### BEGIN INIT INFO
# Provides:          nifi
# Required-Start:    \$remote_fs \$syslog
# Required-Stop:     \$remote_fs \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Apache NiFi
# Description:       Apache NiFi data flow system
### END INIT INFO

# Source function library
. /lib/lsb/init-functions

NIFI_DIR=$NIFI_DIR
NIFI_USER=$SERVICE_USER
NIFI_GROUP=$SERVICE_GROUP
JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

case "\$1" in
    start)
        log_daemon_msg "Starting Apache NiFi" "nifi"
        if [ -f \$NIFI_DIR/bin/nifi-wrapper.sh ]; then
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi-wrapper.sh start"
        else
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi.sh start"
        fi
        log_end_msg \$?
        ;;
    stop)
        log_daemon_msg "Stopping Apache NiFi" "nifi"
        if [ -f \$NIFI_DIR/bin/nifi-wrapper.sh ]; then
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi-wrapper.sh stop"
        else
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi.sh stop"
        fi
        log_end_msg \$?
        ;;
    restart)
        \$0 stop
        sleep 2
        \$0 start
        ;;
    status)
        if [ -f \$NIFI_DIR/bin/nifi-wrapper.sh ]; then
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi-wrapper.sh status"
        else
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi.sh status"
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
NIFI_INIT

# Make the init script executable
chmod +x /etc/init.d/nifi

# Update the init script links
update-rc.d nifi defaults

# Create a proper SysV init script as a fallback only if we don't have systemd
if ! command -v systemctl &> /dev/null; then
    echo "Systemd not found, creating SysV init script as fallback"
    cat > /etc/init.d/nifi <<NIFI_INIT
#!/bin/sh
### BEGIN INIT INFO
# Provides:          nifi
# Required-Start:    \$remote_fs \$syslog
# Required-Stop:     \$remote_fs \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Apache NiFi
# Description:       Apache NiFi data flow system
### END INIT INFO

# Source function library
. /lib/lsb/init-functions

NIFI_DIR=$NIFI_DIR
NIFI_USER=$SERVICE_USER
NIFI_GROUP=$SERVICE_GROUP
JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

case "\$1" in
    start)
        log_daemon_msg "Starting Apache NiFi" "nifi"
        if [ -f \$NIFI_DIR/bin/nifi-wrapper.sh ]; then
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi-wrapper.sh start"
        else
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi.sh start"
        fi
        log_end_msg \$?
        ;;
    stop)
        log_daemon_msg "Stopping Apache NiFi" "nifi"
        if [ -f \$NIFI_DIR/bin/nifi-wrapper.sh ]; then
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi-wrapper.sh stop"
        else
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi.sh stop"
        fi
        log_end_msg \$?
        ;;
    restart)
        \$0 stop
        sleep 2
        \$0 start
        ;;
    status)
        if [ -f \$NIFI_DIR/bin/nifi-wrapper.sh ]; then
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi-wrapper.sh status"
        else
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi.sh status"
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
NIFI_INIT
fi

# Make the init script executable
chmod +x /etc/init.d/nifi

# Update the init script links
update-rc.d nifi defaults

# Start NiFi
systemctl daemon-reload
systemctl enable --force nifi

# Verify NiFi installation before starting
echo "Verifying NiFi installation..."
if [ ! -f "$NIFI_DIR/bin/nifi.sh" ]; then
    echo "ERROR: NiFi script not found at $NIFI_DIR/bin/nifi.sh"
    ls -la $NIFI_DIR/bin/
    exit 1
fi

# Make sure nifi.sh is executable
chmod +x "$NIFI_DIR/bin/nifi.sh"
ls -la $NIFI_DIR/bin/nifi.sh

# Directly modify nifi.sh to set JAVA_HOME at the beginning of the script
echo "Patching nifi.sh to hardcode JAVA_HOME..."
# Create a backup of the original script
cp "$NIFI_DIR/bin/nifi.sh" "$NIFI_DIR/bin/nifi.sh.bak"

# Add JAVA_HOME setting at the beginning of the script (after the shebang line)
# Use a more direct approach to ensure the script is modified correctly
cat > /tmp/nifi_java_home_fix.sh <<EOF
#!/bin/bash
# Hardcoded JAVA_HOME setting
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
if [ ! -d "\$JAVA_HOME" ]; then
  export JAVA_HOME=/usr/lib/jvm/default-java
fi
if [ ! -d "\$JAVA_HOME" ]; then
  export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
fi
if [ ! -d "\$JAVA_HOME" ]; then
  export JAVA_HOME=\$(find /usr/lib/jvm -maxdepth 1 -type d -name "java*" | head -n 1)
fi
echo "Using JAVA_HOME=\$JAVA_HOME"

EOF

# Get the original nifi.sh content (skipping the first line which is the shebang)
tail -n +2 "$NIFI_DIR/bin/nifi.sh" >> /tmp/nifi_java_home_fix.sh

# Make the new script executable
chmod +x /tmp/nifi_java_home_fix.sh

# Replace the original script with our modified version
cp /tmp/nifi_java_home_fix.sh "$NIFI_DIR/bin/nifi.sh"

# Verify the modification
echo "Verifying nifi.sh modification..."
head -n 20 "$NIFI_DIR/bin/nifi.sh"

# Check if Java is installed and set JAVA_HOME
echo "Checking Java installation..."
java -version || {
    echo "ERROR: Java not found. Installing Java..."
    apt-get update
    apt-get install -y default-jre default-jdk
}

# Find and set JAVA_HOME
echo "Setting JAVA_HOME..."
# Initialize JAVA_HOME to avoid unbound variable error
JAVA_HOME=${JAVA_HOME:-""}
if [ -z "$JAVA_HOME" ]; then
    # Try to find Java home directory
    if [ -d "/usr/lib/jvm/default-java" ]; then
        JAVA_HOME="/usr/lib/jvm/default-java"
    elif [ -d "/usr/lib/jvm/java-11-openjdk-amd64" ]; then
        JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64"
    elif [ -d "/usr/lib/jvm/java-8-openjdk-amd64" ]; then
        JAVA_HOME="/usr/lib/jvm/java-8-openjdk-amd64"
    else
        # Find any JVM directory
        JAVA_HOME=$(find /usr/lib/jvm -maxdepth 1 -type d -name "java*" | head -n 1)
    fi
    
    if [ -n "$JAVA_HOME" ]; then
        echo "Found JAVA_HOME: $JAVA_HOME"
        
        # Add JAVA_HOME to system-wide environment
        echo "JAVA_HOME=$JAVA_HOME" >> /etc/environment
        
        # Add JAVA_HOME to nifi.service with hardcoded path
        sed -i "/\\[Service\\]/a Environment=JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64" /etc/systemd/system/nifi.service
        
        # Export for current session
        export JAVA_HOME="$JAVA_HOME"
    else
        echo "ERROR: Could not find JAVA_HOME directory"
        exit 1
    fi
fi

# Verify certificates
echo "Verifying certificates..."
ls -la $NIFI_DIR/certs/

# Check service file content
echo "Checking service file content..."
cat /etc/systemd/system/nifi.service

# Check NiFi configuration
echo "Checking NiFi configuration..."
cat $NIFI_DIR/conf/nifi.properties | grep -E "nifi.web.https.host|nifi.security.keystore|nifi.security.truststore|nifi.zookeeper.connect.string"

# Verify certificate settings in nifi.properties
echo "Verifying certificate settings in nifi.properties..."
grep -E "nifi.security.(keystore|truststore)" $NIFI_DIR/conf/nifi.properties

# Try running nifi.sh directly
echo "Trying to run nifi.sh directly..."
$NIFI_DIR/bin/nifi.sh status || echo "Failed to run nifi.sh directly"

# Create a systemd override directory
echo "Creating systemd override directory..."
mkdir -p /etc/systemd/system/nifi.service.d/

# Create an override file to set JAVA_HOME
echo "Creating systemd override file..."
cat > /etc/systemd/system/nifi.service.d/override.conf <<EOF
[Service]
Environment="JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64"
EOF

# Also add JAVA_HOME to bootstrap.conf
echo "Adding JAVA_HOME to bootstrap.conf..."
if ! grep -q "^java.home=" "$NIFI_DIR/conf/bootstrap.conf"; then
    echo "java.home=$JAVA_HOME" >> "$NIFI_DIR/conf/bootstrap.conf"
fi

# Create a wrapper script for nifi.sh
echo "Creating wrapper script for nifi.sh..."
# Create a more robust wrapper script
cat > /tmp/nifi-wrapper.sh <<EOF
#!/bin/bash
# Hardcoded JAVA_HOME setting
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
if [ ! -d "\$JAVA_HOME" ]; then
  export JAVA_HOME=/usr/lib/jvm/default-java
fi
if [ ! -d "\$JAVA_HOME" ]; then
  export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
fi
if [ ! -d "\$JAVA_HOME" ]; then
  export JAVA_HOME=\$(find /usr/lib/jvm -maxdepth 1 -type d -name "java*" | head -n 1)
fi
echo "Using JAVA_HOME=\$JAVA_HOME"

# Ensure JAVA_HOME is passed to the nifi.sh script
$NIFI_DIR/bin/nifi.sh "\$@"
EOF
chmod +x /tmp/nifi-wrapper.sh
mv /tmp/nifi-wrapper.sh $NIFI_DIR/bin/nifi-wrapper.sh

# Update service file to use wrapper script
echo "Updating service file to use wrapper script..."
sed -i "s|ExecStart=$NIFI_DIR/bin/nifi.sh start|ExecStart=$NIFI_DIR/bin/nifi-wrapper.sh start|" /etc/systemd/system/nifi.service
sed -i "s|ExecStop=$NIFI_DIR/bin/nifi.sh stop|ExecStop=$NIFI_DIR/bin/nifi-wrapper.sh stop|" /etc/systemd/system/nifi.service

# Reload systemd and start NiFi
echo "Starting NiFi service..."
systemctl daemon-reload

# Check for common issues before starting NiFi
echo "Checking for common issues before starting NiFi..."

# Check permissions on NiFi directories
echo "Checking permissions on NiFi directories..."
if [[ "\${RUN_AS_ROOT:-false}" == "true" ]]; then
    chown -R root:root $NIFI_DIR
    chmod -R 755 $NIFI_DIR
    chmod 700 $NIFI_DIR/conf
else
    chown -R $SERVICE_USER:$SERVICE_GROUP $NIFI_DIR
    chmod -R 750 $NIFI_DIR
    chmod 700 $NIFI_DIR/conf
fi

# Verify certificate files
echo "Verifying certificate files..."
ls -la $NIFI_DIR/certs/
file $NIFI_DIR/certs/nifi-truststore.p12
file $NIFI_DIR/certs/nifi*-keystore.p12

# Check if ports are already in use
echo "Checking if ports are already in use..."
netstat -tuln | grep 8443 || echo "Port 8443 is available"
netstat -tuln | grep 11443 || echo "Port 11443 is available"

# Check if there are any existing NiFi processes
echo "Checking for existing NiFi processes..."
ps aux | grep nifi

# Check disk space
echo "Checking disk space..."
df -h

# Check memory
echo "Checking memory..."
free -h

# Add more detailed logging to bootstrap.conf
echo "Enabling detailed logging..."
if ! grep -q "org.slf4j.simpleLogger.defaultLogLevel=DEBUG" "$NIFI_DIR/conf/bootstrap.conf"; then
    echo "org.slf4j.simpleLogger.defaultLogLevel=DEBUG" >> "$NIFI_DIR/conf/bootstrap.conf"
fi

# Start NiFi with debug output
echo "Starting NiFi with debug output..."
systemctl start nifi

# Give NiFi more time to start up
echo "Waiting for NiFi to start (this may take a minute)..."
sleep 30

# Check service status
echo "Checking NiFi service status..."
systemctl status nifi --no-pager

# Check if service is running
if systemctl is-active nifi >/dev/null 2>&1; then
    echo "✅ NiFi service is running!"
else
    echo "⚠️ NiFi service is not running. Checking logs..."
fi

# Check logs regardless of service status
echo "Checking systemd journal logs..."
journalctl -xeu nifi.service --no-pager | tail -n 50

# Add a more comprehensive log check
echo "Performing comprehensive log check..."
if [ -d "$NIFI_DIR/logs" ]; then
    echo "Checking all log files in $NIFI_DIR/logs:"
    find "$NIFI_DIR/logs" -type f -name "*.log" | while read -r logfile; do
        echo "=== Last 50 lines of $(basename "$logfile") ==="
        tail -n 50 "$logfile"
        echo ""
        
        # Check for specific errors in the log file
        echo "Checking for errors in $(basename "$logfile"):"
        grep -i "error\|exception\|fail" "$logfile" | tail -n 20 || echo "No errors found"
        echo ""
    done
fi

# Check if ZooKeeper is running and accessible
echo "Checking ZooKeeper connectivity..."
if command -v nc &> /dev/null; then
    for zk_host in $(echo "$ZK_CONNECT" | tr ',' ' '); do
        host=$(echo "$zk_host" | cut -d: -f1)
        port=$(echo "$zk_host" | cut -d: -f2)
        echo "Testing connection to ZooKeeper at $host:$port"
        nc -z -v -w5 "$host" "$port" || echo "Failed to connect to ZooKeeper at $host:$port"
    done
fi

# Check NiFi logs
echo "Checking NiFi logs..."
if [ -d "$NIFI_DIR/logs" ]; then
    ls -la $NIFI_DIR/logs/
    if [ -f "$NIFI_DIR/logs/nifi-app.log" ]; then
        echo "Last 50 lines of nifi-app.log:"
        tail -n 50 $NIFI_DIR/logs/nifi-app.log
    fi
    
    if [ -f "$NIFI_DIR/logs/nifi-bootstrap.log" ]; then
        echo "Last 50 lines of nifi-bootstrap.log:"
        tail -n 50 $NIFI_DIR/logs/nifi-bootstrap.log
    fi
fi

# Check if there are any permission issues
echo "Checking for permission issues..."
ls -la $NIFI_DIR/
ls -la $NIFI_DIR/conf/

# Verify bootstrap.conf settings
echo "Verifying bootstrap.conf settings..."
grep -E "^java.home=|^java.arg.2=|^java.arg.3=" $NIFI_DIR/conf/bootstrap.conf

# Try running nifi.sh directly with debug
echo "Trying to run nifi.sh directly with debug..."
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
if [ ! -d "$JAVA_HOME" ]; then
  export JAVA_HOME=/usr/lib/jvm/default-java
fi
if [ ! -d "$JAVA_HOME" ]; then
  export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
fi
if [ ! -d "$JAVA_HOME" ]; then
  export JAVA_HOME=$(find /usr/lib/jvm -maxdepth 1 -type d -name "java*" | head -n 1)
fi
echo "Using JAVA_HOME=$JAVA_HOME"

# Create a direct test script to verify JAVA_HOME is being set
cat > /tmp/test_java_home.sh <<TEST_EOF
#!/bin/bash
echo "JAVA_HOME in test script: \$JAVA_HOME"
TEST_EOF
chmod +x /tmp/test_java_home.sh
./tmp/test_java_home.sh

# Run nifi.sh with explicit JAVA_HOME
JAVA_HOME=$JAVA_HOME $NIFI_DIR/bin/nifi.sh status

echo "NiFi node $id configured and started on $ip"
EOF

    # Check for a pre-existing nifi.service file to copy to the remote node
    local service_file_to_copy=""
    for service_file_path in "/opt/nifi-zk-auto-deployment/nifi.service" "./nifi.service" "../nifi.service"; do
        if [[ -f "$service_file_path" ]]; then
            echo "Found nifi.service file at: $service_file_path, will copy to remote node."
            service_file_to_copy="$service_file_path"
            break
        fi
    done

    # If a service file was found, copy it to the remote node
    if [[ -n "$service_file_to_copy" ]]; then
        echo "$(date '+%F %T') | ℹ️ Copying service file to remote node..." | tee -a "$LOG_FILE"
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "$service_file_to_copy" "$user@$ip:/tmp/nifi.service" || {
            echo "$(date '+%F %T') | ⚠️ Failed to copy service file, remote node will generate one." | tee -a "$LOG_FILE"
        }
    fi

    # Create a directory on the remote node for the tarball
    ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "mkdir -p /tmp/nifi_setup"
    
    # Copy the tarball to the remote node with more reliable options
    echo "$(date '+%F %T') | ℹ️ Copying NiFi tarball to remote node..." | tee -a "$LOG_FILE"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        "$NIFI_TARBALL" "$user@$ip:/tmp/nifi_setup/"
    
    # Verify the tarball was copied successfully
    ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "if [[ -f \"/tmp/nifi_setup/$(basename "$NIFI_TARBALL")\" ]]; then
            echo \"Tarball copied successfully\";
            ln -sf \"/tmp/nifi_setup/$(basename "$NIFI_TARBALL")\" \"/tmp/$(basename "$NIFI_TARBALL")\";
         else
            echo \"Failed to copy tarball\";
            exit 1;
         fi"
    # Debug: Show hostname and SERVER_HOSTS array
    echo "$(date '+%F %T') | ℹ️ Remote node setup - Host: $host, IP: $ip, User: $user" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | ℹ️ Node ID: $id" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | ℹ️ SERVER_HOSTS[$((id-1))]: ${SERVER_HOSTS[id-1]}" | tee -a "$LOG_FILE"
    
    # Debug: List certificate directories
    echo "$(date '+%F %T') | ℹ️ Listing certificate directories:" | tee -a "$LOG_FILE"
    ls -la "$CERT_DIR/" | tee -a "$LOG_FILE"
    
    # Check if certificate files exist
    echo "$(date '+%F %T') | ℹ️ Checking certificate files for remote node..." | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | ℹ️ Expected keystore path: $CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | ℹ️ Truststore path: $CERT_DIR/CA/nifi-rootCA.pem" | tee -a "$LOG_FILE"
    
    # More flexible keystore path finding
    KEYSTORE_PATH=""
    
    # Try exact match first
    if [[ -f "$CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12" ]]; then
        echo "$(date '+%F %T') | ✅ Found keystore at expected path: $CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12" | tee -a "$LOG_FILE"
        KEYSTORE_PATH="$CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12"
    else
        # Try using the host directly
        if [[ -f "$CERT_DIR/$host/keystore.p12" ]]; then
            echo "$(date '+%F %T') | ✅ Found keystore using host: $CERT_DIR/$host/keystore.p12" | tee -a "$LOG_FILE"
            KEYSTORE_PATH="$CERT_DIR/$host/keystore.p12"
        else
            # Try case-insensitive or partial match
            local host_pattern="${SERVER_HOSTS[id-1]}"
            local found_dir=$(find "$CERT_DIR" -maxdepth 1 -type d -name "*${host_pattern}*" | head -n 1)
            
            if [[ -n "$found_dir" && -f "$found_dir/keystore.p12" ]]; then
                echo "$(date '+%F %T') | ✅ Found keystore using pattern match: $found_dir/keystore.p12" | tee -a "$LOG_FILE"
                KEYSTORE_PATH="$found_dir/keystore.p12"
            else
                # Try any keystore.p12 file in any subdirectory
                local any_keystore=$(find "$CERT_DIR" -name "keystore.p12" | head -n 1)
                
                if [[ -n "$any_keystore" ]]; then
                    echo "$(date '+%F %T') | ✅ Found keystore using general search: $any_keystore" | tee -a "$LOG_FILE"
                    KEYSTORE_PATH="$any_keystore"
                else
                    # If all else fails, show detailed error information
                    echo "$(date '+%F %T') | ❌ ERROR: Keystore file not found: $CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12" | tee -a "$LOG_FILE"
                    
                    # List all subdirectories and files for debugging
                    echo "$(date '+%F %T') | ℹ️ Listing all subdirectories in $CERT_DIR:" | tee -a "$LOG_FILE"
                    find "$CERT_DIR" -maxdepth 3 -type d | tee -a "$LOG_FILE"
                    
                    echo "$(date '+%F %T') | ℹ️ Searching for any keystore files:" | tee -a "$LOG_FILE"
                    find "$CERT_DIR" -type f \( -name "*.p12" -o -name "*.jks" \) | tee -a "$LOG_FILE"
                    
                    echo "$(date '+%F %T') | ❌ ERROR: Could not find any usable keystore file for remote node" | tee -a "$LOG_FILE"
                    return 1
                fi
            fi
        fi
    fi
    
    if [[ ! -f "$CERT_DIR/CA/nifi-rootCA.pem" ]]; then
        echo "$(date '+%F %T') | ❌ ERROR: Truststore file not found: $CERT_DIR/CA/nifi-rootCA.pem" | tee -a "$LOG_FILE"
        
        # Try to find the truststore file
        echo "$(date '+%F %T') | ℹ️ Searching for truststore files in certificate directory..." | tee -a "$LOG_FILE"
        find "$CERT_DIR" -name "nifi-rootCA.pem" | tee -a "$LOG_FILE"
        
        echo "$(date '+%F %T') | ❌ ERROR: Could not find truststore file for remote node" | tee -a "$LOG_FILE"
        return 1
    fi
    
    echo "$(date '+%F %T') | ℹ️ Copying certificate files to remote node..." | tee -a "$LOG_FILE"
    # Create a dedicated directory for certificate transfer to avoid truncation issues
    ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "mkdir -p /tmp/nifi_certs"
    
    # Use more reliable SCP options to prevent truncation
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        "$KEYSTORE_PATH" "$user@$ip:/tmp/nifi_certs/nifi${id}-keystore.p12" || {
        echo "$(date '+%F %T') | ❌ ERROR: Failed to copy keystore file to remote node" | tee -a "$LOG_FILE"
        return 1
    }
    
    # Create a symlink to the expected location
    ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "ln -sf /tmp/nifi_certs/nifi${id}-keystore.p12 /tmp/nifi${id}-keystore.p12"
    
    # Verify the file was transferred correctly
    ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "ls -la /tmp/nifi_certs/nifi${id}-keystore.p12 /tmp/nifi${id}-keystore.p12"
    
    # Create a proper PKCS12 truststore from the CA certificate
    echo "$(date '+%F %T') | ℹ️ Creating PKCS12 truststore from CA certificate..." | tee -a "$LOG_FILE"
    
    # Clean up any existing files
    rm -f /tmp/nifi-truststore.p12 /tmp/temp-truststore.jks /tmp/nifi-rootCA.der
    
    # Verify the CA certificate exists and is readable
    if [[ ! -f "$CERT_DIR/CA/nifi-rootCA.pem" ]]; then
        echo "$(date '+%F %T') | ❌ ERROR: CA certificate not found at $CERT_DIR/CA/nifi-rootCA.pem" | tee -a "$LOG_FILE"
        return 1
    fi
    
    # Display certificate info for debugging
    echo "$(date '+%F %T') | ℹ️ CA certificate details:" | tee -a "$LOG_FILE"
    openssl x509 -in "$CERT_DIR/CA/nifi-rootCA.pem" -text -noout | head -10 | tee -a "$LOG_FILE"
    
    # Create a DER format certificate for keytool import
    echo "$(date '+%F %T') | ℹ️ Converting PEM to DER format..." | tee -a "$LOG_FILE"
    openssl x509 -outform der -in "$CERT_DIR/CA/nifi-rootCA.pem" -out /tmp/nifi-rootCA.der || {
        echo "$(date '+%F %T') | ❌ ERROR: Failed to convert certificate to DER format" | tee -a "$LOG_FILE"
        return 1
    }
    
    # Create PKCS12 truststore directly (more reliable than JKS conversion)
    echo "$(date '+%F %T') | ℹ️ Creating PKCS12 truststore directly..." | tee -a "$LOG_FILE"
    # Use a more reliable approach with explicit parameters
    keytool -importcert -noprompt -alias "nifi-ca" \
        -file /tmp/nifi-rootCA.der \
        -keystore /tmp/nifi-truststore.p12 \
        -storetype PKCS12 \
        -storepass "$KEYSTORE_PASS" \
        -keypass "$KEYSTORE_PASS" \
        -v || {
        echo "$(date '+%F %T') | ❌ ERROR: Failed to create PKCS12 truststore" | tee -a "$LOG_FILE"
        return 1
    }
    
    # Set proper permissions on the truststore
    chmod 644 /tmp/nifi-truststore.p12
    
    # Verify the PKCS12 file with more detailed output
    echo "$(date '+%F %T') | ℹ️ Verifying PKCS12 truststore with detailed output..." | tee -a "$LOG_FILE"
    if ! keytool -list -v -keystore /tmp/nifi-truststore.p12 -storepass "$KEYSTORE_PASS" -storetype PKCS12 | tee -a "$LOG_FILE"; then
        echo "$(date '+%F %T') | ❌ ERROR: PKCS12 truststore verification failed" | tee -a "$LOG_FILE"
        return 1
    fi
    
    # Verify the PKCS12 file
    echo "$(date '+%F %T') | ℹ️ Verifying PKCS12 truststore..." | tee -a "$LOG_FILE"
    keytool -list -keystore /tmp/nifi-truststore.p12 -storepass "$KEYSTORE_PASS" -storetype PKCS12 || {
        echo "$(date '+%F %T') | ❌ ERROR: PKCS12 truststore verification failed" | tee -a "$LOG_FILE"
        return 1
    }
    
    # Copy the truststore to the remote node using the same reliable approach
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        "/tmp/nifi-truststore.p12" "$user@$ip:/tmp/nifi_certs/nifi-truststore.p12" || {
        echo "$(date '+%F %T') | ❌ ERROR: Failed to copy truststore file to remote node" | tee -a "$LOG_FILE"
        return 1
    }
    
    # Create a symlink to the expected location
    ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "ln -sf /tmp/nifi_certs/nifi-truststore.p12 /tmp/nifi-truststore.p12"
    
    # Verify the file was transferred correctly
    ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "ls -la /tmp/nifi_certs/nifi-truststore.p12 /tmp/nifi-truststore.p12"
    
    # Handle custom NAR files for remote nodes
    if [[ "$SKIP_CUSTOM_NARS" == "false" ]]; then
        echo "$(date '+%F %T') | ℹ️ Preparing custom NAR files for remote node..." | tee -a "$LOG_FILE"
        
        # Create a temporary directory to collect NAR files
        rm -rf /tmp/custom_nars
        mkdir -p /tmp/custom_nars
        
        # Copy specified NAR files to the temporary directory
        if [[ -n "$CUSTOM_NAR_FILES" ]]; then
            echo "$(date '+%F %T') | ℹ️ Processing specified NAR files for remote node: $CUSTOM_NAR_FILES" | tee -a "$LOG_FILE"
            IFS=',' read -ra NAR_FILES <<< "$CUSTOM_NAR_FILES"
            for nar_file in "${NAR_FILES[@]}"; do
                # Trim whitespace
                nar_file=$(echo "$nar_file" | xargs)
                
                # Check if the file exists
                if [[ -f "$nar_file" ]]; then
                    echo "$(date '+%F %T') | ✅ Copying NAR file to temp dir: $nar_file" | tee -a "$LOG_FILE"
                    cp "$nar_file" "/tmp/custom_nars/"
                elif [[ -f "$CUSTOM_NAR_DIR/$nar_file" ]]; then
                    echo "$(date '+%F %T') | ✅ Copying NAR file from custom directory to temp dir: $CUSTOM_NAR_DIR/$nar_file" | tee -a "$LOG_FILE"
                    cp "$CUSTOM_NAR_DIR/$nar_file" "/tmp/custom_nars/"
                else
                    echo "$(date '+%F %T') | ⚠️ NAR file not found for remote transfer: $nar_file" | tee -a "$LOG_FILE"
                fi
            done
        else
            # Copy all NAR files from the custom NAR directory
            echo "$(date '+%F %T') | ℹ️ Checking for NAR files in $CUSTOM_NAR_DIR for remote node" | tee -a "$LOG_FILE"
            if find "$CUSTOM_NAR_DIR" -name "*.nar" -type f | grep -q .; then
                echo "$(date '+%F %T') | ✅ Found NAR files in $CUSTOM_NAR_DIR for remote node" | tee -a "$LOG_FILE"
                # Initialize nar_file to avoid unbound variable error
                nar_file=""
                find "$CUSTOM_NAR_DIR" -name "*.nar" -type f -print | while read -r nar_file; do
                    echo "$(date '+%F %T') | ✅ Copying NAR file to temp dir: $nar_file" | tee -a "$LOG_FILE"
                    cp "$nar_file" "/tmp/custom_nars/"
                done
            else
                echo "$(date '+%F %T') | ℹ️ No NAR files found in $CUSTOM_NAR_DIR for remote node" | tee -a "$LOG_FILE"
                
                # For backward compatibility, check the old plugins directory
                if [[ -d "$PLUGINS_DIR" ]] && compgen -G "$PLUGINS_DIR/*.nar" > /dev/null; then
                    echo "$(date '+%F %T') | ℹ️ Found NAR files in legacy directory $PLUGINS_DIR for remote node" | tee -a "$LOG_FILE"
                    find "$PLUGINS_DIR" -maxdepth 1 -type f -name "*.nar" -exec cp {} "/tmp/custom_nars/" \;
                fi
            fi
        fi

        # Check if we have any NAR files to transfer
        if find "/tmp/custom_nars" -name "*.nar" -type f | grep -q .; then
            echo "$(date '+%F %T') | ℹ️ Transferring custom NAR files to remote node..." | tee -a "$LOG_FILE"
            
            # Create the directory on the remote node
            ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "mkdir -p /tmp/custom_nars"
            
            # Transfer the NAR files
            scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                /tmp/custom_nars/*.nar "$user@$ip:/tmp/custom_nars/" || {
                echo "$(date '+%F %T') | ⚠️ Failed to transfer NAR files to remote node" | tee -a "$LOG_FILE"
            }
            
            # Verify the transfer
            echo "$(date '+%F %T') | ℹ️ Verifying NAR files on remote node..." | tee -a "$LOG_FILE"
            ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "ls -la /tmp/custom_nars/"
        else
            echo "$(date '+%F %T') | ℹ️ No custom NAR files to transfer to remote node" | tee -a "$LOG_FILE"
        fi
    else
        echo "$(date '+%F %T') | ℹ️ Skipping custom NAR files for remote node as requested" | tee -a "$LOG_FILE"
    fi

    # Copy the setup script to the remote node
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        /tmp/nifi_setup_commands.sh "$user@$ip:/tmp/nifi_setup_commands.sh"
    
    # Make the script executable
    ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "chmod +x /tmp/nifi_setup_commands.sh"
    
    # Run the script with sudo in non-interactive mode
    echo "$(date '+%F %T') | ℹ️ Running setup script on remote node with sudo..." | tee -a "$LOG_FILE"
    
    # Create a more robust approach for sudo access
    # First, create a script that will run the setup commands with sudo
    ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "cat > /tmp/run_with_sudo.sh << 'EOF'
#!/bin/bash
# This script will run the setup commands with sudo, handling the password prompt if needed
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
chmod +x /tmp/nifi_setup_commands.sh

# Try non-interactive sudo first
if sudo -n true 2>/dev/null; then
    # User has passwordless sudo
    sudo /tmp/nifi_setup_commands.sh
else
    # Create a temporary sudoers file
    echo \"$user ALL=(ALL) NOPASSWD: /tmp/nifi_setup_commands.sh\" > /tmp/nifi_temp_sudo
    # Use sudo with password to install the temporary sudoers file
    echo \"Setting up temporary sudo access for the setup script...\"
    sudo cp /tmp/nifi_temp_sudo /etc/sudoers.d/nifi_temp_sudo
    sudo chmod 440 /etc/sudoers.d/nifi_temp_sudo
    
    # Now run the script with passwordless sudo
    sudo /tmp/nifi_setup_commands.sh
    
    # Clean up
    sudo rm -f /etc/sudoers.d/nifi_temp_sudo
fi
EOF
chmod +x /tmp/run_with_sudo.sh"

    # Execute the script with a terminal for password prompt if needed
    ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "bash /tmp/run_with_sudo.sh" || {
        echo "$(date '+%F %T') | ❌ Failed to execute setup script on remote node $ip" | tee -a "$LOG_FILE"
        return 1
    }
    
    # Clean up temporary sudo access
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "sudo rm -f /etc/sudoers.d/nifi_temp_sudo"
    
    echo "$(date '+%F %T') | ✅ Successfully executed setup script on remote node" | tee -a "$LOG_FILE"
    
    # Clean up temporary sudo access
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "sudo rm -f /etc/sudoers.d/nifi_temp_sudo"
    
    echo "$(date '+%F %T') | ✅ Successfully executed setup script on remote node" | tee -a "$LOG_FILE"
    
    # Verify the IP configuration on the remote node
    echo "$(date '+%F %T') | ℹ️ Verifying IP configuration on remote node..." | tee -a "$LOG_FILE"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "sudo grep -E 'nifi.web.https.host|nifi.cluster.node.address' $NIFI_DIR/conf/nifi.properties" | tee -a "$LOG_FILE"
    
    # Verify JAVA_HOME is set correctly on the remote node
    echo "$(date '+%F %T') | ℹ️ Verifying JAVA_HOME on remote node..." | tee -a "$LOG_FILE"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "echo 'JAVA_HOME on remote: '\$JAVA_HOME && sudo cat /etc/environment | grep JAVA_HOME"
    
    # Clean up
    rm -f /tmp/nifi_setup_commands.sh
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "rm -f /tmp/nifi_setup_commands.sh"
    
    echo "$(date '+%F %T') | ✅ Remote NiFi node $id setup completed on $ip" | tee -a "$LOG_FILE"
}

setup_local_node() {
    local id="$1"
    echo "$(date '+%F %T') | 🖥️ Setting up local NiFi node $id..." | tee -a "$LOG_FILE"
    
    # Initialize variables to avoid unbound variable errors
    JAR_COUNT=0

    # More robust directory existence check
    echo "$(date '+%F %T') | 🔍 Checking NiFi installation status..." | tee -a "$LOG_FILE"

    # First check if directory exists
    if [[ -d "$NIFI_DIR" ]]; then
        echo "$(date '+%F %T') | ℹ️ NiFi directory exists at $NIFI_DIR" | tee -a "$LOG_FILE"
        
        # Then check if it's a complete installation
        if [[ -f "$NIFI_DIR/bin/nifi.sh" ]]; then
            echo "$(date '+%F %T') | ✅ Found complete NiFi installation" | tee -a "$LOG_FILE"
            NIFI_VERSION=$(basename "$NIFI_DIR")
            # We'll set SKIP_EXTRACTION after cleanup
        else
            echo "$(date '+%F %T') | ⚠️ Found incomplete NiFi installation - will reinstall" | tee -a "$LOG_FILE"
            
            # Force a more thorough cleanup for incomplete installations
            echo "$(date '+%F %T') | 🧹 Performing thorough cleanup of incomplete installation..." | tee -a "$LOG_FILE"
            sudo find "$NIFI_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
            sudo find "$NIFI_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
            sudo rm -rf "$NIFI_DIR"
            
            # Verify directory was removed
            if [[ -d "$NIFI_DIR" ]]; then
                echo "$(date '+%F %T') | ⚠️ Warning: Could not completely remove $NIFI_DIR" | tee -a "$LOG_FILE"
                echo "$(date '+%F %T') | 🔍 Checking for remaining files..." | tee -a "$LOG_FILE"
                ls -la "$NIFI_DIR" | tee -a "$LOG_FILE"
                
                # Try more aggressive removal
                echo "$(date '+%F %T') | 🧹 Attempting more aggressive cleanup..." | tee -a "$LOG_FILE"
                sudo find "$NIFI_DIR" -type f -delete
                sudo find "$NIFI_DIR" -type d -empty -delete
                
                # If directory still exists, force removal with lsof check
                if [[ -d "$NIFI_DIR" ]]; then
                    echo "$(date '+%F %T') | 🔍 Checking for processes using the directory..." | tee -a "$LOG_FILE"
                    sudo lsof +D "$NIFI_DIR" 2>/dev/null || echo "$(date '+%F %T') | ℹ️ No processes found using the directory" | tee -a "$LOG_FILE"
                    
                    echo "$(date '+%F %T') | ⚠️ Warning: Directory still exists, will try to continue anyway" | tee -a "$LOG_FILE"
                fi
            fi
            
            SKIP_EXTRACTION=false
        fi
    else
        echo "$(date '+%F %T') | ℹ️ NiFi directory does not exist, will perform fresh installation" | tee -a "$LOG_FILE"
        
        # Debug: Check if NiFi tarball exists
        echo "$(date '+%F %T') | ℹ️ Checking NiFi tarball: $NIFI_TARBALL" | tee -a "$LOG_FILE"
        if [[ ! -f "$NIFI_TARBALL" ]]; then
            echo "$(date '+%F %T') | ❌ ERROR: NiFi tarball not found: $NIFI_TARBALL" | tee -a "$LOG_FILE"
            exit 1
        fi
        
        # Debug: Check tarball file type
        echo "$(date '+%F %T') | ℹ️ Verifying NiFi tarball file type..." | tee -a "$LOG_FILE"
        file "$NIFI_TARBALL" | tee -a "$LOG_FILE"
        
        SKIP_EXTRACTION=false
    fi

    # Determine which user/group to use (we'll create the service file later)
    SERVICE_USER="$NIFI_USER"
    SERVICE_GROUP="$NIFI_GROUP"
    
    if [[ "$RUN_AS_ROOT" == "true" ]]; then
        echo "$(date '+%F %T') | ⚠️ Warning: Running NiFi as root is not recommended for production environments" | tee -a "$LOG_FILE"
        SERVICE_USER="root"
        SERVICE_GROUP="root"
    fi

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

    # Check for processes using NiFi ports
    echo "$(date '+%F %T') | ℹ️ Checking for processes using NiFi ports..." | tee -a "$LOG_FILE"
    NIFI_PORTS=(8443 11443)
    for port in "${NIFI_PORTS[@]}"; do
        pid=$(sudo lsof -t -i:$port 2>/dev/null)
        if [[ -n "$pid" ]]; then
            echo "$(date '+%F %T') | ⚠️ Found process using port $port: PID $pid" | tee -a "$LOG_FILE"
            echo "$(date '+%F %T') | ℹ️ Process details:" | tee -a "$LOG_FILE"
            sudo ps -f -p $pid | tee -a "$LOG_FILE"
            
            # Kill the process regardless of SKIP_KILL setting
            echo "$(date '+%F %T') | ℹ️ Killing process using port $port..." | tee -a "$LOG_FILE"
            sudo kill -15 $pid 2>/dev/null || true
            sleep 2
            
            # Force kill if still running
            if sudo lsof -t -i:$port 2>/dev/null; then
                echo "$(date '+%F %T') | ⚠️ Process still using port $port, force killing..." | tee -a "$LOG_FILE"
                sudo kill -9 $pid 2>/dev/null || true
            fi
        else
            echo "$(date '+%F %T') | ✅ Port $port is available" | tee -a "$LOG_FILE"
        fi
    done
    
    # Skip additional kill operation if SKIP_KILL is true
    if [[ "$SKIP_KILL" == "true" ]]; then
        echo "$(date '+%F %T') | ℹ️ Skipping additional process kill operation as SKIP_KILL is set to true" | tee -a "$LOG_FILE"
    else
        # Use the external kill script if available
        if [[ -f "./kill_nifi_processes.sh" ]]; then
            echo "$(date '+%F %T') | ℹ️ Using external kill script..." | tee -a "$LOG_FILE"
            chmod +x ./kill_nifi_processes.sh
            ./kill_nifi_processes.sh
        else
            echo "$(date '+%F %T') | ℹ️ External kill script not found, using built-in process termination..." | tee -a "$LOG_FILE"
            
            # Find and kill all NiFi processes
            echo "$(date '+%F %T') | ℹ️ Finding all NiFi processes..." | tee -a "$LOG_FILE"
            
            # Find Java processes related to NiFi
            nifi_pids=$(sudo pgrep -f "java.*nifi" || echo "")
            if [[ -n "$nifi_pids" ]]; then
                echo "$(date '+%F %T') | ℹ️ Found NiFi Java processes: $nifi_pids" | tee -a "$LOG_FILE"
                for pid in $nifi_pids; do
                    echo "$(date '+%F %T') | ℹ️ Killing NiFi Java process $pid..." | tee -a "$LOG_FILE"
                    sudo kill -15 $pid 2>/dev/null || true
                done
                sleep 3
                
                # Check if processes are still running and force kill if necessary
                still_running=$(sudo pgrep -f "java.*nifi" || echo "")
                if [[ -n "$still_running" ]]; then
                    echo "$(date '+%F %T') | ⚠️ Some NiFi processes still running, force killing: $still_running" | tee -a "$LOG_FILE"
                    for pid in $still_running; do
                        sudo kill -9 $pid 2>/dev/null || true
                    done
                fi
            fi
            
            # Find any nifi.sh processes
            nifi_sh_pids=$(sudo pgrep -f "nifi.sh" || echo "")
            if [[ -n "$nifi_sh_pids" ]]; then
                echo "$(date '+%F %T') | ℹ️ Found nifi.sh processes: $nifi_sh_pids" | tee -a "$LOG_FILE"
                for pid in $nifi_sh_pids; do
                    echo "$(date '+%F %T') | ℹ️ Killing nifi.sh process $pid..." | tee -a "$LOG_FILE"
                    sudo kill -15 $pid 2>/dev/null || true
                done
                sleep 2
                
                # Force kill if necessary
                still_running=$(sudo pgrep -f "nifi.sh" || echo "")
                if [[ -n "$still_running" ]]; then
                    echo "$(date '+%F %T') | ⚠️ Some nifi.sh processes still running, force killing: $still_running" | tee -a "$LOG_FILE"
                    for pid in $still_running; do
                        sudo kill -9 $pid 2>/dev/null || true
                    done
                fi
            fi
            
            # Verify no NiFi processes are running
            if [[ -z "$(sudo pgrep -f 'java.*nifi\|nifi.sh' || echo '')" ]]; then
                echo "$(date '+%F %T') | ✅ All NiFi processes successfully terminated" | tee -a "$LOG_FILE"
            else
                echo "$(date '+%F %T') | ⚠️ Warning: Some NiFi processes could not be terminated. Continuing anyway." | tee -a "$LOG_FILE"
                echo "$(date '+%F %T') | ℹ️ Running NiFi processes: $(sudo pgrep -f 'java.*nifi\|nifi.sh' || echo 'none')" | tee -a "$LOG_FILE"
            fi
        fi
    fi

    echo "$(date '+%F %T') | ℹ️ Proceeding with file cleanup..." | tee -a "$LOG_FILE"

    # Remove NiFi installation directory
    echo "$(date '+%F %T') | ℹ️ Removing NiFi installation directory..." | tee -a "$LOG_FILE"
    sudo rm -rf "$NIFI_DIR" || echo "$(date '+%F %T') | ℹ️ No NiFi directory to remove or permission issue" | tee -a "$LOG_FILE"
    
    # Special check for the case where only logs directory remains
    if [[ -d "$NIFI_DIR" && "$(ls -A "$NIFI_DIR" 2>/dev/null | grep -v "logs")" == "" ]]; then
        echo "$(date '+%F %T') | ⚠️ Found NiFi directory with only logs subdirectory - this is the issue we're fixing" | tee -a "$LOG_FILE"
        echo "$(date '+%F %T') | ℹ️ Preserving logs directory and removing parent directory..." | tee -a "$LOG_FILE"
        
        # Temporarily move logs directory if it exists
        if [[ -d "$NIFI_DIR/logs" ]]; then
            sudo mv "$NIFI_DIR/logs" "/tmp/nifi-logs-backup"
        fi
        
        # Remove the parent directory
        sudo rm -rf "$NIFI_DIR"
        
        # Recreate the parent directory
        sudo mkdir -p "$NIFI_DIR"
        
        # Restore logs directory if it was backed up
        if [[ -d "/tmp/nifi-logs-backup" ]]; then
            sudo mv "/tmp/nifi-logs-backup" "$NIFI_DIR/logs"
        fi
        
        # Force extraction since we know the directory is incomplete
        SKIP_EXTRACTION=false
        echo "$(date '+%F %T') | ✅ Handled the 'logs-only' directory case, will force extraction" | tee -a "$LOG_FILE"
    fi
    
    # Check if directory was actually removed
    if [[ ! -d "$NIFI_DIR" ]]; then
        echo "$(date '+%F %T') | ✅ NiFi directory successfully removed" | tee -a "$LOG_FILE"
        # Force extraction since directory is gone
        SKIP_EXTRACTION=false
    else
        echo "$(date '+%F %T') | ⚠️ Warning: NiFi directory still exists after removal attempt" | tee -a "$LOG_FILE"
        # Check if it's a complete installation after removal attempt
        if [[ -f "$NIFI_DIR/bin/nifi.sh" && -d "$NIFI_DIR/lib" && -d "$NIFI_DIR/conf" ]]; then
            echo "$(date '+%F %T') | ℹ️ Directory still contains a complete installation" | tee -a "$LOG_FILE"
            
            # Verify critical files exist
            if [[ -f "$NIFI_DIR/conf/nifi.properties" && -f "$NIFI_DIR/conf/bootstrap.conf" ]]; then
                echo "$(date '+%F %T') | ✅ All critical NiFi files verified, can use existing installation" | tee -a "$LOG_FILE"
                SKIP_EXTRACTION=true
            else
                echo "$(date '+%F %T') | ⚠️ Missing critical configuration files, will force extraction" | tee -a "$LOG_FILE"
                SKIP_EXTRACTION=false
            fi
        else
            echo "$(date '+%F %T') | ℹ️ Directory exists but installation is incomplete, will extract" | tee -a "$LOG_FILE"
            SKIP_EXTRACTION=false
        fi
    fi

    # Remove NiFi data directories
    echo "$(date '+%F %T') | ℹ️ Removing NiFi data directories..." | tee -a "$LOG_FILE"
    sudo rm -rf /var/lib/nifi
    sudo rm -rf /var/log/nifi
    sudo rm -rf /var/run/nifi
    sudo rm -rf /etc/nifi

    # Remove NiFi user and group if they exist
    if id "$NIFI_USER" &>/dev/null; then
        echo "$(date '+%F %T') | ℹ️ Removing NiFi user ($NIFI_USER)..." | tee -a "$LOG_FILE"
        sudo userdel -r "$NIFI_USER" 2>/dev/null || true
    fi
    if getent group "$NIFI_GROUP" &>/dev/null; then
        echo "$(date '+%F %T') | ℹ️ Removing NiFi group ($NIFI_GROUP)..." | tee -a "$LOG_FILE"
        sudo groupdel "$NIFI_GROUP" 2>/dev/null || true
    fi

    # Remove NiFi environment files
    echo "$(date '+%F %T') | ℹ️ Removing NiFi environment files..." | tee -a "$LOG_FILE"
    sudo rm -f /etc/profile.d/nifi.sh
    sudo rm -f /etc/environment.d/nifi.conf

    # Clean up temporary files but preserve the tarball
    echo "$(date '+%F %T') | ℹ️ Cleaning up temporary NiFi files..." | tee -a "$LOG_FILE"
    # Save the tarball to a safe location if it exists (always preserve it)
    if [[ -f "$NIFI_TARBALL" ]]; then
        echo "$(date '+%F %T') | ℹ️ Preserving NiFi tarball during cleanup..." | tee -a "$LOG_FILE"
        sudo cp "$NIFI_TARBALL" "/tmp/nifi-tarball-backup.zip"
    fi
    
    # Remove temporary files except the backup tarball
    sudo find /tmp -name "nifi*" -not -name "nifi-tarball-backup.zip" -exec rm -rf {} \; 2>/dev/null || true
    sudo rm -f /tmp/nifi-*.log
    sudo rm -f /tmp/nifi_*.pid

    echo "$(date '+%F %T') | ✅ NiFi cleanup completed" | tee -a "$LOG_FILE"
    
    # Restore the tarball if we backed it up (always restore it)
    if [[ -f "/tmp/nifi-tarball-backup.zip" ]]; then
        echo "$(date '+%F %T') | ℹ️ Restoring NiFi tarball from backup..." | tee -a "$LOG_FILE"
        sudo cp "/tmp/nifi-tarball-backup.zip" "$NIFI_TARBALL"
        sudo rm -f "/tmp/nifi-tarball-backup.zip"
    fi
    
    # Check if extraction directory already exists and remove it
    if [[ -d "/tmp/$NIFI_VERSION" && "$SKIP_EXTRACTION" == "false" ]]; then
        echo "$(date '+%F %T') | ℹ️ Removing existing extraction directory: /tmp/$NIFI_VERSION" | tee -a "$LOG_FILE"
        sudo rm -rf "/tmp/$NIFI_VERSION"
    fi
    
    # Check if NiFi directory exists after cleanup
    if [[ ! -d "$NIFI_DIR" || "$SKIP_EXTRACTION" == "false" ]]; then
        echo "$(date '+%F %T') | ℹ️ Need to extract NiFi (directory doesn't exist or is incomplete)" | tee -a "$LOG_FILE"
        # Extract NiFi tarball with more verbose output
        echo "$(date '+%F %T') | ℹ️ Extracting NiFi tarball..." | tee -a "$LOG_FILE"
        if ! sudo unzip -o "$NIFI_TARBALL" -d /tmp/ 2>&1 | tee -a "$LOG_FILE"; then
            echo "$(date '+%F %T') | ❌ ERROR: Failed to extract NiFi tarball" | tee -a "$LOG_FILE"
            echo "$(date '+%F %T') | ℹ️ Trying alternative extraction method..." | tee -a "$LOG_FILE"

            # Try alternative extraction method
            sudo mkdir -p "/tmp/$NIFI_VERSION"
            if ! sudo unzip -o "$NIFI_TARBALL" -d "/tmp/$NIFI_VERSION" 2>&1 | tee -a "$LOG_FILE"; then
                echo "$(date '+%F %T') | ❌ ERROR: All extraction methods failed" | tee -a "$LOG_FILE"
                exit 1
            fi
        fi
    
        # Check if extraction was successful and find the actual directory
        echo "$(date '+%F %T') | ℹ️ Checking extracted NiFi directory..." | tee -a "$LOG_FILE"
        ls -la /tmp/ | grep nifi | tee -a "$LOG_FILE"
        # Try to find the NiFi directory
        EXTRACTED_DIR=$(find /tmp -maxdepth 1 -type d -name "nifi*" | grep -v "nifi-certs" | head -n 1)
        
        if [[ -z "$EXTRACTED_DIR" ]]; then
            echo "$(date '+%F %T') | ⚠️ Warning: Could not find extracted NiFi directory in /tmp" | tee -a "$LOG_FILE"
            
            # Check if tarball still exists
            if [[ ! -f "$NIFI_TARBALL" ]]; then
                echo "$(date '+%F %T') | ❌ ERROR: NiFi tarball is missing: $NIFI_TARBALL" | tee -a "$LOG_FILE"
                exit 1
            fi
            
            # Try extraction again with more verbose output
            echo "$(date '+%F %T') | ℹ️ Attempting extraction again..." | tee -a "$LOG_FILE"
            sudo unzip -o "$NIFI_TARBALL" -d /tmp/ 2>&1 | tee -a "$LOG_FILE"
            
            # Check again for the extracted directory
            EXTRACTED_DIR=$(find /tmp -maxdepth 1 -type d -name "nifi*" | grep -v "nifi-certs" | head -n 1)
            
            if [[ -z "$EXTRACTED_DIR" ]]; then
                echo "$(date '+%F %T') | ❌ ERROR: Still could not find extracted NiFi directory" | tee -a "$LOG_FILE"
                exit 1
            fi
        fi
        
        echo "$(date '+%F %T') | ✅ Found extracted NiFi directory: $EXTRACTED_DIR" | tee -a "$LOG_FILE"
        NIFI_VERSION=$(basename "$EXTRACTED_DIR")
        SKIP_EXTRACTION=false
    fi
    
    # Move NiFi to installation directory if we didn't skip extraction
    if [[ "$SKIP_EXTRACTION" != "true" ]]; then
        echo "$(date '+%F %T') | ℹ️ Moving NiFi to installation directory..." | tee -a "$LOG_FILE"
        
        # Remove existing directory if it exists
        if [[ -d "$NIFI_DIR" ]]; then
            echo "$(date '+%F %T') | ℹ️ Removing existing NiFi directory: $NIFI_DIR" | tee -a "$LOG_FILE"
            sudo rm -rf "$NIFI_DIR"
        fi
        
        sudo mv "$EXTRACTED_DIR" "$NIFI_DIR" || {
            echo "$(date '+%F %T') | ⚠️ Warning: Failed to move NiFi to installation directory" | tee -a "$LOG_FILE"
            echo "$(date '+%F %T') | ℹ️ Trying alternative move method..." | tee -a "$LOG_FILE"
            
            # Try alternative move method
            sudo mkdir -p "$NIFI_DIR"
            sudo cp -r "$EXTRACTED_DIR"/* "$NIFI_DIR/" || {
                echo "$(date '+%F %T') | ❌ ERROR: All move methods failed" | tee -a "$LOG_FILE"
                exit 1
            }
            echo "$(date '+%F %T') | ✅ Copied NiFi files to installation directory" | tee -a "$LOG_FILE"
        }
    else
        # Check if the directory is a complete installation before skipping
        if [[ -f "$NIFI_DIR/bin/nifi.sh" ]]; then
            echo "$(date '+%F %T') | ℹ️ Skipping NiFi extraction and move as complete installation already exists" | tee -a "$LOG_FILE"
        else
            echo "$(date '+%F %T') | ⚠️ NiFi directory exists but appears incomplete, forcing extraction..." | tee -a "$LOG_FILE"
            # Force extraction by setting SKIP_EXTRACTION to false
            SKIP_EXTRACTION=false
            
            # Extract NiFi tarball
            echo "$(date '+%F %T') | ℹ️ Extracting NiFi tarball for incomplete installation..." | tee -a "$LOG_FILE"
            if ! sudo unzip -o "$NIFI_TARBALL" -d /tmp/ 2>&1 | tee -a "$LOG_FILE"; then
                echo "$(date '+%F %T') | ❌ ERROR: Failed to extract NiFi tarball" | tee -a "$LOG_FILE"
                exit 1
            fi
            
            # Find the extracted directory
            EXTRACTED_DIR=$(find /tmp -maxdepth 1 -type d -name "nifi*" | grep -v "nifi-certs" | head -n 1)
            
            if [[ -z "$EXTRACTED_DIR" ]]; then
                echo "$(date '+%F %T') | ❌ ERROR: Could not find extracted NiFi directory" | tee -a "$LOG_FILE"
                exit 1
            fi
            
            echo "$(date '+%F %T') | ✅ Found extracted NiFi directory: $EXTRACTED_DIR" | tee -a "$LOG_FILE"
            NIFI_VERSION=$(basename "$EXTRACTED_DIR")
            
            # Remove existing directory
            echo "$(date '+%F %T') | ℹ️ Removing incomplete NiFi directory: $NIFI_DIR" | tee -a "$LOG_FILE"
            sudo rm -rf "$NIFI_DIR"
            
            # Move extracted directory to installation location
            echo "$(date '+%F %T') | ℹ️ Moving NiFi to installation directory..." | tee -a "$LOG_FILE"
            sudo mv "$EXTRACTED_DIR" "$NIFI_DIR" || {
                echo "$(date '+%F %T') | ⚠️ Warning: Failed to move NiFi to installation directory" | tee -a "$LOG_FILE"
                echo "$(date '+%F %T') | ℹ️ Trying alternative move method..." | tee -a "$LOG_FILE"
                
                # Try alternative move method
                sudo mkdir -p "$NIFI_DIR"
                sudo cp -r "$EXTRACTED_DIR"/* "$NIFI_DIR/" || {
                    echo "$(date '+%F %T') | ❌ ERROR: All move methods failed" | tee -a "$LOG_FILE"
                    exit 1
                }
                echo "$(date '+%F %T') | ✅ Copied NiFi files to installation directory" | tee -a "$LOG_FILE"
            }
        fi
    fi
    
    # Verify NiFi installation
    echo "$(date '+%F %T') | 🔍 Verifying NiFi installation..." | tee -a "$LOG_FILE"
    ls -la "$NIFI_DIR" | tee -a "$LOG_FILE"
    
    # Check critical directories and files
    for dir in "bin" "conf" "lib"; do
        if [[ ! -d "$NIFI_DIR/$dir" ]]; then
            echo "$(date '+%F %T') | ❌ ERROR: Missing critical directory: $NIFI_DIR/$dir" | tee -a "$LOG_FILE"
            exit 1
        fi
    done

    for file in "bin/nifi.sh" "conf/nifi.properties" "conf/bootstrap.conf"; do
        if [[ ! -f "$NIFI_DIR/$file" ]]; then
            echo "$(date '+%F %T') | ❌ ERROR: Missing critical file: $NIFI_DIR/$file" | tee -a "$LOG_FILE"
            exit 1
        fi
    done

    echo "$(date '+%F %T') | ✅ NiFi installation verified successfully" | tee -a "$LOG_FILE"
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
    echo "$(date '+%F %T') | ℹ️ Expected keystore path: $CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | ℹ️ Truststore path: $CERT_DIR/CA/nifi-rootCA.pem" | tee -a "$LOG_FILE"
    
    # More flexible keystore path finding
    KEYSTORE_PATH=""
    
    # Try exact match first
    if [[ -f "$CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12" ]]; then
        echo "$(date '+%F %T') | ✅ Found keystore at expected path: $CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12" | tee -a "$LOG_FILE"
        KEYSTORE_PATH="$CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12"
    else
        # Try current hostname
        if [[ -f "$CERT_DIR/$(hostname)/keystore.p12" ]]; then
            echo "$(date '+%F %T') | ✅ Found keystore using current hostname: $CERT_DIR/$(hostname)/keystore.p12" | tee -a "$LOG_FILE"
            KEYSTORE_PATH="$CERT_DIR/$(hostname)/keystore.p12"
        else
            # Try case-insensitive or partial match
            local host_pattern="${SERVER_HOSTS[id-1]}"
            local found_dir=$(find "$CERT_DIR" -maxdepth 1 -type d -name "*${host_pattern}*" | head -n 1)
            
            if [[ -n "$found_dir" && -f "$found_dir/keystore.p12" ]]; then
                echo "$(date '+%F %T') | ✅ Found keystore using pattern match: $found_dir/keystore.p12" | tee -a "$LOG_FILE"
                KEYSTORE_PATH="$found_dir/keystore.p12"
            else
                # Try any keystore.p12 file in any subdirectory
                local any_keystore=$(find "$CERT_DIR" -name "keystore.p12" | head -n 1)
                
                if [[ -n "$any_keystore" ]]; then
                    echo "$(date '+%F %T') | ✅ Found keystore using general search: $any_keystore" | tee -a "$LOG_FILE"
                    KEYSTORE_PATH="$any_keystore"
                else
                    # If all else fails, show detailed error information
                    echo "$(date '+%F %T') | ❌ ERROR: Keystore file not found: $CERT_DIR/${SERVER_HOSTS[id-1]}/keystore.p12" | tee -a "$LOG_FILE"
                    
                    # List all subdirectories and files for debugging
                    echo "$(date '+%F %T') | ℹ️ Listing all subdirectories in $CERT_DIR:" | tee -a "$LOG_FILE"
                    find "$CERT_DIR" -maxdepth 3 -type d | tee -a "$LOG_FILE"
                    
                    echo "$(date '+%F %T') | ℹ️ Searching for any keystore files:" | tee -a "$LOG_FILE"
                    find "$CERT_DIR" -type f \( -name "*.p12" -o -name "*.jks" \) | tee -a "$LOG_FILE"
                    
                    echo "$(date '+%F %T') | ❌ ERROR: Could not find any usable keystore file" | tee -a "$LOG_FILE"
                    exit 1
                fi
            fi
        fi
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
    
    # Clean up any existing files
    sudo rm -f /tmp/nifi-truststore.p12 /tmp/temp-truststore.jks /tmp/nifi-rootCA.der
    
    # Verify the CA certificate exists and is readable
    if [[ ! -f "$CERT_DIR/CA/nifi-rootCA.pem" ]]; then
        echo "$(date '+%F %T') | ❌ ERROR: CA certificate not found at $CERT_DIR/CA/nifi-rootCA.pem" | tee -a "$LOG_FILE"
        exit 1
    fi
    
    # Display certificate info for debugging
    echo "$(date '+%F %T') | ℹ️ CA certificate details:" | tee -a "$LOG_FILE"
    sudo openssl x509 -in "$CERT_DIR/CA/nifi-rootCA.pem" -text -noout | head -10 | tee -a "$LOG_FILE"
    
    # Create a DER format certificate for keytool import
    echo "$(date '+%F %T') | ℹ️ Converting PEM to DER format..." | tee -a "$LOG_FILE"
    sudo openssl x509 -outform der -in "$CERT_DIR/CA/nifi-rootCA.pem" -out /tmp/nifi-rootCA.der || {
        echo "$(date '+%F %T') | ❌ ERROR: Failed to convert certificate to DER format" | tee -a "$LOG_FILE"
        exit 1
    }
    
    # Create PKCS12 truststore directly (more reliable than JKS conversion)
    echo "$(date '+%F %T') | ℹ️ Creating PKCS12 truststore directly..." | tee -a "$LOG_FILE"
    # Use a more reliable approach with explicit parameters
    sudo keytool -importcert -noprompt -alias "nifi-ca" \
        -file /tmp/nifi-rootCA.der \
        -keystore /tmp/nifi-truststore.p12 \
        -storetype PKCS12 \
        -storepass "$KEYSTORE_PASS" \
        -keypass "$KEYSTORE_PASS" \
        -v || {
        echo "$(date '+%F %T') | ❌ ERROR: Failed to create PKCS12 truststore" | tee -a "$LOG_FILE"
        exit 1
    }
    
    # Set proper permissions on the truststore
    sudo chmod 644 /tmp/nifi-truststore.p12
    
    # Verify the PKCS12 file with more detailed output
    echo "$(date '+%F %T') | ℹ️ Verifying PKCS12 truststore with detailed output..." | tee -a "$LOG_FILE"
    if ! sudo keytool -list -v -keystore /tmp/nifi-truststore.p12 -storepass "$KEYSTORE_PASS" -storetype PKCS12 | tee -a "$LOG_FILE"; then
        echo "$(date '+%F %T') | ❌ ERROR: PKCS12 truststore verification failed" | tee -a "$LOG_FILE"
        exit 1
    fi
    
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
    
    # Set proper permissions on certificate files
    echo "$(date '+%F %T') | ℹ️ Setting proper permissions on certificate files..." | tee -a "$LOG_FILE"
    sudo chmod 644 "$NIFI_DIR/certs/nifi${id}-keystore.p12"
    sudo chmod 644 "$NIFI_DIR/certs/nifi-truststore.p12"
    
    # Verify certificate files were copied
    echo "$(date '+%F %T') | ℹ️ Verifying certificate files were copied..." | tee -a "$LOG_FILE"
    ls -la "$NIFI_DIR/certs/" | tee -a "$LOG_FILE"
    
    # Verify the truststore is valid
    echo "$(date '+%F %T') | ℹ️ Verifying truststore validity in final location..." | tee -a "$LOG_FILE"
    if ! sudo keytool -list -keystore "$NIFI_DIR/certs/nifi-truststore.p12" -storepass "$KEYSTORE_PASS" -storetype PKCS12 | tee -a "$LOG_FILE"; then
        echo "$(date '+%F %T') | ❌ ERROR: Truststore verification failed in final location" | tee -a "$LOG_FILE"
        exit 1
    fi
    
    # Create NiFi service file
    echo "$(date '+%F %T') | ℹ️ Creating NiFi service file..." | tee -a "$LOG_FILE"
    # Create service file without LSB headers
    # Create service file with proper variable expansion
    cat > /tmp/nifi.service <<EOF
    
    [Unit]
    Description=Apache NiFi
    After=network.target
    
    [Service]
    User=${SERVICE_USER}
    Group=${SERVICE_GROUP}
    ExecStart=/bin/bash -c 'export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 && ${NIFI_DIR}/bin/nifi.sh start'
    ExecStop=/bin/bash -c 'export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 && ${NIFI_DIR}/bin/nifi.sh stop'
    Restart=on-failure
    RestartSec=10
    TimeoutSec=300
    PIDFile=${NIFI_DIR}/run/nifi.pid
    LimitNOFILE=50000
    
    [Install]
    WantedBy=multi-user.target
EOF

    sudo cp /tmp/nifi.service /etc/systemd/system/nifi.service
    rm -f /tmp/nifi.service
    
    # Verify certificate settings in nifi.properties
    echo "$(date '+%F %T') | ℹ️ Verifying certificate settings in nifi.properties..." | tee -a "$LOG_FILE"
    sudo grep -E "nifi.security.(keystore|truststore)" "$NIFI_DIR/conf/nifi.properties" | tee -a "$LOG_FILE"

    # Remove any leading slash from the IP address
    CURRENT_IP=${CURRENT_IP#/}
    echo "$(date '+%F %T') | ℹ️ Using cleaned IP address for local node: $CURRENT_IP" | tee -a "$LOG_FILE"
    
    configure_nifi_properties "$id" "$CURRENT_IP" "nifi${id}-keystore.p12" "nifi-truststore.p12"

    # Check if Java is installed and set JAVA_HOME
    echo "$(date '+%F %T') | ℹ️ Checking Java installation..." | tee -a "$LOG_FILE"
    java -version || {
        echo "$(date '+%F %T') | ℹ️ Installing Java..." | tee -a "$LOG_FILE"
        sudo apt-get update
        sudo apt-get install -y default-jre default-jdk
    }
    
    # Find and set JAVA_HOME
    echo "$(date '+%F %T') | ℹ️ Setting JAVA_HOME..." | tee -a "$LOG_FILE"
    # Initialize JAVA_HOME to avoid unbound variable error
    JAVA_HOME=${JAVA_HOME:-""}
    if [ -z "$JAVA_HOME" ]; then
        # Try to find Java home directory
        if [ -d "/usr/lib/jvm/default-java" ]; then
            JAVA_HOME="/usr/lib/jvm/default-java"
        elif [ -d "/usr/lib/jvm/java-11-openjdk-amd64" ]; then
            JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64"
        elif [ -d "/usr/lib/jvm/java-8-openjdk-amd64" ]; then
            JAVA_HOME="/usr/lib/jvm/java-8-openjdk-amd64"
        else
            # Find any JVM directory
            JAVA_HOME=$(find /usr/lib/jvm -maxdepth 1 -type d -name "java*" | head -n 1)
        fi
        
        echo "$(date '+%F %T') | ✅ Found JAVA_HOME: $JAVA_HOME" | tee -a "$LOG_FILE"

        # Add JAVA_HOME to system-wide environment
        echo "JAVA_HOME=$JAVA_HOME" | sudo tee -a /etc/environment

        # Add JAVA_HOME to nifi.service with hardcoded path
        sudo sed -i "/\\[Service\\]/a Environment=JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64" /etc/systemd/system/nifi.service

        # Add JAVA_HOME to bootstrap.conf
        if ! sudo grep -q "^java.home=" "$NIFI_DIR/conf/bootstrap.conf"; then
            echo "$(date '+%F %T') | ℹ️ Adding JAVA_HOME to bootstrap.conf..." | tee -a "$LOG_FILE"
            echo "java.home=$JAVA_HOME" | sudo tee -a "$NIFI_DIR/conf/bootstrap.conf" > /dev/null
        fi

        # Create a wrapper script for nifi.sh
        echo "$(date '+%F %T') | ℹ️ Creating wrapper script for nifi.sh..." | tee -a "$LOG_FILE"
        cat > /tmp/nifi-wrapper.sh <<EOF
#!/bin/bash
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
if [ ! -d "\$JAVA_HOME" ]; then
  export JAVA_HOME=/usr/lib/jvm/default-java
fi
if [ ! -d "\$JAVA_HOME" ]; then
  export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
fi
if [ ! -d "\$JAVA_HOME" ]; then
  export JAVA_HOME=\$(find /usr/lib/jvm -maxdepth 1 -type d -name "java*" | head -n 1)
fi
echo "Using JAVA_HOME=\$JAVA_HOME"
$NIFI_DIR/bin/nifi.sh "\$@"
EOF
        if [ -n "$JAVA_HOME" ]; then
          sudo chmod +x /tmp/nifi-wrapper.sh
          sudo mv /tmp/nifi-wrapper.sh "$NIFI_DIR/bin/nifi-wrapper.sh"

          echo "$(date '+%F %T') | ℹ️ Updating service file to use wrapper script..." | tee -a "$LOG_FILE"
          sudo sed -i "s|ExecStart=.*nifi.sh start|ExecStart=$NIFI_DIR/bin/nifi-wrapper.sh start|" /etc/systemd/system/nifi.service
          sudo sed -i "s|ExecStop=.*nifi.sh stop|ExecStop=$NIFI_DIR/bin/nifi-wrapper.sh stop|" /etc/systemd/system/nifi.service

          export JAVA_HOME="$JAVA_HOME"
      else
          echo "$(date '+%F %T') | ❌ ERROR: Could not find JAVA_HOME directory" | tee -a "$LOG_FILE"
          exit 1
      fi
  fi

      # Create NiFi user and group if requested
    if [[ "$CREATE_USER" == "true" && "$RUN_AS_ROOT" != "true" ]]; then
        echo "$(date '+%F %T') | ℹ️ Creating NiFi user and group..." | tee -a "$LOG_FILE"
        
        # Create group if it doesn't exist
        if ! getent group "$NIFI_GROUP" &>/dev/null; then
            sudo groupadd "$NIFI_GROUP"
            echo "$(date '+%F %T') | ✅ Created group: $NIFI_GROUP" | tee -a "$LOG_FILE"
        else
            echo "$(date '+%F %T') | ℹ️ Group already exists: $NIFI_GROUP" | tee -a "$LOG_FILE"
        fi
        
        # Create user if it doesn't exist
        if ! id "$NIFI_USER" &>/dev/null; then
            sudo useradd -r -g "$NIFI_GROUP" -d "$NIFI_DIR" -s /bin/bash "$NIFI_USER"
            echo "$(date '+%F %T') | ✅ Created user: $NIFI_USER" | tee -a "$LOG_FILE"
        else
            echo "$(date '+%F %T') | ℹ️ User already exists: $NIFI_USER" | tee -a "$LOG_FILE"
        fi
        
        # Set proper permissions on NiFi directories
        echo "$(date '+%F %T') | ℹ️ Setting proper permissions on NiFi directories..." | tee -a "$LOG_FILE"
        sudo chown -R "$NIFI_USER:$NIFI_GROUP" "$NIFI_DIR"
        sudo chmod -R 750 "$NIFI_DIR"
        
        # Ensure sensitive directories have proper permissions
        sudo chmod 700 "$NIFI_DIR/conf"
        sudo chmod 700 "$NIFI_DIR/certs"
        
        # Create data directories with proper permissions
        echo "$(date '+%F %T') | ℹ️ Creating NiFi data directories with proper permissions..." | tee -a "$LOG_FILE"
        sudo mkdir -p /var/lib/nifi /var/log/nifi /var/run/nifi
        sudo chown -R "$NIFI_USER:$NIFI_GROUP" /var/lib/nifi /var/log/nifi /var/run/nifi
        sudo chmod 750 /var/lib/nifi /var/log/nifi /var/run/nifi
        
        # Create repository directories with proper permissions
        echo "$(date '+%F %T') | ℹ️ Creating NiFi repository directories with proper permissions..." | tee -a "$LOG_FILE"
        sudo mkdir -p "$NIFI_DIR/flowfile_repository" \
                     "$NIFI_DIR/content_repository" \
                     "$NIFI_DIR/provenance_repository" \
                     "$NIFI_DIR/state/local" \
                     "$NIFI_DIR/database_repository"
        sudo chown -R "$NIFI_USER:$NIFI_GROUP" "$NIFI_DIR/flowfile_repository" \
                                              "$NIFI_DIR/content_repository" \
                                              "$NIFI_DIR/provenance_repository" \
                                              "$NIFI_DIR/state/local" \
                                              "$NIFI_DIR/database_repository"
        sudo chmod -R 750 "$NIFI_DIR/flowfile_repository" \
                         "$NIFI_DIR/content_repository" \
                         "$NIFI_DIR/provenance_repository" \
                         "$NIFI_DIR/state/local" \
                         "$NIFI_DIR/database_repository"
        
        # Update bootstrap.conf to use the correct user
        echo "$(date '+%F %T') | ℹ️ Updating bootstrap.conf to use the correct user..." | tee -a "$LOG_FILE"
        if ! sudo grep -q "^run.as=" "$NIFI_DIR/conf/bootstrap.conf"; then
            echo "run.as=$NIFI_USER" | sudo tee -a "$NIFI_DIR/conf/bootstrap.conf" > /dev/null
        else
            sudo sed -i "s|^run.as=.*|run.as=$NIFI_USER|" "$NIFI_DIR/conf/bootstrap.conf"
        fi
        
        # Verify the user exists in /etc/passwd
        if ! getent passwd "$NIFI_USER" > /dev/null; then
            echo "$(date '+%F %T') | ⚠️ Warning: User $NIFI_USER does not exist in /etc/passwd" | tee -a "$LOG_FILE"
            echo "$(date '+%F %T') | ℹ️ Creating user $NIFI_USER again to ensure it exists..." | tee -a "$LOG_FILE"
            sudo useradd -r -g "$NIFI_GROUP" -d "$NIFI_DIR" -s /bin/bash "$NIFI_USER" || true
        fi
    else
        echo "$(date '+%F %T') | ℹ️ Skipping NiFi user/group creation as requested" | tee -a "$LOG_FILE"
        
        # If running as root, ensure directories have proper permissions
        if [[ "$RUN_AS_ROOT" == "true" ]]; then
            echo "$(date '+%F %T') | ℹ️ Setting permissions for root user..." | tee -a "$LOG_FILE"
            sudo chown -R root:root "$NIFI_DIR"
            sudo chmod -R 750 "$NIFI_DIR"
            sudo chmod 700 "$NIFI_DIR/conf"
            sudo chmod 700 "$NIFI_DIR/certs"
            
            # Create data directories with proper permissions
            sudo mkdir -p /var/lib/nifi /var/log/nifi /var/run/nifi
            sudo chown -R root:root /var/lib/nifi /var/log/nifi /var/run/nifi
            sudo chmod 750 /var/lib/nifi /var/log/nifi /var/run/nifi
        fi
    fi
    
    # Create a proper SysV init script as a fallback
    cat > /etc/init.d/nifi <<NIFI_INIT
#!/bin/sh
### BEGIN INIT INFO
# Provides:          nifi
# Required-Start:    \$remote_fs \$syslog
# Required-Stop:     \$remote_fs \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Apache NiFi
# Description:       Apache NiFi data flow system
### END INIT INFO

# Source function library
. /lib/lsb/init-functions

NIFI_DIR=$NIFI_DIR
NIFI_USER=$SERVICE_USER
NIFI_GROUP=$SERVICE_GROUP
JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

case "\$1" in
    start)
        log_daemon_msg "Starting Apache NiFi" "nifi"
        if [ -f \$NIFI_DIR/bin/nifi-wrapper.sh ]; then
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi-wrapper.sh start"
        else
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi.sh start"
        fi
        log_end_msg \$?
        ;;
    stop)
        log_daemon_msg "Stopping Apache NiFi" "nifi"
        if [ -f \$NIFI_DIR/bin/nifi-wrapper.sh ]; then
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi-wrapper.sh stop"
        else
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi.sh stop"
        fi
        log_end_msg \$?
        ;;
    restart)
        \$0 stop
        sleep 2
        \$0 start
        ;;
    status)
        if [ -f \$NIFI_DIR/bin/nifi-wrapper.sh ]; then
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi-wrapper.sh status"
        else
            su - \$NIFI_USER -c "JAVA_HOME=\$JAVA_HOME \$NIFI_DIR/bin/nifi.sh status"
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
NIFI_INIT

    # Make the init script executable
    chmod +x /etc/init.d/nifi

    # Update the init script links
    update-rc.d nifi defaults

    # Start NiFi
    sudo systemctl daemon-reload
    sudo systemctl enable --force nifi
    
    # Check if ports are already in use before starting NiFi
    echo "$(date '+%F %T') | ℹ️ Checking if NiFi ports are available before starting..." | tee -a "$LOG_FILE"
    NIFI_PORTS=(8443 11443)
    PORTS_IN_USE=false
    
    for port in "${NIFI_PORTS[@]}"; do
        pid=$(sudo lsof -t -i:$port 2>/dev/null)
        if [[ -n "$pid" ]]; then
            echo "$(date '+%F %T') | ⚠️ Port $port is already in use by PID $pid" | tee -a "$LOG_FILE"
            echo "$(date '+%F %T') | ℹ️ Process details:" | tee -a "$LOG_FILE"
            sudo ps -f -p $pid | tee -a "$LOG_FILE"
            PORTS_IN_USE=true
            
            # Attempt to kill the process
            echo "$(date '+%F %T') | ℹ️ Attempting to kill process using port $port..." | tee -a "$LOG_FILE"
            sudo kill -15 $pid 2>/dev/null || true
            sleep 2
            
            # Check if port is now available
            if sudo lsof -t -i:$port 2>/dev/null; then
                echo "$(date '+%F %T') | ⚠️ Process still using port $port, force killing..." | tee -a "$LOG_FILE"
                sudo kill -9 $pid 2>/dev/null || true
                sleep 1
                
                # Final check
                if sudo lsof -t -i:$port 2>/dev/null; then
                    echo "$(date '+%F %T') | ❌ Failed to free up port $port, NiFi may fail to start" | tee -a "$LOG_FILE"
                else
                    echo "$(date '+%F %T') | ✅ Successfully freed up port $port" | tee -a "$LOG_FILE"
                fi
            else
                echo "$(date '+%F %T') | ✅ Successfully freed up port $port" | tee -a "$LOG_FILE"
            fi
        else
            echo "$(date '+%F %T') | ✅ Port $port is available" | tee -a "$LOG_FILE"
        fi
    done
    
    echo "$(date '+%F %T') | ℹ️ Port check completed, proceeding with NiFi service start..." | tee -a "$LOG_FILE"
    
    # Start NiFi service with additional checks
    echo "$(date '+%F %T') | ℹ️ Starting NiFi service with additional checks..." | tee -a "$LOG_FILE"
    
    # Verify the service file has proper values
    echo "$(date '+%F %T') | ℹ️ Verifying service file..." | tee -a "$LOG_FILE"
    sudo cat /etc/systemd/system/nifi.service | tee -a "$LOG_FILE"
    
    # Verify the user exists
    echo "$(date '+%F %T') | ℹ️ Verifying NiFi user exists..." | tee -a "$LOG_FILE"
    if ! getent passwd "$SERVICE_USER" | tee -a "$LOG_FILE"; then
        echo "$(date '+%F %T') | ⚠️ Warning: User $SERVICE_USER does not exist in /etc/passwd" | tee -a "$LOG_FILE"
        echo "$(date '+%F %T') | ℹ️ Falling back to root user for service..." | tee -a "$LOG_FILE"
        sudo sed -i "s|^User=.*|User=root|" /etc/systemd/system/nifi.service
        sudo sed -i "s|^Group=.*|Group=root|" /etc/systemd/system/nifi.service
        sudo systemctl daemon-reload
    fi
    
    # Verify bootstrap.conf has proper run.as setting
    echo "$(date '+%F %T') | ℹ️ Verifying bootstrap.conf run.as setting..." | tee -a "$LOG_FILE"
    if ! sudo grep "^run.as=" "$NIFI_DIR/conf/bootstrap.conf" | tee -a "$LOG_FILE"; then
        echo "$(date '+%F %T') | ⚠️ Warning: run.as not found in bootstrap.conf" | tee -a "$LOG_FILE"
        echo "$(date '+%F %T') | ℹ️ Adding run.as=root to bootstrap.conf..." | tee -a "$LOG_FILE"
        echo "run.as=root" | sudo tee -a "$NIFI_DIR/conf/bootstrap.conf" > /dev/null
    fi
    
    # Ensure NiFi directories have proper permissions
    echo "$(date '+%F %T') | ℹ️ Ensuring NiFi directories have proper permissions..." | tee -a "$LOG_FILE"
    sudo chown -R root:root "$NIFI_DIR"
    sudo chmod -R 755 "$NIFI_DIR"
    
    # Reload systemd and start NiFi
    sudo systemctl daemon-reload
    sudo systemctl start nifi
    
    # Check service status after starting
    echo "$(date '+%F %T') | ℹ️ Checking NiFi service status after starting..." | tee -a "$LOG_FILE"
    sudo systemctl status nifi --no-pager | tee -a "$LOG_FILE"
    
    echo "$(date '+%F %T') | ✅ Local NiFi setup complete." | tee -a "$LOG_FILE"
}

# Debug function to help diagnose issues
debug_script_state() {
    echo "$(date '+%F %T') | 🔍 DEBUG: Script state at line ${BASH_LINENO[0]}" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | 🔍 Current working directory: $(pwd)" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | 🔍 SERVER_HOSTS: ${SERVER_HOSTS[*]}" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | 🔍 SERVER_IPS: ${SERVER_IPS[*]}" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | 🔍 CURRENT_HOST: $CURRENT_HOST" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | 🔍 CURRENT_IP: $CURRENT_IP" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | 🔍 NIFI_DIR exists: $(if [[ -d "$NIFI_DIR" ]]; then echo "yes"; else echo "no"; fi)" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | 🔍 CERT_DIR exists: $(if [[ -d "$CERT_DIR" ]]; then echo "yes"; else echo "no"; fi)" | tee -a "$LOG_FILE"
    if [[ -d "$CERT_DIR" ]]; then
        echo "$(date '+%F %T') | 🔍 Certificate directories:" | tee -a "$LOG_FILE"
        ls -la "$CERT_DIR" | tee -a "$LOG_FILE"
    fi
}

for (( i=1; i<=NODE_COUNT; i++ )); do
    HOST="${SERVER_HOSTS[i-1]}"
    IP="${SERVER_IPS[i-1]}"
    USER="${SERVER_USERS[i-1]}"

    echo "$(date '+%F %T') | ℹ️ Processing node $i: Host=$HOST, IP=$IP, User=$USER" | tee -a "$LOG_FILE"
    echo "$(date '+%F %T') | ℹ️ Current host: $CURRENT_HOST, Current IP: $CURRENT_IP" | tee -a "$LOG_FILE"
    
    # Add debug information before node setup
    debug_script_state

    if [[ "$HOST" == "$CURRENT_HOST" || "$IP" == "$CURRENT_IP" ]]; then
        echo "$(date '+%F %T') | ℹ️ Detected as local node" | tee -a "$LOG_FILE"
        setup_local_node "$i" || {
            echo "$(date '+%F %T') | ❌ ERROR: Local node setup failed" | tee -a "$LOG_FILE"
            exit 1
        }
    else
        echo "$(date '+%F %T') | 🖥️ Setting up remote NiFi node $i on $IP..." | tee -a "$LOG_FILE"
        
        # Verify NiFi tarball exists before copying
        if [[ ! -f "$NIFI_TARBALL" ]]; then
            echo "$(date '+%F %T') | ❌ ERROR: NiFi tarball not found: $NIFI_TARBALL" | tee -a "$LOG_FILE"
            exit 1
        fi
        
        # Use SSH key-based authentication for SCP with verbose output and error checking
        echo "$(date '+%F %T') | ℹ️ Copying NiFi tarball to remote node $IP..." | tee -a "$LOG_FILE"
        scp -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$NIFI_TARBALL" "$USER@$IP:/tmp/" || {
            echo "$(date '+%F %T') | ❌ ERROR: Failed to copy NiFi tarball to remote node" | tee -a "$LOG_FILE"
            exit 1
        }
        
        # Verify the tarball was copied successfully
        echo "$(date '+%F %T') | ℹ️ Verifying NiFi tarball was copied to remote node..." | tee -a "$LOG_FILE"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@$IP" "ls -la /tmp/$(basename $NIFI_TARBALL)" || {
            echo "$(date '+%F %T') | ❌ ERROR: NiFi tarball not found on remote node after copy" | tee -a "$LOG_FILE"
            exit 1
        }
        
        # Copy certificate files with error checking
        echo "$(date '+%F %T') | ℹ️ Copying certificate files to remote node..." | tee -a "$LOG_FILE"
        scp -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$CERT_DIR/${SERVER_HOSTS[i-1]}/keystore.p12" \
            "$USER@$IP:/tmp/nifi${i}-keystore.p12" || {
            echo "$(date '+%F %T') | ❌ ERROR: Failed to copy keystore to remote node" | tee -a "$LOG_FILE"
            exit 1
        }
        
        # Create a proper PKCS12 truststore from the CA certificate
        echo "$(date '+%F %T') | ℹ️ Creating PKCS12 truststore from CA certificate..." | tee -a "$LOG_FILE"
        
        # Create a temporary truststore using Java keytool with enhanced error handling
        echo "$(date '+%F %T') | ℹ️ Creating truststore with enhanced process..." | tee -a "$LOG_FILE"
        
        # Clean up any existing files
        rm -f /tmp/nifi-truststore.p12 /tmp/temp-truststore.jks
        
        # Verify the CA certificate exists and is readable
        if [[ ! -f "$CERT_DIR/CA/nifi-rootCA.pem" ]]; then
            echo "$(date '+%F %T') | ❌ ERROR: CA certificate not found at $CERT_DIR/CA/nifi-rootCA.pem" | tee -a "$LOG_FILE"
            exit 1
        fi
        
        # Display certificate info for debugging
        echo "$(date '+%F %T') | ℹ️ CA certificate details:" | tee -a "$LOG_FILE"
        openssl x509 -in "$CERT_DIR/CA/nifi-rootCA.pem" -text -noout | head -10 | tee -a "$LOG_FILE"
        
        # Create a DER format certificate for keytool import
        echo "$(date '+%F %T') | ℹ️ Converting PEM to DER format..." | tee -a "$LOG_FILE"
        openssl x509 -outform der -in "$CERT_DIR/CA/nifi-rootCA.pem" -out /tmp/nifi-rootCA.der || {
            echo "$(date '+%F %T') | ❌ ERROR: Failed to convert certificate to DER format" | tee -a "$LOG_FILE"
            exit 1
        }
        
        # Create PKCS12 truststore directly (more reliable than JKS conversion)
        echo "$(date '+%F %T') | ℹ️ Creating PKCS12 truststore directly..." | tee -a "$LOG_FILE"
        keytool -importcert -noprompt -alias "nifi-ca" \
            -file /tmp/nifi-rootCA.der \
            -keystore /tmp/nifi-truststore.p12 \
            -storetype PKCS12 \
            -storepass "$KEYSTORE_PASS" \
            -keypass "$KEYSTORE_PASS" \
            -v || {
            echo "$(date '+%F %T') | ❌ ERROR: Failed to create PKCS12 truststore" | tee -a "$LOG_FILE"
            exit 1
        }
        
        # Set proper permissions on the truststore
        chmod 644 /tmp/nifi-truststore.p12
        
        # Verify the PKCS12 file with more detailed output
        echo "$(date '+%F %T') | ℹ️ Verifying PKCS12 truststore with detailed output..." | tee -a "$LOG_FILE"
        if ! keytool -list -v -keystore /tmp/nifi-truststore.p12 -storepass "$KEYSTORE_PASS" -storetype PKCS12 | tee -a "$LOG_FILE"; then
            echo "$(date '+%F %T') | ❌ ERROR: PKCS12 truststore verification failed" | tee -a "$LOG_FILE"
            exit 1
        fi
        
        # Verify the PKCS12 file
        echo "$(date '+%F %T') | ℹ️ Verifying PKCS12 truststore..." | tee -a "$LOG_FILE"
        keytool -list -keystore /tmp/nifi-truststore.p12 -storepass "$KEYSTORE_PASS" -storetype PKCS12 || {
            echo "$(date '+%F %T') | ❌ ERROR: PKCS12 truststore verification failed" | tee -a "$LOG_FILE"
            exit 1
        }
        
        # Copy the truststore to the remote node
        scp -v -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "/tmp/nifi-truststore.p12" \
            "$USER@$IP:/tmp/nifi-truststore.p12" || {
            echo "$(date '+%F %T') | ❌ ERROR: Failed to copy truststore to remote node" | tee -a "$LOG_FILE"
            exit 1
        }
        
        # Proceed with remote node setup
        setup_remote_node "$i" "$HOST" "$IP" "$USER"
    fi
done

echo "$(date '+%F %T') | ✅ NiFi cluster setup completed on all nodes." | tee -a "$LOG_FILE"
exit 0

# End of script

#!/bin/bash
# Enhanced script for setting up NiFi single-user credentials
# Provides options for interactive and non-interactive usage, password generation,
# and targeting specific nodes

set -euo pipefail
LOG_FILE="/var/log/nifi_deploy.log"
NIFI_DIR="/opt/nifi"
CONFIG_FILE="./cluster_config.env"
CREDS_FILE="/opt/nifi/admin.env"
SPECIFIC_NODE=""
GENERATE_PASSWORD=false
NON_INTERACTIVE=false
VERIFY_CREDENTIALS=true
MAX_RETRIES=3
RETRY_DELAY=5

# Function to display usage information
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -h, --help                 Display this help message
  -u, --username USERNAME    Specify admin username (for non-interactive mode)
  -p, --password PASSWORD    Specify admin password (for non-interactive mode)
  -g, --generate-password    Generate a random secure password
  -n, --node NODE_ID         Apply credentials only to specific node (1-based index)
  -s, --skip-verification    Skip credential verification step
  -f, --force                Force credential update even if NiFi is not running

Examples:
  $0                         Interactive mode, prompts for username and password
  $0 -g                      Interactive mode with generated password
  $0 -u admin -p password    Non-interactive mode with specified credentials
  $0 -u admin -g             Non-interactive mode with specified username and generated password
  $0 -n 2                    Apply credentials only to node 2

EOF
    exit 1
}

# Function to log messages
log() {
    local level="$1"
    local message="$2"
    local symbol=""
    
    case "$level" in
        "INFO") symbol="ℹ️" ;;
        "SUCCESS") symbol="✅" ;;
        "WARNING") symbol="⚠️" ;;
        "ERROR") symbol="❌" ;;
        *) symbol="ℹ️" ;;
    esac
    
    echo "$(date '+%F %T') | $symbol $message" | tee -a "$LOG_FILE"
}

# Function to generate a secure random password
generate_password() {
    local length=16
    local password=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+?><~' | head -c "$length")
    echo "$password"
}

# Function to validate credentials
validate_credentials() {
    local username="$1"
    local password="$2"
    
    # Check if username is empty
    if [[ -z "$username" ]]; then
        log "ERROR" "Username cannot be empty"
        return 1
    fi
    
    # Check if password is empty
    if [[ -z "$password" ]]; then
        log "ERROR" "Password cannot be empty"
        return 1
    fi
    
    # Check password length (minimum 8 characters)
    if [[ ${#password} -lt 8 ]]; then
        log "ERROR" "Password must be at least 8 characters long"
        return 1
    fi
    
    # Check if password contains at least one uppercase letter, one lowercase letter, and one number
    if ! [[ "$password" =~ [A-Z] && "$password" =~ [a-z] && "$password" =~ [0-9] ]]; then
        log "WARNING" "Password should contain at least one uppercase letter, one lowercase letter, and one number"
    fi
    
    return 0
}

# Function to check if NiFi is running on a node
check_nifi_running() {
    local host="$1"
    local ip="$2"
    local user="$3"
    
    log "INFO" "Checking if NiFi is running on $host ($ip)"
    
    local is_running=false
    
    if [[ "$host" == "$(hostname)" ]]; then
        if sudo systemctl is-active nifi >/dev/null 2>&1; then
            is_running=true
        fi
    else
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "$user@$ip" \
            "sudo systemctl is-active nifi >/dev/null 2>&1"; then
            is_running=true
        fi
    fi
    
    if [[ "$is_running" == "true" ]]; then
        log "INFO" "NiFi is running on $host ($ip)"
        return 0
    else
        log "WARNING" "NiFi is not running on $host ($ip)"
        return 1
    fi
}

# Function to set credentials on a single node
set_creds_on_node() {
    local host="$1"
    local ip="$2"
    local user="$3"
    local username="$4"
    local password="$5"

    log "INFO" "Setting credentials on $host ($ip)"

    # Check if NiFi is running
    if ! check_nifi_running "$host" "$ip" "$user" && [[ "$FORCE" != "true" ]]; then
        log "ERROR" "NiFi is not running on $host ($ip). Use --force to set credentials anyway."
        return 1
    fi

    local success=false
    local attempt=1
    
    while [[ $attempt -le $MAX_RETRIES && "$success" != "true" ]]; do
        log "INFO" "Attempt $attempt of $MAX_RETRIES to set credentials on $host ($ip)"
        
        if [[ "$host" == "$(hostname)" ]]; then
            if sudo $NIFI_DIR/bin/nifi.sh set-single-user-credentials "$username" "$password" >/dev/null 2>&1; then
                success=true
            fi
        else
            if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
                "sudo $NIFI_DIR/bin/nifi.sh set-single-user-credentials '$username' '$password'" >/dev/null 2>&1; then
                success=true
            fi
        fi
        
        if [[ "$success" != "true" ]]; then
            log "WARNING" "Failed to set credentials on $host ($ip) - attempt $attempt"
            ((attempt++))
            sleep $RETRY_DELAY
        fi
    done
    
    if [[ "$success" == "true" ]]; then
        log "SUCCESS" "Credentials set successfully on $host ($ip)"
        return 0
    else
        log "ERROR" "Failed to set credentials on $host ($ip) after $MAX_RETRIES attempts"
        return 1
    fi
}

# Function to verify credentials on a node
verify_credentials_on_node() {
    local host="$1"
    local ip="$2"
    local user="$3"
    
    log "INFO" "Verifying credentials on $host ($ip)"
    
    # Check if the authorizations.xml file exists and contains the username
    local auth_file="$NIFI_DIR/conf/authorizations.xml"
    local success=false
    
    if [[ "$host" == "$(hostname)" ]]; then
        if sudo grep -q "<identity>$NIFI_USER</identity>" "$auth_file" 2>/dev/null; then
            success=true
        fi
    else
        if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
            "sudo grep -q '<identity>$NIFI_USER</identity>' '$auth_file'" 2>/dev/null; then
            success=true
        fi
    fi
    
    if [[ "$success" == "true" ]]; then
        log "SUCCESS" "Credentials verified on $host ($ip)"
        return 0
    else
        log "ERROR" "Failed to verify credentials on $host ($ip)"
        return 1
    fi
}

# Parse command line arguments
FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        -u|--username)
            NIFI_USER="$2"
            NON_INTERACTIVE=true
            shift 2
            ;;
        -p|--password)
            NIFI_PASS="$2"
            NON_INTERACTIVE=true
            shift 2
            ;;
        -g|--generate-password)
            GENERATE_PASSWORD=true
            shift
            ;;
        -n|--node)
            SPECIFIC_NODE="$2"
            shift 2
            ;;
        -s|--skip-verification)
            VERIFY_CREDENTIALS=false
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        *)
            log "ERROR" "Unknown option: $1"
            usage
            ;;
    esac
done

log "INFO" "Setting NiFi admin credentials..."

# Load cluster config
if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR" "Cluster configuration file not found. Run cluster setup first."
    exit 1
fi
source "$CONFIG_FILE"

# Get username and password
if [[ "$NON_INTERACTIVE" != "true" ]]; then
    # Interactive mode
    read -rp "Enter NiFi admin username: " NIFI_USER
    
    if [[ "$GENERATE_PASSWORD" == "true" ]]; then
        NIFI_PASS=$(generate_password)
        echo "Generated password: $NIFI_PASS"
    else
        read -srp "Enter NiFi admin password: " NIFI_PASS
        echo
    fi
else
    # Non-interactive mode
    if [[ -z "${NIFI_USER:-}" ]]; then
        log "ERROR" "Username must be specified in non-interactive mode"
        exit 1
    fi
    
    if [[ "$GENERATE_PASSWORD" == "true" ]]; then
        NIFI_PASS=$(generate_password)
        echo "Generated password: $NIFI_PASS"
    elif [[ -z "${NIFI_PASS:-}" ]]; then
        log "ERROR" "Password must be specified in non-interactive mode"
        exit 1
    fi
fi

# Validate credentials
if ! validate_credentials "$NIFI_USER" "$NIFI_PASS"; then
    log "ERROR" "Invalid credentials. Please try again."
    exit 1
fi

# Using SSH key-based authentication
log "INFO" "Using SSH key-based authentication"

# Apply credentials to nodes
if [[ -n "$SPECIFIC_NODE" ]]; then
    # Apply to specific node
    if [[ ! "$SPECIFIC_NODE" =~ ^[0-9]+$ || "$SPECIFIC_NODE" -lt 1 || "$SPECIFIC_NODE" -gt "$NODE_COUNT" ]]; then
        log "ERROR" "Invalid node ID: $SPECIFIC_NODE. Must be between 1 and $NODE_COUNT."
        exit 1
    fi
    
    i=$SPECIFIC_NODE
    HOST_VAR="NODE_${i}_HOST"
    IP_VAR="NODE_${i}_IP"
    USER_VAR="NODE_${i}_USER"
    HOST=${!HOST_VAR}
    IP=${!IP_VAR}
    USER=${!USER_VAR}
    
    if ! set_creds_on_node "$HOST" "$IP" "$USER" "$NIFI_USER" "$NIFI_PASS"; then
        log "ERROR" "Failed to set credentials on node $i: $HOST ($IP)"
        exit 1
    fi
    
    if [[ "$VERIFY_CREDENTIALS" == "true" ]]; then
        if ! verify_credentials_on_node "$HOST" "$IP" "$USER"; then
            log "ERROR" "Failed to verify credentials on node $i: $HOST ($IP)"
            exit 1
        fi
    fi
else
    # Apply to all nodes
    for (( i=1; i<=NODE_COUNT; i++ )); do
        HOST_VAR="NODE_${i}_HOST"
        IP_VAR="NODE_${i}_IP"
        USER_VAR="NODE_${i}_USER"
        HOST=${!HOST_VAR}
        IP=${!IP_VAR}
        USER=${!USER_VAR}
        
        if ! set_creds_on_node "$HOST" "$IP" "$USER" "$NIFI_USER" "$NIFI_PASS"; then
            log "ERROR" "Failed to set credentials on node $i: $HOST ($IP)"
            exit 1
        fi
        
        if [[ "$VERIFY_CREDENTIALS" == "true" ]]; then
            if ! verify_credentials_on_node "$HOST" "$IP" "$USER"; then
                log "ERROR" "Failed to verify credentials on node $i: $HOST ($IP)"
                exit 1
            fi
        fi
    done
fi

# Save creds locally for reference
sudo mkdir -p "$(dirname "$CREDS_FILE")" 2>/dev/null || true
sudo tee "$CREDS_FILE" >/dev/null <<EOF
NIFI_USER=$NIFI_USER
NIFI_PASS=$NIFI_PASS
EOF

# Set secure permissions on credentials file
sudo chmod 600 "$CREDS_FILE"

log "SUCCESS" "Admin credentials successfully set on all nodes."
log "INFO" "Credentials saved to $CREDS_FILE"
log "INFO" "You can now access the NiFi UI at https://<node-ip>:8443/nifi/"
log "INFO" "Username: $NIFI_USER"
log "INFO" "Password: $NIFI_PASS"

exit 0

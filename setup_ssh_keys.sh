#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/nifi_deploy.log"
CONFIG_FILE="./cluster_config.env"

echo "$(date '+%F %T') | Setting up SSH key-based authentication..." | tee -a "$LOG_FILE"

# Ensure cluster config exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "$(date '+%F %T') | ❌ Cluster configuration not found. Run cluster_setup.sh first." | tee -a "$LOG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# Prompt for SSH password (needed one last time to set up keys)
read -srp "Enter SSH password for all remote nodes: " SSH_PASS
echo
echo "$(date '+%F %T') | 🔑 SSH password entered (hidden)" | tee -a "$LOG_FILE"

# Generate SSH key pair if it doesn't exist
SSH_DIR="$HOME/.ssh"
SSH_KEY="$SSH_DIR/id_rsa"
if [[ ! -f "$SSH_KEY" ]]; then
    echo "$(date '+%F %T') | 🔑 Generating SSH key pair..." | tee -a "$LOG_FILE"
    mkdir -p "$SSH_DIR"
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -C "nifi-automation"
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_KEY"
    chmod 644 "$SSH_KEY.pub"
fi

# Get the public key
SSH_PUB_KEY=$(cat "$SSH_KEY.pub")

# Copy the public key to all remote nodes
for (( i=1; i<=NODE_COUNT; i++ )); do
    IP_VAR="NODE_${i}_IP"
    USER_VAR="NODE_${i}_USER"
    HOST_VAR="NODE_${i}_HOST"
    IP=${!IP_VAR}
    USER=${!USER_VAR}
    HOST=${!HOST_VAR}

    # Skip the local node
    if [[ "$HOST" == "$(hostname)" || "$IP" == "$(hostname -I | awk '{print $1}')" ]]; then
        echo "$(date '+%F %T') | ℹ️ Skipping local node $HOST ($IP)" | tee -a "$LOG_FILE"
        continue
    fi

    echo "$(date '+%F %T') | 🔑 Setting up SSH key for $HOST ($IP)" | tee -a "$LOG_FILE"

    # Create a script to set up the authorized_keys file
    cat > /tmp/setup_auth_keys.sh <<EOF
#!/bin/bash
set -euo pipefail

# Create .ssh directory if it doesn't exist
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Add the public key to authorized_keys
echo "$SSH_PUB_KEY" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Test that it works
echo "SSH key setup complete on \$(hostname)"
EOF

    # Copy the script to the remote node
    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        /tmp/setup_auth_keys.sh "$USER@$IP:/tmp/setup_auth_keys.sh"

    # Make the script executable and run it
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@$IP" \
        "chmod +x /tmp/setup_auth_keys.sh && /tmp/setup_auth_keys.sh"

    # Clean up
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@$IP" \
        "rm -f /tmp/setup_auth_keys.sh"
    rm -f /tmp/setup_auth_keys.sh

    # Test SSH connection
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@$IP" "echo 'SSH key-based authentication is working!'"
done

echo "$(date '+%F %T') | ✅ SSH key-based authentication set up successfully." | tee -a "$LOG_FILE"
echo "$(date '+%F %T') | ℹ️ You can now run the automation scripts without entering SSH passwords." | tee -a "$LOG_FILE"
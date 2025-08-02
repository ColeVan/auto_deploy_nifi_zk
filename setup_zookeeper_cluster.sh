#!/bin/bash
set -euo pipefail

# Error handling function
handle_error() {
    local exit_code=$1
    local error_message=$2
    local error_source=${3:-"unknown"}
    
    echo "$(date '+%F %T') | ❌ ERROR ($exit_code) in $error_source: $error_message" | tee -a "$LOG_FILE"
    
    # Cleanup any temporary files
    rm -f /tmp/zk_setup_commands.sh 2>/dev/null || true
    
    exit $exit_code
}

# Trap errors
trap 'handle_error $? "Unexpected error occurred" "${BASH_SOURCE[0]}:${LINENO}"' ERR

LOG_FILE="/var/log/zookeeper_setup.log"
CONFIG_FILE="./cluster_config.env"
ZOOKEEPER_DIR="/opt/zookeeper"
ZOOKEEPER_TARBALL="/tmp/apache-zookeeper-3.9.3-bin.tar.gz"
ZOOKEEPER_VERSION="apache-zookeeper-3.9.3-bin"
SKIP_SSH_SETUP=${SKIP_SSH_SETUP:-false}  # Set to true to skip SSH key setup

# Define multiple mirror URLs for Zookeeper download
ZOOKEEPER_URLS=(
    "https://downloads.apache.org/zookeeper/zookeeper-3.9.3/apache-zookeeper-3.9.3-bin.tar.gz"
    "https://archive.apache.org/dist/zookeeper/zookeeper-3.9.3/apache-zookeeper-3.9.3-bin.tar.gz"
    "https://dlcdn.apache.org/zookeeper/zookeeper-3.9.3/apache-zookeeper-3.9.3-bin.tar.gz"
    "https://apache.org/dyn/closer.cgi?path=/zookeeper/zookeeper-3.9.3/apache-zookeeper-3.9.3-bin.tar.gz&action=download"
)

echo "$(date '+%F %T') | Starting multi-node Zookeeper cluster setup..." | tee -a "$LOG_FILE"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "$(date '+%F %T') | ❌ Cluster configuration not found." | tee -a "$LOG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

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

# Set up SSH keys if needed (after arrays are populated)
if [[ "$SKIP_SSH_SETUP" == "true" ]]; then
    echo "$(date '+%F %T') | ℹ️ Skipping SSH key setup as requested" | tee -a "$LOG_FILE"
else
    setup_ssh_keys_if_needed
fi

# Using SSH key-based authentication
echo "$(date '+%F %T') | 🔑 Using SSH key-based authentication" | tee -a "$LOG_FILE"

CURRENT_HOST=$(hostname)
CURRENT_IP=$(hostname -I | awk '{print $1}')

# Function to download the Zookeeper tarball with multiple fallback URLs
download_tarball() {
    echo "$(date '+%F %T') | ⬇️ Downloading Zookeeper tarball..." | tee -a "$LOG_FILE"
    
    # Check if the tarball already exists and is valid
    if [[ -f "$ZOOKEEPER_TARBALL" ]]; then
        echo "$(date '+%F %T') | 🔍 Checking existing tarball..." | tee -a "$LOG_FILE"
        if file "$ZOOKEEPER_TARBALL" | grep -q "gzip compressed data"; then
            echo "$(date '+%F %T') | ✅ Existing tarball is valid, skipping download" | tee -a "$LOG_FILE"
            return 0
        else
            echo "$(date '+%F %T') | ⚠️ Existing tarball is invalid, will download again" | tee -a "$LOG_FILE"
            sudo rm -f "$ZOOKEEPER_TARBALL"
        fi
    fi
    
    # Ensure /tmp directory is writable
    if [[ ! -w "/tmp" ]]; then
        echo "$(date '+%F %T') | ⚠️ /tmp directory is not writable, attempting to fix permissions..." | tee -a "$LOG_FILE"
        sudo chmod 1777 /tmp
    fi
    
    # Try each mirror URL until one works
    local download_success=false
    for url in "${ZOOKEEPER_URLS[@]}"; do
        echo "$(date '+%F %T') | 🔄 Trying URL: $url" | tee -a "$LOG_FILE"
        
        for attempt in {1..3}; do
            echo "$(date '+%F %T') | 📥 Download attempt $attempt from $url" | tee -a "$LOG_FILE"
            
            # Use curl instead of wget for better error handling
            if sudo curl -L --connect-timeout 30 --retry 3 --retry-delay 5 -o "$ZOOKEEPER_TARBALL" "$url"; then
                download_success=true
                echo "$(date '+%F %T') | ✅ Download successful from $url" | tee -a "$LOG_FILE"
                break 2  # Break out of both loops
            else
                echo "$(date '+%F %T') | ⚠️ Download attempt $attempt from $url failed" | tee -a "$LOG_FILE"
                sleep 5
            fi
        done
    done
    
    if [[ "$download_success" != "true" ]]; then
        echo "$(date '+%F %T') | ❌ Failed to download Zookeeper tarball from all mirrors" | tee -a "$LOG_FILE"
        handle_error 1 "Failed to download Zookeeper tarball from all mirrors" "download_tarball"
    fi
    
    # Verify the downloaded file
    echo "$(date '+%F %T') | 🔍 Verifying downloaded tarball..." | tee -a "$LOG_FILE"
    
    # Check if file command is available
    if ! command -v file &> /dev/null; then
        echo "$(date '+%F %T') | ⚠️ 'file' command not found, installing..." | tee -a "$LOG_FILE"
        sudo apt-get update && sudo apt-get install -y file
    fi
    
    if ! file "$ZOOKEEPER_TARBALL" | grep -q "gzip compressed data"; then
        echo "$(date '+%F %T') | ❌ Downloaded file is not a valid gzip archive" | tee -a "$LOG_FILE"
        handle_error 1 "Downloaded file is not a valid gzip archive" "verify_tarball"
    fi
    
    echo "$(date '+%F %T') | ✅ Tarball verified successfully" | tee -a "$LOG_FILE"
    return 0
}

# Download the Zookeeper tarball
if [[ ! -f "$ZOOKEEPER_TARBALL" ]] || ! file "$ZOOKEEPER_TARBALL" 2>/dev/null | grep -q "gzip compressed data"; then
    download_tarball
fi

configure_zookeeper() {
    local id="$1"
    local ip="$2"

    echo "$(date '+%F %T') | 🛠️ Configuring Zookeeper on $ip..." | tee -a "$LOG_FILE"

    # Use sudo for local commands (no password needed if sudo is configured properly)
    # Stop ZooKeeper using its own script if it exists
    if [[ -f "$ZOOKEEPER_DIR/bin/zkServer.sh" ]]; then
        echo "$(date '+%F %T') | ℹ️ Stopping ZooKeeper using zkServer.sh..." | tee -a "$LOG_FILE"
        sudo "$ZOOKEEPER_DIR/bin/zkServer.sh" stop || true
    fi
    
    # Kill any running ZooKeeper processes
    sudo pkill -f zkServer.sh || true

    # Remove ZooKeeper service if it exists
    if sudo systemctl list-unit-files | grep -q "^zookeeper.service"; then
        echo "$(date '+%F %T') | ℹ️ Removing ZooKeeper service..." | tee -a "$LOG_FILE"
        sudo systemctl stop zookeeper || true
        sudo systemctl disable zookeeper || true
        sudo rm -f /etc/systemd/system/zookeeper.service
        sudo rm -f /etc/systemd/system/multi-user.target.wants/zookeeper.service || true
    else
        echo "$(date '+%F %T') | ℹ️ No existing Zookeeper service found, fresh install." | tee -a "$LOG_FILE"
    fi
    
    # Find and remove any ZooKeeper-related files in /etc
    echo "$(date '+%F %T') | ℹ️ Removing any ZooKeeper-related files..." | tee -a "$LOG_FILE"
    sudo find /etc -name '*zookeeper*' -exec rm -rf {} \; 2>/dev/null || true
    sudo find /etc/systemd -name '*zookeeper*' -exec rm -rf {} \; 2>/dev/null || true
    sudo find /etc/systemd -name '*zookeeper.service' -exec rm -f {} \; 2>/dev/null || true
    
    # Reset failed systemd units and reload
    sudo systemctl reset-failed || true
    sudo systemctl daemon-reload
    
    # Remove ZooKeeper directory
    echo "$(date '+%F %T') | ℹ️ Removing ZooKeeper directory..." | tee -a "$LOG_FILE"
    sudo rm -rf "$ZOOKEEPER_DIR"
    sudo tar -xzf "$ZOOKEEPER_TARBALL" -C /tmp/
    sudo mv "/tmp/$ZOOKEEPER_VERSION" "$ZOOKEEPER_DIR"

    # Create zoo.cfg file
    cat <<CFG > /tmp/zoo.cfg
tickTime=2000
dataDir=$ZOOKEEPER_DIR/data
clientPortAddress=$ip
clientPort=2181
initLimit=10
syncLimit=5
CFG

    # Add server entries
    for ((j = 1; j <= NODE_COUNT; j++)); do
        echo "server.$j=${SERVER_IPS[j-1]}:2888:3888" >> /tmp/zoo.cfg
    done

    # Move config file to destination
    sudo mkdir -p "$ZOOKEEPER_DIR/conf"
    sudo cp /tmp/zoo.cfg "$ZOOKEEPER_DIR/conf/zoo.cfg"
    rm -f /tmp/zoo.cfg

    # Create data directory and myid file
    sudo mkdir -p "$ZOOKEEPER_DIR/data"
    echo "$id" > /tmp/myid
    sudo cp /tmp/myid "$ZOOKEEPER_DIR/data/myid"
    rm -f /tmp/myid

    # Check if the service file exists in the repository
    if [[ -f "/opt/nifi-zk-auto-deployment/zookeeper.service" ]]; then
        echo "$(date '+%F %T') | ℹ️ Using pre-created zookeeper.service file from repository" | tee -a "$LOG_FILE"
        sudo cp "/opt/nifi-zk-auto-deployment/zookeeper.service" /etc/systemd/system/zookeeper.service
        # Update the service file with the correct paths
        sudo sed -i "s|ZOOKEEPER_DIR|$ZOOKEEPER_DIR|g" /etc/systemd/system/zookeeper.service
    else
        echo "$(date '+%F %T') | ℹ️ Pre-created service file not found, creating dynamically" | tee -a "$LOG_FILE"
        # Create service file
        cat <<SERVICE > /tmp/zookeeper.service
[Unit]
Description=Apache Zookeeper Service
After=network.target
[Service]
Type=forking
ExecStart=$ZOOKEEPER_DIR/bin/zkServer.sh start
ExecStop=$ZOOKEEPER_DIR/bin/zkServer.sh stop
Restart=on-failure
User=root
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
SERVICE

        sudo cp /tmp/zookeeper.service /etc/systemd/system/zookeeper.service
        rm -f /tmp/zookeeper.service
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable zookeeper
    sudo systemctl start zookeeper

    echo "$(date '+%F %T') | ✅ Zookeeper node $id configured and started on $ip" | tee -a "$LOG_FILE"
}

setup_remote_node() {
    local id="$1"
    local ip="$2"
    local user="$3"
    # Use ~/ for the remote path which will be expanded by SSH/SCP
    local remote_tarball_dir="~/zookeeper_setup"
    local remote_tarball_path="$remote_tarball_dir/$(basename "$ZOOKEEPER_TARBALL")"

    echo "$(date '+%F %T') | 🖥️ Setting up remote Zookeeper node $id on $ip..." | tee -a "$LOG_FILE"
    
    # Create a directory in the user's home directory for the tarball
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" "mkdir -p $remote_tarball_dir" || {
        echo "$(date '+%F %T') | ❌ Failed to create directory on remote node $ip" | tee -a "$LOG_FILE"
        handle_error 1 "Failed to create directory on remote node $ip" "setup_remote_node"
    }
    
    # Create a script with all the commands to run on the remote node
    cat > /tmp/zk_setup_commands.sh <<EOF
#!/bin/bash
set -euo pipefail

# Define variables explicitly
ZOOKEEPER_DIR="$ZOOKEEPER_DIR"
# Use absolute path with $HOME for the script that runs on the remote machine
ZOOKEEPER_TARBALL="\$HOME/zookeeper_setup/$(basename "$ZOOKEEPER_TARBALL")"
ZOOKEEPER_VERSION="$ZOOKEEPER_VERSION"
NODE_COUNT="$NODE_COUNT"

# Stop ZooKeeper using its own script if it exists
if [[ -f "\$ZOOKEEPER_DIR/bin/zkServer.sh" ]]; then
    echo "Stopping ZooKeeper using zkServer.sh..."
    sudo "\$ZOOKEEPER_DIR/bin/zkServer.sh" stop || true
fi

# Kill any running ZooKeeper processes
sudo pkill -f zkServer.sh || true

# Check if zookeeper service exists and stop it
if systemctl list-unit-files | grep -q "^zookeeper.service"; then
    echo "Removing ZooKeeper service..."
    sudo systemctl stop zookeeper || true
    sudo systemctl disable zookeeper || true
    sudo rm -f /etc/systemd/system/zookeeper.service
    sudo rm -f /etc/systemd/system/multi-user.target.wants/zookeeper.service || true
else
    echo "No existing Zookeeper service found, fresh install."
fi

# Find and remove any ZooKeeper-related files in /etc
echo "Removing any ZooKeeper-related files..."
sudo find /etc -name '*zookeeper*' -exec rm -rf {} \; 2>/dev/null || true
sudo find /etc/systemd -name '*zookeeper*' -exec rm -rf {} \; 2>/dev/null || true
sudo find /etc/systemd -name '*zookeeper.service' -exec rm -f {} \; 2>/dev/null || true

# Reset failed systemd units and reload
sudo systemctl reset-failed || true
sudo systemctl daemon-reload

# Remove old installation and extract new one
echo "Removing ZooKeeper directory..."
sudo rm -rf "\$ZOOKEEPER_DIR"
echo "Extracting ZooKeeper from \$ZOOKEEPER_TARBALL..."
sudo tar -xzf "\$ZOOKEEPER_TARBALL" -C /tmp/
echo "Extracted ZooKeeper to /tmp/\$ZOOKEEPER_VERSION"
ls -la /tmp/\$ZOOKEEPER_VERSION
sudo mv "/tmp/\$ZOOKEEPER_VERSION" "\$ZOOKEEPER_DIR"
echo "Moved ZooKeeper to \$ZOOKEEPER_DIR"
ls -la \$ZOOKEEPER_DIR

# Create zoo.cfg
sudo mkdir -p "\$ZOOKEEPER_DIR/conf"
cat > /tmp/zoo.cfg <<ZKCONFIG
tickTime=2000
dataDir=\$ZOOKEEPER_DIR/data
clientPortAddress=$ip
clientPort=2181
initLimit=10
syncLimit=5
ZKCONFIG

# Add server entries
EOF

    # Add server entries to the script
    for ((j = 1; j <= NODE_COUNT; j++)); do
        echo "echo \"server.$j=${SERVER_IPS[j-1]}:2888:3888\" >> /tmp/zoo.cfg" >> /tmp/zk_setup_commands.sh
    done

    # Continue with the rest of the setup
    cat >> /tmp/zk_setup_commands.sh <<EOF
# Copy zoo.cfg to destination
sudo cp /tmp/zoo.cfg "\$ZOOKEEPER_DIR/conf/zoo.cfg"
rm -f /tmp/zoo.cfg

# Create data directory and myid file
sudo mkdir -p "\$ZOOKEEPER_DIR/data"
echo "$id" > /tmp/myid
sudo cp /tmp/myid "\$ZOOKEEPER_DIR/data/myid"
rm -f /tmp/myid

# Check if the service file exists in the repository
if [[ -f "/opt/nifi-zk-auto-deployment/zookeeper.service" ]]; then
    echo "Using pre-created zookeeper.service file from repository"
    sudo cp "/opt/nifi-zk-auto-deployment/zookeeper.service" /etc/systemd/system/zookeeper.service
    # Update the service file with the correct paths
    sudo sed -i "s|ZOOKEEPER_DIR|\$ZOOKEEPER_DIR|g" /etc/systemd/system/zookeeper.service
else
    echo "Pre-created service file not found, creating dynamically"
    # Create service file
    cat > /tmp/zookeeper.service <<ZKSERVICE
[Unit]
Description=Apache Zookeeper Service
After=network.target
[Service]
Type=forking
ExecStart=\$ZOOKEEPER_DIR/bin/zkServer.sh start
ExecStop=\$ZOOKEEPER_DIR/bin/zkServer.sh stop
Restart=on-failure
User=root
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
ZKSERVICE

    sudo cp /tmp/zookeeper.service /etc/systemd/system/zookeeper.service
    rm -f /tmp/zookeeper.service
fi

# Start zookeeper
sudo systemctl daemon-reload
sudo systemctl enable zookeeper

# Verify ZooKeeper installation before starting
echo "Verifying ZooKeeper installation..."
if [ ! -f "\$ZOOKEEPER_DIR/bin/zkServer.sh" ]; then
    echo "ERROR: ZooKeeper server script not found at \$ZOOKEEPER_DIR/bin/zkServer.sh"
    ls -la \$ZOOKEEPER_DIR/bin/
    exit 1
fi

# Make sure zkServer.sh is executable
sudo chmod +x "\$ZOOKEEPER_DIR/bin/zkServer.sh"
ls -la \$ZOOKEEPER_DIR/bin/zkServer.sh

# Check if Java is installed
echo "Checking Java installation..."
java -version || {
    echo "ERROR: Java not found. Installing Java..."
    sudo apt-get update
    sudo apt-get install -y default-jre
}

# Check service file content
echo "Checking service file content..."
cat /etc/systemd/system/zookeeper.service

# Try running zkServer.sh directly
echo "Trying to run zkServer.sh directly..."
sudo \$ZOOKEEPER_DIR/bin/zkServer.sh --version || echo "Failed to run zkServer.sh directly"

# Start ZooKeeper
echo "Starting ZooKeeper service..."
sudo systemctl start zookeeper
sleep 2
sudo systemctl status zookeeper --no-pager

# If service failed, check logs
if ! sudo systemctl is-active zookeeper >/dev/null 2>&1; then
    echo "ZooKeeper service failed to start. Checking logs..."
    sudo journalctl -xeu zookeeper.service --no-pager | tail -n 50
fi

echo "Zookeeper node $id configured and started on $ip"
EOF

    # Check if the tarball exists and is valid before copying
    if [[ ! -f "$ZOOKEEPER_TARBALL" ]] || ! file "$ZOOKEEPER_TARBALL" 2>/dev/null | grep -q "gzip compressed data"; then
        echo "$(date '+%F %T') | ⚠️ Tarball not found or invalid, downloading again..." | tee -a "$LOG_FILE"
        download_tarball
    fi
    
    # Copy the tarball to the remote node's home directory
    echo "$(date '+%F %T') | 📤 Copying Zookeeper tarball to remote node $ip..." | tee -a "$LOG_FILE"
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$ZOOKEEPER_TARBALL" "$user@$ip:$remote_tarball_path" || {
        echo "$(date '+%F %T') | ❌ Failed to copy tarball to remote node $ip" | tee -a "$LOG_FILE"
        handle_error 1 "Failed to copy tarball to remote node $ip" "setup_remote_node"
    }
    
    # Copy the setup script to the remote node
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        /tmp/zk_setup_commands.sh "$user@$ip:/tmp/zk_setup_commands.sh"
    
    # Make the script executable and run it with a pseudo-terminal for sudo password prompt
    ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "chmod +x /tmp/zk_setup_commands.sh && /tmp/zk_setup_commands.sh" || {
        echo "$(date '+%F %T') | ❌ Failed to setup Zookeeper on remote node $ip" | tee -a "$LOG_FILE"
        return 1
    }
    
    # Clean up
    rm -f /tmp/zk_setup_commands.sh
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@$ip" \
        "rm -f /tmp/zk_setup_commands.sh"
    
    echo "$(date '+%F %T') | ✅ Remote Zookeeper node $id setup completed on $ip" | tee -a "$LOG_FILE"
}

setup_local_node() {
    local id="$1"
    echo "$(date '+%F %T') | 🖥️ Setting up local Zookeeper node $id..." | tee -a "$LOG_FILE"
    configure_zookeeper "$id" "$CURRENT_IP"
}

for (( i=1; i<=NODE_COUNT; i++ )); do
    HOST="${SERVER_HOSTS[i-1]}"
    IP="${SERVER_IPS[i-1]}"
    USER="${SERVER_USERS[i-1]}"

    echo "$(date '+%F %T') | 🔍 Processing node $i: $HOST ($IP)" | tee -a "$LOG_FILE"

    # Check if this is the current node
    if [[ "$HOST" == "$CURRENT_HOST" || "$IP" == "$CURRENT_IP" ]]; then
        echo "$(date '+%F %T') | ℹ️ This is the current node, setting up locally" | tee -a "$LOG_FILE"
        setup_local_node "$i"
    else
        echo "$(date '+%F %T') | ℹ️ This is a remote node, setting up via SSH" | tee -a "$LOG_FILE"
        
        # Variables for remote node setup
        # Use ~/ for the remote path which will be expanded by SSH/SCP
        remote_tarball_dir="~/zookeeper_setup"
        remote_tarball_path="$remote_tarball_dir/$(basename "$ZOOKEEPER_TARBALL")"
        
        # Create directory on remote node
        echo "$(date '+%F %T') | 📁 Creating directory on remote node $IP..." | tee -a "$LOG_FILE"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@$IP" "mkdir -p $remote_tarball_dir" || {
            echo "$(date '+%F %T') | ❌ Failed to create directory on remote node $IP" | tee -a "$LOG_FILE"
            handle_error 1 "Failed to create directory on remote node $IP" "setup_remote_node"
        }
        
        # Check if the tarball exists and is valid before copying
        if [[ ! -f "$ZOOKEEPER_TARBALL" ]] || ! file "$ZOOKEEPER_TARBALL" 2>/dev/null | grep -q "gzip compressed data"; then
            echo "$(date '+%F %T') | ⚠️ Tarball not found or invalid, downloading again..." | tee -a "$LOG_FILE"
            download_tarball
        fi
        
        # Copy tarball to remote node
        echo "$(date '+%F %T') | 📤 Copying Zookeeper tarball to remote node $IP..." | tee -a "$LOG_FILE"
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "$ZOOKEEPER_TARBALL" "$USER@$IP:$remote_tarball_path" || {
            echo "$(date '+%F %T') | ❌ Failed to copy tarball to remote node $IP" | tee -a "$LOG_FILE"
            handle_error 1 "Failed to copy tarball to remote node $IP" "setup_remote_node"
        }
        
        # Set up the remote node
        setup_remote_node "$i" "$IP" "$USER"
    fi
done

echo "$(date '+%F %T') | ✅ Zookeeper cluster setup completed successfully." | tee -a "$LOG_FILE"
exit 0

# End of script

#!/bin/bash
# NiFi Command Aliases
# This script creates convenient command aliases for common NiFi operations

# Define log file
LOG_FILE="/var/log/nifi_aliases.log"

# Create log file if it doesn't exist
touch "$LOG_FILE" 2>/dev/null || {
    echo "Error: Cannot create log file at $LOG_FILE. Using /tmp/nifi_aliases.log instead."
    LOG_FILE="/tmp/nifi_aliases.log"
    touch "$LOG_FILE"
}

# Log function
log() {
    echo "$(date '+%F %T') | $1" | tee -a "$LOG_FILE"
}

log "Setting up NiFi command aliases..."

# Default NiFi installation directory
NIFI_DIR=${NIFI_DIR:-"/opt/nifi"}

# Check if NiFi is installed
if [ ! -d "$NIFI_DIR" ]; then
    log "NiFi installation not found at $NIFI_DIR. Please set NIFI_DIR environment variable if installed elsewhere."
    exit 1
fi

# Create aliases file
ALIASES_FILE="/etc/profile.d/nifi_aliases.sh"
sudo touch "$ALIASES_FILE" || {
    log "Error: Cannot create aliases file at $ALIASES_FILE. Using /tmp/nifi_aliases.sh instead."
    ALIASES_FILE="/tmp/nifi_aliases.sh"
    touch "$ALIASES_FILE"
}

# Write aliases to file
cat > /tmp/nifi_aliases_temp.sh << 'EOF'
#!/bin/bash
# Apache NiFi command aliases

# NiFi directory
export NIFI_HOME="/opt/nifi"

# Basic NiFi service commands
alias nifi-start='sudo systemctl start nifi'
alias nifi-stop='sudo systemctl stop nifi'
alias nifi-restart='sudo systemctl restart nifi'
alias nifi-status='sudo systemctl status nifi'
alias nifi-enable='sudo systemctl enable nifi'
alias nifi-disable='sudo systemctl disable nifi'

# NiFi logs
alias nifi-logs='sudo tail -f $NIFI_HOME/logs/nifi-app.log'
alias nifi-bootstrap-logs='sudo tail -f $NIFI_HOME/logs/nifi-bootstrap.log'
alias nifi-user-logs='sudo tail -f $NIFI_HOME/logs/nifi-user.log'
alias nifi-all-logs='sudo find $NIFI_HOME/logs -name "*.log" -exec tail -f {} \;'

# NiFi configuration
alias nifi-edit-props='sudo nano $NIFI_HOME/conf/nifi.properties'
alias nifi-edit-bootstrap='sudo nano $NIFI_HOME/conf/bootstrap.conf'
alias nifi-edit-state='sudo nano $NIFI_HOME/conf/state-management.xml'
alias nifi-edit-logback='sudo nano $NIFI_HOME/conf/logback.xml'
alias nifi-edit-login='sudo nano $NIFI_HOME/conf/login-identity-providers.xml'
alias nifi-edit-auth='sudo nano $NIFI_HOME/conf/authorizers.xml'

# NiFi process management
alias nifi-pid='ps aux | grep -i nifi | grep -v grep'
alias nifi-kill='sudo pkill -f "java.*nifi" || echo "No NiFi processes found"'
alias nifi-kill-force='sudo pkill -9 -f "java.*nifi" || echo "No NiFi processes found"'

# NiFi diagnostics
alias nifi-diag='$NIFI_HOME/bin/nifi.sh diagnostics'
alias nifi-env='$NIFI_HOME/bin/nifi.sh env'
alias nifi-heap-dump='sudo -u nifi jmap -dump:format=b,file=/tmp/nifi_heap.bin $(pgrep -f "java.*nifi")'
alias nifi-thread-dump='sudo -u nifi jstack $(pgrep -f "java.*nifi") > /tmp/nifi_threads.txt && echo "Thread dump saved to /tmp/nifi_threads.txt"'

# NiFi system information
alias nifi-version='$NIFI_HOME/bin/nifi.sh version'
alias nifi-disk-usage='du -sh $NIFI_HOME/* | sort -hr'
alias nifi-repo-usage='du -sh $NIFI_HOME/content_repository $NIFI_HOME/provenance_repository $NIFI_HOME/flowfile_repository | sort -hr'
alias nifi-mem-usage='ps -o pid,user,%mem,%cpu,command ax | grep -i nifi | grep -v grep'

# NiFi cluster commands
alias nifi-cluster-nodes='curl -k -s https://localhost:8443/nifi-api/controller/cluster/nodes | python3 -m json.tool'
alias nifi-cluster-status='curl -k -s https://localhost:8443/nifi-api/controller/cluster | python3 -m json.tool'

# NiFi flow commands
alias nifi-list-pgs='curl -k -s https://localhost:8443/nifi-api/process-groups/root/process-groups | python3 -m json.tool'
alias nifi-list-templates='curl -k -s https://localhost:8443/nifi-api/flow/templates | python3 -m json.tool'

# NiFi security commands
alias nifi-users='curl -k -s https://localhost:8443/nifi-api/tenants/users | python3 -m json.tool'
alias nifi-user-groups='curl -k -s https://localhost:8443/nifi-api/tenants/user-groups | python3 -m json.tool'
alias nifi-policies='curl -k -s https://localhost:8443/nifi-api/policies | python3 -m json.tool'

# NiFi help
nifi-help() {
    echo "NiFi Command Aliases:"
    echo "====================="
    echo "Service Management:"
    echo "  nifi-start        - Start NiFi service"
    echo "  nifi-stop         - Stop NiFi service"
    echo "  nifi-restart      - Restart NiFi service"
    echo "  nifi-status       - Check NiFi service status"
    echo "  nifi-enable       - Enable NiFi service at boot"
    echo "  nifi-disable      - Disable NiFi service at boot"
    echo ""
    echo "Logs:"
    echo "  nifi-logs         - View NiFi application logs"
    echo "  nifi-bootstrap-logs - View NiFi bootstrap logs"
    echo "  nifi-user-logs    - View NiFi user logs"
    echo "  nifi-all-logs     - View all NiFi logs"
    echo ""
    echo "Configuration:"
    echo "  nifi-edit-props   - Edit nifi.properties"
    echo "  nifi-edit-bootstrap - Edit bootstrap.conf"
    echo "  nifi-edit-state   - Edit state-management.xml"
    echo "  nifi-edit-logback - Edit logback.xml"
    echo "  nifi-edit-login   - Edit login-identity-providers.xml"
    echo "  nifi-edit-auth    - Edit authorizers.xml"
    echo ""
    echo "Process Management:"
    echo "  nifi-pid          - Show NiFi processes"
    echo "  nifi-kill         - Kill NiFi processes"
    echo "  nifi-kill-force   - Force kill NiFi processes"
    echo ""
    echo "Diagnostics:"
    echo "  nifi-diag         - Run NiFi diagnostics"
    echo "  nifi-env          - Show NiFi environment"
    echo "  nifi-heap-dump    - Create heap dump"
    echo "  nifi-thread-dump  - Create thread dump"
    echo ""
    echo "System Information:"
    echo "  nifi-version      - Show NiFi version"
    echo "  nifi-disk-usage   - Show NiFi disk usage"
    echo "  nifi-repo-usage   - Show NiFi repository usage"
    echo "  nifi-mem-usage    - Show NiFi memory usage"
    echo ""
    echo "Cluster Commands:"
    echo "  nifi-cluster-nodes - List cluster nodes"
    echo "  nifi-cluster-status - Show cluster status"
    echo ""
    echo "Flow Commands:"
    echo "  nifi-list-pgs     - List process groups"
    echo "  nifi-list-templates - List templates"
    echo ""
    echo "Security Commands:"
    echo "  nifi-users        - List users"
    echo "  nifi-user-groups  - List user groups"
    echo "  nifi-policies     - List policies"
}

alias nifi-help='nifi-help'
EOF

# Replace NIFI_HOME with actual NIFI_DIR
sed "s|export NIFI_HOME=\"/opt/nifi\"|export NIFI_HOME=\"$NIFI_DIR\"|" /tmp/nifi_aliases_temp.sh | sudo tee "$ALIASES_FILE" > /dev/null

# Make the aliases file executable
sudo chmod +x "$ALIASES_FILE"

# Remove temporary file
rm -f /tmp/nifi_aliases_temp.sh

log "NiFi command aliases have been set up at $ALIASES_FILE"
log "To use these aliases in the current session, run: source $ALIASES_FILE"
log "The aliases will be automatically loaded for all users in new sessions"

# Add the aliases to the current session
source "$ALIASES_FILE" 2>/dev/null || true

echo ""
echo "Available NiFi aliases (run 'nifi-help' for details):"
echo "-----------------------------------------------------"
echo "Service: nifi-start, nifi-stop, nifi-restart, nifi-status"
echo "Logs: nifi-logs, nifi-bootstrap-logs, nifi-user-logs"
echo "Config: nifi-edit-props, nifi-edit-bootstrap, nifi-edit-state"
echo "Process: nifi-pid, nifi-kill, nifi-kill-force"
echo "Diagnostics: nifi-diag, nifi-env, nifi-heap-dump, nifi-thread-dump"
echo "System: nifi-version, nifi-disk-usage, nifi-repo-usage, nifi-mem-usage"
echo "Cluster: nifi-cluster-nodes, nifi-cluster-status"
echo "Flow: nifi-list-pgs, nifi-list-templates"
echo "Security: nifi-users, nifi-user-groups, nifi-policies"
echo "Help: nifi-help"
echo ""
echo "For full details, run: nifi-help"
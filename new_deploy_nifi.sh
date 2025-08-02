#!/bin/bash
set -euo pipefail

# === Colors and Formatting ===
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
RED="\e[31m"
BLUE="\e[34m"
MAGENTA="\e[35m"
GRAY="\e[90m"
NC="\e[0m"
BOLD="\e[1m"
DIM="\e[2m"

# === Icons ===
ICON_CHECK="✅"
ICON_CROSS="❌"
ICON_WARN="⚠️"
ICON_INFO="ℹ️"
ICON_GEAR="⚙️"
ICON_ROCKET="🚀"
ICON_WRENCH="🔧"
ICON_KEY="🔑"
ICON_SHIELD="🛡️"
ICON_SERVER="🖥️"
ICON_CLUSTER="🌐"
ICON_DOWNLOAD="⬇️"
ICON_START="▶️"
ICON_STOP="⏹️"
ICON_CLEANUP="🧹"
ICON_HEALTH="🩺"
ICON_HELP="❓"
ICON_EXIT="🚪"

# === Configuration ===
CONFIG_FILE="./cluster_config.env"
STATUS_FILE="./.deploy_status"

# === Make all scripts executable ===
for script in *.sh; do
    [[ "$script" != "$(basename "$0")" ]] && sudo chmod +x "$script"
done

# === Helper Functions ===
run_script() {
    sudo -E env "BASH_ENV=" bash "$@"
}

print_header() {
    local title="$1"
    local width=70
    local padding=$(( (width - ${#title}) / 2 ))
    
    echo
    echo -e "${BLUE}${BOLD}$(printf '═%.0s' $(seq 1 $width))${NC}"
    echo -e "${BLUE}${BOLD}$(printf ' %.0s' $(seq 1 $padding))$title${NC}"
    echo -e "${BLUE}${BOLD}$(printf '═%.0s' $(seq 1 $width))${NC}"
    echo
}

print_section() {
    local title="$1"
    echo -e "\n${MAGENTA}${BOLD}[ $title ]${NC}\n"
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        local options="[Y/n]"
    else
        local options="[y/N]"
    fi
    
    while true; do
        read -rp "$(echo -e "${YELLOW}$prompt $options: ${NC}")" choice
        choice=${choice:-$default}
        case "$choice" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo -e "${RED}Please answer yes or no.${NC}" ;;
        esac
    done
}

# Initialize or read status file
init_status() {
    if [[ ! -f "$STATUS_FILE" ]]; then
        cat > "$STATUS_FILE" <<EOF
PREREQS_INSTALLED=false
CLUSTER_CONFIGURED=false
NIFI_DOWNLOADED=false
TLS_GENERATED=false
ZOOKEEPER_SETUP=false
NIFI_SETUP=false
ADMIN_CREDS_SET=false
SSH_KEYS_SETUP=false
EOF
    fi
    
    source "$STATUS_FILE"
}

update_status() {
    local key="$1"
    local value="$2"
    
    # Update the status file
    sed -i "s/^$key=.*/$key=$value/" "$STATUS_FILE"
    
    # Also update the current environment
    eval "$key=$value"
}

get_status_icon() {
    local status="$1"
    if [[ "$status" == "true" ]]; then
        echo -e "${GREEN}$ICON_CHECK${NC}"
    else
        echo -e "${GRAY}$ICON_CROSS${NC}"
    fi
}

show_status() {
    print_section "Current Deployment Status"
    
    echo -e "$(get_status_icon $PREREQS_INSTALLED) Prerequisites Installation"
    echo -e "$(get_status_icon $CLUSTER_CONFIGURED) Cluster Configuration"
    echo -e "$(get_status_icon $SSH_KEYS_SETUP) SSH Keys Setup"
    echo -e "$(get_status_icon $NIFI_DOWNLOADED) NiFi Download"
    echo -e "$(get_status_icon $TLS_GENERATED) TLS Certificate Generation"
    echo -e "$(get_status_icon $ZOOKEEPER_SETUP) ZooKeeper Cluster Setup"
    echo -e "$(get_status_icon $NIFI_SETUP) NiFi Cluster Setup"
    echo -e "$(get_status_icon $ADMIN_CREDS_SET) Admin Credentials Setup"
    
    # Show cluster configuration if available
    if [[ -f "$CONFIG_FILE" && "$CLUSTER_CONFIGURED" == "true" ]]; then
        echo
        echo -e "${CYAN}${BOLD}Cluster Configuration:${NC}"
        source "$CONFIG_FILE"
        echo -e "${CYAN}Number of Nodes:${NC} $NODE_COUNT"
        for (( i=1; i<=NODE_COUNT; i++ )); do
            IP_VAR="NODE_${i}_IP"
            HOST_VAR="NODE_${i}_HOST"
            echo -e "${CYAN}Node $i:${NC} ${!HOST_VAR} (${!IP_VAR})"
        done
    fi
    
    echo
}

show_help() {
    print_section "Deployment Help"
    
    echo -e "${BOLD}Recommended Deployment Order:${NC}"
    echo -e "1. Install Prerequisites"
    echo -e "2. Configure Cluster"
    echo -e "3. Setup SSH Keys"
    echo -e "4. Download NiFi"
    echo -e "5. Generate TLS Certificates"
    echo -e "6. Setup ZooKeeper Cluster"
    echo -e "7. Setup NiFi Cluster"
    echo -e "8. Set Admin Credentials"
    echo -e "9. Check Cluster Health"
    echo
    echo -e "${BOLD}Alternative for Single Node:${NC}"
    echo -e "1. Install Prerequisites"
    echo -e "2. Download NiFi"
    echo -e "3. Generate TLS Certificates"
    echo -e "4. Configure NiFi (single node)"
    echo -e "5. Set Admin Credentials"
    echo -e "6. Start NiFi"
    echo
    echo -e "${BOLD}For Quick Deployment:${NC}"
    echo -e "Use the 'Full Cluster Deployment' option to run all steps automatically."
    echo
    echo -e "${BOLD}Troubleshooting:${NC}"
    echo -e "- If deployment fails, check the logs in /var/log/"
    echo -e "- Use 'Check Cluster Health' to verify the status of your cluster"
    echo -e "- If needed, use 'Cleanup' to start fresh, but this will remove all data"
    echo
}

# Initialize status
init_status

# Main menu loop
while true; do
    clear
    print_header "Apache NiFi & ZooKeeper Deployment"
    
    show_status
    
    print_section "Deployment Menu"
    
    # Setup Section
    echo -e "${YELLOW}${BOLD}Setup:${NC}"
    echo -e "  ${CYAN}1)${NC} ${ICON_WRENCH} Install Prerequisites ${DIM}(Java, tools, dependencies)${NC}"
    echo -e "  ${CYAN}2)${NC} ${ICON_GEAR} Configure Cluster/Single Node ${DIM}(Define nodes, IPs, hostnames)${NC}"
    echo -e "  ${CYAN}3)${NC} ${ICON_KEY} Setup SSH Keys ${DIM}(Configure passwordless SSH between nodes)${NC}"
    
    # Installation Section
    echo -e "\n${YELLOW}${BOLD}Installation:${NC}"
    echo -e "  ${CYAN}4)${NC} ${ICON_DOWNLOAD} Download NiFi ${DIM}(Fetch NiFi binaries)${NC}"
    echo -e "  ${CYAN}5)${NC} ${ICON_SHIELD} Generate TLS Certificates ${DIM}(Create security certificates)${NC}"
    
    # Deployment Section
    echo -e "\n${YELLOW}${BOLD}Deployment:${NC}"
    echo -e "  ${CYAN}6)${NC} ${ICON_SERVER} Configure NiFi (Single Node) ${DIM}(Setup standalone instance)${NC}"
    echo -e "  ${CYAN}7)${NC} ${ICON_CLUSTER} Setup ZooKeeper Cluster ${DIM}(Deploy ZooKeeper across nodes)${NC}"
    echo -e "  ${CYAN}8)${NC} ${ICON_CLUSTER} Setup NiFi Cluster ${DIM}(Deploy NiFi across nodes)${NC}"
    
    # Management Section
    echo -e "\n${YELLOW}${BOLD}Management:${NC}"
    echo -e "  ${CYAN}9)${NC} ${ICON_KEY} Set Admin Username & Password ${DIM}(Configure admin credentials)${NC}"
    echo -e "  ${CYAN}10)${NC} ${ICON_START} Start NiFi ${DIM}(Start single node instance)${NC}"
    echo -e "  ${CYAN}11)${NC} ${ICON_HEALTH} Check Cluster Health ${DIM}(Verify cluster status)${NC}"
    
    # Automation Section
    echo -e "\n${YELLOW}${BOLD}Automation:${NC}"
    echo -e "  ${CYAN}12)${NC} ${ICON_ROCKET} Full Cluster Deployment ${DIM}(Run all steps automatically)${NC}"
    
    # Utilities Section
    echo -e "\n${YELLOW}${BOLD}Utilities:${NC}"
    echo -e "  ${CYAN}13)${NC} ${ICON_CLEANUP} Cleanup Old Install ${DIM}(Remove previous installation)${NC}"
    echo -e "  ${CYAN}14)${NC} ${ICON_HELP} Help ${DIM}(Show deployment guidance)${NC}"
    echo -e "  ${CYAN}15)${NC} ${ICON_EXIT} Exit ${DIM}(Quit this menu)${NC}"
    
    echo
    read -rp "$(echo -e "${CYAN}Select option [1-15]: ${NC}")" choice
    
    case $choice in
        1)  # Install prerequisites
            print_header "Installing Prerequisites"
            run_script ./install_prereqs.sh
            update_status "PREREQS_INSTALLED" "true"
            ;;
            
        2)  # Cluster/Single Node Setup
            print_header "Configuring Cluster"
            run_script ./cluster_setup.sh
            update_status "CLUSTER_CONFIGURED" "true"
            ;;
            
        3)  # Setup SSH Keys
            print_header "Setting Up SSH Keys"
            run_script ./setup_ssh_keys.sh
            update_status "SSH_KEYS_SETUP" "true"
            ;;
            
        4)  # Download NiFi
            print_header "Downloading NiFi"
            read -rp "$(echo -e "${CYAN}Enter NiFi version (default 2.5.0): ${NC}")" v
            v=${v:-2.5.0}
            run_script ./download_nifi.sh "$v"
            update_status "NIFI_DOWNLOADED" "true"
            ;;
            
        5)  # Generate TLS Certificates
            print_header "Generating TLS Certificates"
            run_script ./generate_tls.sh
            update_status "TLS_GENERATED" "true"
            ;;
            
        6)  # Configure NiFi (single node)
            print_header "Configuring NiFi (Single Node)"
            if [[ "$NIFI_DOWNLOADED" != "true" ]]; then
                echo -e "${YELLOW}${ICON_WARN} Warning: NiFi has not been downloaded yet.${NC}"
                if ! confirm "Do you want to continue anyway?" "n"; then
                    continue
                fi
            fi
            run_script ./configure_nifi.sh
            ;;
            
        7)  # Setup Zookeeper Cluster
            print_header "Setting Up ZooKeeper Cluster"
            if [[ "$CLUSTER_CONFIGURED" != "true" ]]; then
                echo -e "${RED}${ICON_CROSS} Error: Cluster configuration is required first.${NC}"
                echo -e "${YELLOW}Please run option 2 (Configure Cluster) before setting up ZooKeeper.${NC}"
                sleep 3
                continue
            fi
            run_script ./setup_zookeeper_cluster.sh
            update_status "ZOOKEEPER_SETUP" "true"
            ;;
            
        8)  # Setup NiFi Cluster
            print_header "Setting Up NiFi Cluster"
            if [[ "$ZOOKEEPER_SETUP" != "true" ]]; then
                echo -e "${YELLOW}${ICON_WARN} Warning: ZooKeeper cluster has not been set up yet.${NC}"
                if ! confirm "Do you want to continue anyway?" "n"; then
                    continue
                fi
            fi
            run_script ./setup_nifi_cluster.sh
            update_status "NIFI_SETUP" "true"
            ;;
            
        9)  # Set Admin Username & Password
            print_header "Setting Admin Credentials"
            run_script ./set_admin_creds.sh
            update_status "ADMIN_CREDS_SET" "true"
            ;;
            
        10) # Start NiFi
            print_header "Starting NiFi"
            run_script ./start_nifi.sh
            ;;
            
        11) # Check Cluster Health
            print_header "Checking Cluster Health"
            run_script ./check_cluster_health.sh
            ;;
            
        12) # Full Cluster Deployment
            print_header "Full Cluster Deployment"
            echo -e "${CYAN}${ICON_ROCKET} Performing Full Cluster Deployment...${NC}"
            
            if confirm "This will run all deployment steps. Continue?" "y"; then
                read -rp "$(echo -e "${CYAN}Enter NiFi version (default 2.5.0): ${NC}")" full_v
                full_v=${full_v:-2.5.0}
                
                # Ask if cleanup is needed
                if confirm "Do you want to clean up any previous installation?" "n"; then
                    run_script ./cleanup.sh
                fi
                
                # Run all steps in sequence
                run_script ./install_prereqs.sh
                update_status "PREREQS_INSTALLED" "true"
                
                # Check if cluster is already configured
                if [[ "$CLUSTER_CONFIGURED" == "true" && -f "$CONFIG_FILE" ]]; then
                    echo -e "${CYAN}${ICON_INFO} Existing cluster configuration found.${NC}"
                    
                    # Source the config file to display current settings
                    source "$CONFIG_FILE"
                    echo -e "${CYAN}Current cluster configuration:${NC}"
                    echo -e "${CYAN}Number of Nodes:${NC} $NODE_COUNT"
                    for (( i=1; i<=NODE_COUNT; i++ )); do
                        IP_VAR="NODE_${i}_IP"
                        HOST_VAR="NODE_${i}_HOST"
                        USER_VAR="NODE_${i}_USER"
                        echo -e "${CYAN}Node $i:${NC} ${!HOST_VAR} (${!IP_VAR}) - User: ${!USER_VAR}"
                    done
                    
                    if confirm "Do you want to reuse this configuration?" "y"; then
                        echo -e "${GREEN}${ICON_CHECK} Reusing existing cluster configuration.${NC}"
                    else
                        run_script ./cluster_setup.sh
                    fi
                else
                    run_script ./cluster_setup.sh
                    update_status "CLUSTER_CONFIGURED" "true"
                fi
                
                run_script ./setup_ssh_keys.sh
                update_status "SSH_KEYS_SETUP" "true"
                
                run_script ./download_nifi.sh "$full_v"
                update_status "NIFI_DOWNLOADED" "true"
                
                run_script ./generate_tls.sh
                update_status "TLS_GENERATED" "true"
                
                run_script ./setup_zookeeper_cluster.sh
                update_status "ZOOKEEPER_SETUP" "true"
                
                run_script ./setup_nifi_cluster.sh
                update_status "NIFI_SETUP" "true"
                
                run_script ./set_admin_creds.sh
                update_status "ADMIN_CREDS_SET" "true"
                
                echo -e "${GREEN}${ICON_CHECK} Full cluster deployment completed successfully!${NC}"
            fi
            ;;
            
        13) # Cleanup old install
            print_header "Cleaning Up Old Installation"
            if confirm "This will remove all previous NiFi and ZooKeeper installations. Continue?" "n"; then
                run_script ./cleanup.sh
                
                # Reset status after cleanup
                update_status "PREREQS_INSTALLED" "false"
                update_status "CLUSTER_CONFIGURED" "false"
                update_status "NIFI_DOWNLOADED" "false"
                update_status "TLS_GENERATED" "false"
                update_status "ZOOKEEPER_SETUP" "false"
                update_status "NIFI_SETUP" "false"
                update_status "ADMIN_CREDS_SET" "false"
                update_status "SSH_KEYS_SETUP" "false"
            fi
            ;;
            
        14) # Help
            show_help
            ;;
            
        15) # Exit
            echo -e "${RED}${ICON_EXIT} Exiting...${NC}"
            exit 0
            ;;
            
        *)  # Invalid option
            echo -e "${RED}${ICON_CROSS} Invalid option. Please select 1-15.${NC}"
            ;;
    esac
    
    echo -e "\n${GREEN}${BOLD}Task completed.${NC} Press Enter to return to menu..."
    read -r
done
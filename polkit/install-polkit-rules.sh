#!/bin/bash
#===============================================================================
# MnMs.io Polkit Rules Installation Script
# 
# Installs the Polkit rules and action definitions for the MnMs.io
# three-dimensional permission system (Roles, Attributes, Scopes)
#===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#===============================================================================
# ROLE GROUPS
#===============================================================================

ROLE_GROUPS=(
    # Dev Roles
    "mnm-dbdevs"
    "mnm-appdevs"
    # Ops Roles
    "mnm-sysops"
    "mnm-netops"
    "mnm-dbaops"
    "mnm-dataops"
    "mnm-secops"
    "mnm-chkops"
    # Derived Roles
    "mnm-mlops"
    "mnm-aiops"
    "mnm-finops"
    "mnm-billops"
)

#===============================================================================
# FUNCTIONS
#===============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

create_role_groups() {
    log_info "Creating role groups..."
    
    for group in "${ROLE_GROUPS[@]}"; do
        if getent group "$group" > /dev/null 2>&1; then
            log_warn "Group $group already exists"
        else
            groupadd "$group"
            log_success "Created group: $group"
        fi
    done
}

install_polkit_rules() {
    log_info "Installing Polkit rules..."
    
    local rules_dir="/etc/polkit-1/rules.d"
    
    # Check if rules directory exists
    if [[ ! -d "$rules_dir" ]]; then
        log_error "Polkit rules directory not found: $rules_dir"
        exit 1
    fi
    
    # Copy rule files
    local rules_files=(
        "00-mnm-base.rules"
        "10-mnm-sysops.rules"
        "20-mnm-netops.rules"
        "30-mnm-dbops.rules"
        "40-mnm-devops.rules"
        "50-mnm-secops.rules"
        "60-mnm-derived.rules"
    )
    
    for rule_file in "${rules_files[@]}"; do
        if [[ -f "$SCRIPT_DIR/$rule_file" ]]; then
            cp "$SCRIPT_DIR/$rule_file" "$rules_dir/"
            chmod 644 "$rules_dir/$rule_file"
            log_success "Installed: $rule_file"
        else
            log_warn "Rule file not found: $rule_file"
        fi
    done
}

install_polkit_actions() {
    log_info "Installing Polkit action definitions..."
    
    local actions_dir="/usr/share/polkit-1/actions"
    
    if [[ ! -d "$actions_dir" ]]; then
        log_error "Polkit actions directory not found: $actions_dir"
        exit 1
    fi
    
    if [[ -f "$SCRIPT_DIR/io.mnm.policy" ]]; then
        cp "$SCRIPT_DIR/io.mnm.policy" "$actions_dir/"
        chmod 644 "$actions_dir/io.mnm.policy"
        log_success "Installed: io.mnm.policy"
    else
        log_warn "Action file not found: io.mnm.policy"
    fi
}

restart_polkit() {
    log_info "Restarting Polkit service..."
    
    if systemctl is-active --quiet polkit; then
        systemctl restart polkit
        log_success "Polkit service restarted"
    else
        log_warn "Polkit service is not running"
    fi
}

show_usage() {
    cat << EOF
Usage: $0 <command>

Commands:
    install     Install Polkit rules, actions, and create role groups
    uninstall   Remove Polkit rules and actions (keeps groups)
    status      Show installation status
    add-role    Add a user to a role group
    remove-role Remove a user from a role group
    list-roles  List all role groups and their members

Examples:
    # Install everything
    $0 install

    # Add user to SysOps role
    $0 add-role xdoc_api sysops

    # Remove user from role
    $0 remove-role xdoc_api sysops

    # Check if user has permission
    pkcheck --action-id io.mnm.scope.monitoring.logs --process \$\$ --user xdoc_api
EOF
}

add_role() {
    local user="$1"
    local role="$2"
    
    if [[ -z "$user" || -z "$role" ]]; then
        log_error "Usage: $0 add-role <user> <role>"
        exit 1
    fi
    
    local group="mnm-${role,,}"  # lowercase
    
    if ! getent group "$group" > /dev/null 2>&1; then
        log_error "Role group not found: $group"
        log_info "Available roles: ${ROLE_GROUPS[*]}"
        exit 1
    fi
    
    if ! id "$user" > /dev/null 2>&1; then
        log_error "User not found: $user"
        exit 1
    fi
    
    usermod -aG "$group" "$user"
    log_success "Added $user to role: $role (group: $group)"
}

remove_role() {
    local user="$1"
    local role="$2"
    
    if [[ -z "$user" || -z "$role" ]]; then
        log_error "Usage: $0 remove-role <user> <role>"
        exit 1
    fi
    
    local group="mnm-${role,,}"
    
    gpasswd -d "$user" "$group" 2>/dev/null || true
    log_success "Removed $user from role: $role"
}

list_roles() {
    echo ""
    echo "MnMs.io Role Groups"
    echo "==================="
    echo ""
    
    for group in "${ROLE_GROUPS[@]}"; do
        local members=$(getent group "$group" 2>/dev/null | cut -d: -f4)
        local role="${group#mnm-}"
        
        if getent group "$group" > /dev/null 2>&1; then
            printf "%-15s : %s\n" "$role" "${members:-<no members>}"
        else
            printf "%-15s : %s\n" "$role" "<not installed>"
        fi
    done
    echo ""
}

show_status() {
    echo ""
    echo "MnMs.io Polkit Installation Status"
    echo "==================================="
    echo ""
    
    # Check Polkit service
    if systemctl is-active --quiet polkit; then
        echo -e "Polkit Service: ${GREEN}running${NC}"
    else
        echo -e "Polkit Service: ${RED}not running${NC}"
    fi
    
    # Check rule files
    echo ""
    echo "Rule Files:"
    for rule in /etc/polkit-1/rules.d/*-mnm-*.rules; do
        if [[ -f "$rule" ]]; then
            echo -e "  ${GREEN}✓${NC} $(basename "$rule")"
        fi
    done
    
    # Check action file
    echo ""
    echo "Action Definitions:"
    if [[ -f "/usr/share/polkit-1/actions/io.mnm.policy" ]]; then
        echo -e "  ${GREEN}✓${NC} io.mnm.policy"
    else
        echo -e "  ${RED}✗${NC} io.mnm.policy"
    fi
    
    # Check groups
    echo ""
    echo "Role Groups:"
    for group in "${ROLE_GROUPS[@]}"; do
        if getent group "$group" > /dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} $group"
        else
            echo -e "  ${RED}✗${NC} $group"
        fi
    done
    echo ""
}

uninstall() {
    log_info "Uninstalling MnMs.io Polkit rules..."
    
    # Remove rule files
    rm -f /etc/polkit-1/rules.d/*-mnm-*.rules
    log_success "Removed rule files"
    
    # Remove action file
    rm -f /usr/share/polkit-1/actions/io.mnm.policy
    log_success "Removed action definitions"
    
    # Restart Polkit
    restart_polkit
    
    log_warn "Role groups were NOT removed. Remove manually if needed:"
    echo "  groupdel mnm-sysops"
    echo "  etc..."
}

#===============================================================================
# MAIN
#===============================================================================

case "${1:-}" in
    install)
        check_root
        create_role_groups
        install_polkit_rules
        install_polkit_actions
        restart_polkit
        echo ""
        log_success "MnMs.io Polkit rules installed successfully!"
        echo ""
        echo "Next steps:"
        echo "  1. Add users to role groups:"
        echo "     $0 add-role xdoc_api sysops"
        echo ""
        echo "  2. Test permissions:"
        echo "     pkcheck --action-id io.mnm.scope.monitoring.logs --process \$\$ --user xdoc_api"
        echo ""
        ;;
    uninstall)
        check_root
        uninstall
        ;;
    status)
        show_status
        ;;
    add-role)
        check_root
        add_role "$2" "$3"
        ;;
    remove-role)
        check_root
        remove_role "$2" "$3"
        ;;
    list-roles)
        list_roles
        ;;
    *)
        show_usage
        exit 1
        ;;
esac

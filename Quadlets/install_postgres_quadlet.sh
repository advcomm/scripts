#!/bin/bash
#===============================================================================
# PostgreSQL Quadlet Installation Script
# 
# Creates a PostgreSQL container as a Podman Quadlet with:
# - Peer authentication using OS user UID mapping
# - Shared socket volume for other containers
# - Integration with the tenant provisioning system
# - Auto-creates tenant and app user if they don't exist
#
# Author: System Architect
# Version: 1.1.0
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
readonly QUADLET_DIR="/etc/containers/systemd"
readonly BASE_DIR="/srv"
readonly LOG_DIR="/var/log/tenant-apps"

# Default values
DEFAULT_POSTGRES_VERSION="16"
DEFAULT_CONTAINER_NAME="pg-root-peer"
DEFAULT_DATA_DIR="/var/lib/postgresql-quadlet"
DEFAULT_SOCKET_VOLUME="pg-run-volume"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

#-------------------------------------------------------------------------------
# Helper Functions
#-------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_podman() {
    if ! command -v podman &> /dev/null; then
        log_error "Podman is not installed. Please install podman first."
        exit 1
    fi
}

validate_name() {
    local name="$1"
    local type="$2"
    
    if [[ ! "$name" =~ ^[a-z][a-z0-9_]{0,31}$ ]]; then
        log_error "Invalid $type name: '$name'. Must be lowercase, start with letter, max 32 chars, only alphanumeric/underscore."
        return 1
    fi
    return 0
}

#-------------------------------------------------------------------------------
# Tenant/App User Management (same as provision-tenant-app.sh)
#-------------------------------------------------------------------------------
create_tenant_if_not_exists() {
    local tenant_name="$1"
    
    validate_name "$tenant_name" "tenant" || return 1
    
    if getent group "$tenant_name" > /dev/null 2>&1; then
        log_info "Tenant group '$tenant_name' already exists"
        return 0
    fi
    
    groupadd "$tenant_name"
    log_info "Created tenant group: $tenant_name"
    
    local tenant_dir="${BASE_DIR}/${tenant_name}"
    mkdir -p "$tenant_dir"
    chown root:"$tenant_name" "$tenant_dir"
    chmod 2750 "$tenant_dir"
    
    log_info "Created tenant directory: $tenant_dir"
    return 0
}

create_app_user_if_not_exists() {
    local tenant_name="$1"
    local app_name="$2"
    local app_user="${tenant_name}_${app_name}"
    
    validate_name "$app_name" "app" || return 1
    
    # Check if user already exists
    if id "$app_user" > /dev/null 2>&1; then
        log_info "App user '$app_user' already exists with UID $(id -u "$app_user")"
        return 0
    fi
    
    # Get next available UID in the 100000+ range
    local next_uid
    next_uid=$(awk -F: 'BEGIN{max=100000} $3>=100000 && $3>max {max=$3} END{print max+1}' /etc/passwd)
    
    if ! useradd \
        --system \
        --uid "$next_uid" \
        --gid "$tenant_name" \
        --no-create-home \
        --shell /usr/sbin/nologin \
        --comment "DB_App_${app_name}_Tenant_${tenant_name}" \
        "$app_user"; then
        log_error "Failed to create user: $app_user"
        return 1
    fi
    
    log_info "Created app user: $app_user (UID: $next_uid, GID: $(getent group "$tenant_name" | cut -d: -f3))"
    return 0
}

create_app_directories() {
    local tenant_name="$1"
    local app_name="$2"
    local app_user="${tenant_name}_${app_name}"
    local app_dir="${BASE_DIR}/${tenant_name}/${app_name}"
    
    mkdir -p "$app_dir"/{read,write,exec,shared,data,config,logs,secrets}
    
    chown -R "$app_user":"$tenant_name" "$app_dir"
    chmod 2750 "$app_dir"
    chmod 2550 "$app_dir/read"
    chmod 2700 "$app_dir/write"
    chmod 2550 "$app_dir/exec"
    chmod 2750 "$app_dir/shared"
    chmod 2700 "$app_dir/data"
    chmod 2500 "$app_dir/config"
    chmod 2700 "$app_dir/logs"
    chmod 2500 "$app_dir/secrets"
    
    log_info "Created app directories: $app_dir"
}

get_or_create_app_uid() {
    local tenant_name="$1"
    local app_name="$2"
    local app_user="${tenant_name}_${app_name}"
    
    # Create tenant and app user if they don't exist
    create_tenant_if_not_exists "$tenant_name" || return 1
    create_app_user_if_not_exists "$tenant_name" "$app_name" || return 1
    
    # Return the UID
    id -u "$app_user"
}

get_or_create_app_gid() {
    local tenant_name="$1"
    local app_name="$2"
    local app_user="${tenant_name}_${app_name}"
    
    # Return the GID (tenant group)
    getent group "$tenant_name" | cut -d: -f3
}

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    cat << EOF
PostgreSQL Quadlet Installation Script

Usage: $(basename "$0") <command> [options]

Commands:
  install                              Install PostgreSQL as a Quadlet container
  uninstall                            Remove PostgreSQL Quadlet and optionally data
  status                               Show PostgreSQL service status
  connect [user] [database]            Connect to PostgreSQL as specified user
  get-uid <tenant> <app>               Get UID for a tenant/app (creates if not exists)

Install Options:
  --name NAME                          Container/service name (default: $DEFAULT_CONTAINER_NAME)
  --version VERSION                    PostgreSQL version (default: $DEFAULT_POSTGRES_VERSION)
  --data-dir PATH                      Data directory path (default: $DEFAULT_DATA_DIR)
  --socket-volume NAME                 Socket volume name (default: $DEFAULT_SOCKET_VOLUME)
  --tenant TENANT                      Tenant name (creates if not exists)
  --app APP                            App name (creates user if not exists)
  --uid UID                            Explicit UID to use (skip tenant/app creation)
  --gid GID                            Explicit GID to use (skip tenant/app creation)
  --superuser-password PASS            PostgreSQL superuser password (optional, for remote access)

Examples:
  # Install with default settings (runs as default postgres user)
  $(basename "$0") install

  # Install with tenant/app - CREATES the user if not exists (RECOMMENDED)
  # This creates: tenant group 'xdoc', user 'xdoc_api' with UID 100001+
  $(basename "$0") install --tenant xdoc --app api

  # Install with explicit UID/GID (no user creation)
  $(basename "$0") install --uid 100001 --gid 1001

  # Install with custom name and data directory
  $(basename "$0") install --name my-postgres --data-dir /data/postgres

  # Get the UID for later use with provision-tenant-app.sh
  $(basename "$0") get-uid xdoc api

  # Uninstall
  $(basename "$0") uninstall --name my-postgres

  # Connect as a specific user
  $(basename "$0") connect xdoc xdoc

Recommended Workflow (Database First):
  1. Install PostgreSQL with tenant/app (creates the user):
     ./install_postgres_quadlet.sh install --tenant xdoc --app api
     
  2. Note the UID created (e.g., 100001)
  
  3. Create database for the app:
     ./pg_deploy_with_update.sh -c pg-root-peer /backup /repo ~/.ssh/key xdoc xdoc 100001

  4. Later, provision the API app with the SAME UID:
     # The user xdoc_api already exists, so provision-tenant-app.sh will reuse it
     ./provision-tenant-app.sh provision xdoc api docker.io/myapp:latest "3000:3000" \\
         "" "" "pg-run-volume:/var/run/postgresql:rw"

  Both containers now share the same UID for peer authentication!

EOF
}

#-------------------------------------------------------------------------------
# Create PostgreSQL Quadlet
#-------------------------------------------------------------------------------
create_postgres_quadlet() {
    local container_name="$1"
    local pg_version="$2"
    local data_dir="$3"
    local socket_volume="$4"
    local run_uid="${5:-}"
    local run_gid="${6:-}"
    local superuser_password="${7:-}"
    
    local quadlet_file="${QUADLET_DIR}/${container_name}.container"
    local image="docker.io/postgres:${pg_version}"
    
    log_step "Creating PostgreSQL Quadlet: $container_name"
    
    # Ensure directories exist
    mkdir -p "$QUADLET_DIR"
    mkdir -p "$data_dir"
    
    # Set ownership if UID/GID provided
    if [[ -n "$run_uid" && -n "$run_gid" ]]; then
        chown "$run_uid:$run_gid" "$data_dir"
        log_info "Data directory owned by UID:GID = $run_uid:$run_gid"
    fi
    chmod 700 "$data_dir"
    
    # Create the socket volume if it doesn't exist
    if ! podman volume exists "$socket_volume" 2>/dev/null; then
        podman volume create "$socket_volume"
        log_info "Created socket volume: $socket_volume"
    fi
    
    # Build environment lines
    local env_lines=""
    if [[ -n "$superuser_password" ]]; then
        env_lines+="Environment=POSTGRES_PASSWORD=${superuser_password}\n"
    else
        # Allow passwordless local connections (trust for local, peer for socket)
        env_lines+="Environment=POSTGRES_HOST_AUTH_METHOD=trust\n"
    fi
    
    # Build user/group lines for Quadlet
    local user_lines=""
    if [[ -n "$run_uid" && -n "$run_gid" ]]; then
        user_lines="User=${run_uid}
Group=${run_gid}

# User namespace mapping for UID/GID
UserNS=keep-id:uid=${run_uid},gid=${run_gid}"
    fi
    
    # Create the Quadlet .container file
    cat > "$quadlet_file" << EOF
# PostgreSQL Quadlet Container
# Container: ${container_name}
# Generated: $(date -Iseconds)
#
# This file creates a PostgreSQL container managed by systemd via Podman Quadlet
# Socket is shared via volume: ${socket_volume}

[Unit]
Description=PostgreSQL Database Server (Quadlet)
Documentation=https://www.postgresql.org/docs/
After=network-online.target local-fs.target
Wants=network-online.target

[Container]
# Container image and name
Image=${image}
ContainerName=${container_name}

${user_lines}

# Environment variables
Environment=POSTGRES_USER=postgres
Environment=PGDATA=/var/lib/postgresql/data/pgdata
$(echo -e "$env_lines")

# Volume mounts
# Data directory - persistent storage
Volume=${data_dir}:/var/lib/postgresql/data:rw,Z

# Socket volume - shared with other containers for peer authentication
Volume=${socket_volume}:/var/run/postgresql:rw

# Port mapping (optional - for remote connections)
# Uncomment if you need TCP access
# PublishPort=5432:5432

# Security options
NoNewPrivileges=true

# Healthcheck
HealthCmd=pg_isready -h /var/run/postgresql -U postgres
HealthInterval=30s
HealthTimeout=10s
HealthRetries=5
HealthStartPeriod=30s

# Resource limits (adjust as needed)
PodmanArgs=--memory=1g --cpus=2

# Labels
Label=service=postgresql
Label=managed-by=install_postgres_quadlet

[Service]
# Restart policy
Restart=always
RestartSec=10
TimeoutStartSec=300
TimeoutStopSec=60

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${container_name}

[Install]
WantedBy=multi-user.target default.target
EOF
    
    chmod 644 "$quadlet_file"
    log_info "Created Quadlet file: $quadlet_file"
    
    # Reload systemd
    systemctl daemon-reload
    log_info "Systemd daemon reloaded"
    
    return 0
}

#-------------------------------------------------------------------------------
# Create pg_hba.conf for peer authentication
#-------------------------------------------------------------------------------
create_pg_hba_config() {
    local data_dir="$1"
    local pg_hba_file="${data_dir}/pgdata/pg_hba.conf"
    
    # Wait for PostgreSQL to initialize and create the data directory
    log_info "Waiting for PostgreSQL to initialize..."
    local max_wait=60
    local waited=0
    
    while [[ ! -f "$pg_hba_file" && $waited -lt $max_wait ]]; do
        sleep 2
        ((waited+=2))
    done
    
    if [[ ! -f "$pg_hba_file" ]]; then
        log_warn "pg_hba.conf not found after ${max_wait}s. Manual configuration may be needed."
        return 1
    fi
    
    log_info "Configuring pg_hba.conf for peer authentication..."
    
    # Backup original
    cp "$pg_hba_file" "${pg_hba_file}.backup"
    
    # Create new pg_hba.conf with peer authentication
    cat > "$pg_hba_file" << 'EOF'
# PostgreSQL Client Authentication Configuration File
# ===================================================
#
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections via Unix socket - peer authentication
# This allows OS users to connect as matching PostgreSQL users
local   all             all                                     peer

# IPv4 local connections (loopback only)
host    all             all             127.0.0.1/32            scram-sha-256

# IPv6 local connections (loopback only)  
host    all             all             ::1/128                 scram-sha-256

# Container network connections (for linked containers)
host    all             all             10.0.0.0/8              scram-sha-256
host    all             all             172.16.0.0/12           scram-sha-256
host    all             all             192.168.0.0/16          scram-sha-256

# Replication connections (if needed)
# local   replication     all                                     peer
# host    replication     all             127.0.0.1/32            scram-sha-256
EOF
    
    log_info "pg_hba.conf configured for peer authentication"
    return 0
}

#-------------------------------------------------------------------------------
# Install Command
#-------------------------------------------------------------------------------
cmd_install() {
    local container_name="$DEFAULT_CONTAINER_NAME"
    local pg_version="$DEFAULT_POSTGRES_VERSION"
    local data_dir="$DEFAULT_DATA_DIR"
    local socket_volume="$DEFAULT_SOCKET_VOLUME"
    local tenant=""
    local app=""
    local run_uid=""
    local run_gid=""
    local superuser_password=""
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                container_name="$2"
                shift 2
                ;;
            --version)
                pg_version="$2"
                shift 2
                ;;
            --data-dir)
                data_dir="$2"
                shift 2
                ;;
            --socket-volume)
                socket_volume="$2"
                shift 2
                ;;
            --tenant)
                tenant="$2"
                shift 2
                ;;
            --app)
                app="$2"
                shift 2
                ;;
            --uid)
                run_uid="$2"
                shift 2
                ;;
            --gid)
                run_gid="$2"
                shift 2
                ;;
            --superuser-password)
                superuser_password="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Get or create UID/GID from tenant/app if specified
    if [[ -n "$tenant" && -n "$app" ]]; then
        log_info "Setting up tenant '$tenant' and app '$app'..."
        
        # This will CREATE the tenant and user if they don't exist
        run_uid=$(get_or_create_app_uid "$tenant" "$app") || exit 1
        run_gid=$(get_or_create_app_gid "$tenant" "$app") || exit 1
        
        # Also create the app directories
        create_app_directories "$tenant" "$app"
        
        log_info "Using UID:GID = $run_uid:$run_gid for ${tenant}_${app}"
    elif [[ -n "$tenant" || -n "$app" ]]; then
        log_error "Both --tenant and --app must be specified together"
        exit 1
    fi
    
    log_info "========================================"
    log_info "Installing PostgreSQL Quadlet"
    log_info "========================================"
    log_info "Container Name: $container_name"
    log_info "PostgreSQL Version: $pg_version"
    log_info "Data Directory: $data_dir"
    log_info "Socket Volume: $socket_volume"
    if [[ -n "$run_uid" ]]; then
        log_info "Run as UID:GID: $run_uid:$run_gid"
    else
        log_info "Run as: default postgres user"
    fi
    log_info "========================================"
    
    # Check for existing installation
    if [[ -f "${QUADLET_DIR}/${container_name}.container" ]]; then
        log_warn "Quadlet file already exists: ${QUADLET_DIR}/${container_name}.container"
        read -p "Overwrite? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled."
            exit 0
        fi
    fi
    
    # Pull the image first
    log_step "[1/4] Pulling PostgreSQL image..."
    local image="docker.io/postgres:${pg_version}"
    if ! podman pull "$image"; then
        log_error "Failed to pull image: $image"
        exit 1
    fi
    
    # Create the Quadlet
    log_step "[2/4] Creating Quadlet configuration..."
    create_postgres_quadlet "$container_name" "$pg_version" "$data_dir" "$socket_volume" \
        "$run_uid" "$run_gid" "$superuser_password"
    
    # Start the service
    log_step "[3/4] Starting PostgreSQL service..."
    if ! systemctl start "${container_name}.service"; then
        log_error "Failed to start service. Check logs with: journalctl -u ${container_name}.service"
        exit 1
    fi
    
    # Wait for PostgreSQL to be ready
    log_step "[4/4] Waiting for PostgreSQL to be ready..."
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if podman exec "$container_name" pg_isready -h /var/run/postgresql -U postgres >/dev/null 2>&1; then
            log_info "PostgreSQL is ready!"
            break
        fi
        log_info "Waiting for PostgreSQL... (attempt $attempt/$max_attempts)"
        sleep 2
        ((attempt++))
    done
    
    if [[ $attempt -gt $max_attempts ]]; then
        log_error "PostgreSQL failed to become ready within timeout."
        exit 1
    fi
    
    # Configure pg_hba.conf after initialization
    create_pg_hba_config "$data_dir"
    
    # Reload PostgreSQL to apply pg_hba.conf changes
    log_info "Reloading PostgreSQL configuration..."
    podman exec "$container_name" pg_ctl reload -D /var/lib/postgresql/data/pgdata 2>/dev/null || true
    
    log_info "========================================"
    log_info "PostgreSQL Installation Complete!"
    log_info "========================================"
    log_info ""
    log_info "Service: ${container_name}.service"
    log_info "Quadlet: ${QUADLET_DIR}/${container_name}.container"
    log_info "Data: $data_dir"
    log_info "Socket Volume: $socket_volume"
    log_info ""
    log_info "Useful commands:"
    log_info "  Status:  systemctl status ${container_name}.service"
    log_info "  Logs:    journalctl -u ${container_name}.service -f"
    log_info "  Connect: podman exec -it $container_name psql -h /var/run/postgresql -U postgres"
    log_info "  Restart: systemctl restart ${container_name}.service"
    log_info ""
    log_info "To create a database for your app, use pg_deploy_with_update.sh:"
    log_info "  ./pg_deploy_with_update.sh -c $container_name /backup /repo ~/.ssh/id_rsa mydb myuser"
    
    return 0
}

#-------------------------------------------------------------------------------
# Uninstall Command
#-------------------------------------------------------------------------------
cmd_uninstall() {
    local container_name="$DEFAULT_CONTAINER_NAME"
    local remove_data=false
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                container_name="$2"
                shift 2
                ;;
            --remove-data)
                remove_data=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    log_info "Uninstalling PostgreSQL Quadlet: $container_name"
    
    # Stop the service
    if systemctl is-active --quiet "${container_name}.service" 2>/dev/null; then
        log_info "Stopping service..."
        systemctl stop "${container_name}.service"
    fi
    
    # Remove the Quadlet file
    local quadlet_file="${QUADLET_DIR}/${container_name}.container"
    if [[ -f "$quadlet_file" ]]; then
        rm -f "$quadlet_file"
        log_info "Removed Quadlet file: $quadlet_file"
    fi
    
    # Reload systemd
    systemctl daemon-reload
    
    # Remove the container if it still exists
    if podman container exists "$container_name" 2>/dev/null; then
        podman rm -f "$container_name" 2>/dev/null || true
        log_info "Removed container: $container_name"
    fi
    
    if [[ "$remove_data" == "true" ]]; then
        log_warn "Data removal requested but data directory path not tracked."
        log_warn "Please manually remove the data directory if needed."
    fi
    
    log_info "PostgreSQL Quadlet uninstalled successfully."
}

#-------------------------------------------------------------------------------
# Status Command
#-------------------------------------------------------------------------------
cmd_status() {
    local container_name="$DEFAULT_CONTAINER_NAME"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)
                container_name="$2"
                shift 2
                ;;
            *)
                container_name="$1"
                shift
                ;;
        esac
    done
    
    log_info "PostgreSQL Status: $container_name"
    echo ""
    
    # Service status
    systemctl status "${container_name}.service" --no-pager || true
    
    echo ""
    
    # Container status
    if podman container exists "$container_name" 2>/dev/null; then
        log_info "Container Info:"
        podman inspect "$container_name" --format '  State: {{.State.Status}}
  Running: {{.State.Running}}
  Started: {{.State.StartedAt}}
  Health: {{.State.Health.Status}}'
    fi
}

#-------------------------------------------------------------------------------
# Connect Command
#-------------------------------------------------------------------------------
cmd_connect() {
    local container_name="$DEFAULT_CONTAINER_NAME"
    local db_user="${1:-postgres}"
    local db_name="${2:-postgres}"
    
    log_info "Connecting to PostgreSQL as user '$db_user' to database '$db_name'..."
    
    # If connecting as a non-postgres user, we need to use that user in the container
    if [[ "$db_user" == "postgres" ]]; then
        podman exec -it "$container_name" psql -h /var/run/postgresql -U "$db_user" -d "$db_name"
    else
        # For peer authentication, we need an OS user matching the DB user
        podman exec -it --user "$db_user" "$container_name" psql -h /var/run/postgresql -d "$db_name"
    fi
}

#-------------------------------------------------------------------------------
# Get-UID Command - Get or create UID for tenant/app
#-------------------------------------------------------------------------------
cmd_get_uid() {
    local tenant="${1:-}"
    local app="${2:-}"
    
    if [[ -z "$tenant" || -z "$app" ]]; then
        log_error "Usage: $(basename "$0") get-uid <tenant> <app>"
        exit 1
    fi
    
    log_info "Getting/creating UID for tenant '$tenant', app '$app'..."
    
    local uid gid
    uid=$(get_or_create_app_uid "$tenant" "$app") || exit 1
    gid=$(get_or_create_app_gid "$tenant" "$app") || exit 1
    
    # Create directories too
    create_app_directories "$tenant" "$app"
    
    log_info "========================================"
    log_info "Tenant/App User Ready"
    log_info "========================================"
    echo "Tenant:    $tenant"
    echo "App:       $app"
    echo "User:      ${tenant}_${app}"
    echo "UID:       $uid"
    echo "GID:       $gid"
    echo "App Dir:   ${BASE_DIR}/${tenant}/${app}/"
    log_info "========================================"
    log_info ""
    log_info "Use this UID with pg_deploy_with_update.sh:"
    log_info "  ./pg_deploy_with_update.sh -c pg-root-peer /backup /repo ~/.ssh/key $app $app $uid"
    log_info ""
    log_info "Later provision the API with provision-tenant-app.sh:"
    log_info "  ./provision-tenant-app.sh provision $tenant $app docker.io/myimage:latest \"3000:3000\""
    log_info "  (The user ${tenant}_${app} already exists, so it will be reused)"
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    check_root
    check_podman
    
    local command="${1:-}"
    shift || true
    
    case "$command" in
        install)
            cmd_install "$@"
            ;;
        uninstall)
            cmd_uninstall "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        connect)
            cmd_connect "$@"
            ;;
        get-uid)
            cmd_get_uid "$@"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            if [[ -z "$command" ]]; then
                usage
            else
                log_error "Unknown command: $command"
                usage
                exit 1
            fi
            ;;
    esac
}

main "$@"

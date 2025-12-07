#!/bin/bash
#===============================================================================
# Multi-Tenant Application Provisioning Script
# 
# This script provisions tenant applications with:
# - Tenant as OS group (groupId)
# - App as OS user (userId) belonging to tenant group
# - POSIX-compliant folder structure in /srv
# - systemd service for each app (script-based or container-based)
# - Podman Quadlet support for container apps with proper UID/GID mapping
#
# Author: System Architect
# Version: 2.0.0
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Configuration
#-------------------------------------------------------------------------------
readonly BASE_DIR="/srv"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly QUADLET_DIR="/etc/containers/systemd"
readonly APP_SCRIPTS_DIR="/opt/apps"
readonly LOG_DIR="/var/log/tenant-apps"
readonly CONTAINER_SECRETS_DIR="/etc/tenant-secrets"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

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

#-------------------------------------------------------------------------------
# Validation Functions
#-------------------------------------------------------------------------------
validate_name() {
    local name="$1"
    local type="$2"
    
    # POSIX compliant naming: lowercase, alphanumeric, underscore, hyphen
    # Must start with letter, max 32 characters
    if [[ ! "$name" =~ ^[a-z][a-z0-9_]{0,31}$ ]]; then
        log_error "Invalid $type name: '$name'. Must be lowercase, start with letter, max 32 chars, only alphanumeric, underscore allowed."
        return 1
    fi
    return 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_podman() {
    if ! command -v podman &> /dev/null; then
        log_error "Podman is not installed. Please install podman first."
        return 1
    fi
    return 0
}

get_user_ids() {
    local username="$1"
    local uid gid
    uid=$(id -u "$username" 2>/dev/null) || return 1
    gid=$(id -g "$username" 2>/dev/null) || return 1
    echo "$uid:$gid"
}

#-------------------------------------------------------------------------------
# Tenant (Group) Management
#-------------------------------------------------------------------------------
create_tenant() {
    local tenant_name="$1"
    
    validate_name "$tenant_name" "tenant" || return 1
    
    # Check if group already exists
    if getent group "$tenant_name" > /dev/null 2>&1; then
        log_warn "Tenant group '$tenant_name' already exists"
        return 0
    fi
    
    # Create tenant group
    groupadd "$tenant_name"
    log_info "Created tenant group: $tenant_name"
    
    # Create tenant base directory
    local tenant_dir="${BASE_DIR}/${tenant_name}"
    mkdir -p "$tenant_dir"
    chown root:"$tenant_name" "$tenant_dir"
    chmod 2750 "$tenant_dir"  # SGID bit for group inheritance
    
    log_info "Created tenant directory: $tenant_dir"
    return 0
}

delete_tenant() {
    local tenant_name="$1"
    
    # Check if group exists
    if ! getent group "$tenant_name" > /dev/null 2>&1; then
        log_error "Tenant group '$tenant_name' does not exist"
        return 1
    fi
    
    # Check for existing apps (users) in this tenant
    local users
    users=$(getent group "$tenant_name" | cut -d: -f4)
    if [[ -n "$users" ]]; then
        log_error "Cannot delete tenant '$tenant_name': Apps still exist: $users"
        return 1
    fi
    
    # Remove tenant directory
    local tenant_dir="${BASE_DIR}/${tenant_name}"
    if [[ -d "$tenant_dir" ]]; then
        rm -rf "$tenant_dir"
        log_info "Removed tenant directory: $tenant_dir"
    fi
    
    # Remove tenant group
    groupdel "$tenant_name"
    log_info "Deleted tenant group: $tenant_name"
    
    return 0
}

#-------------------------------------------------------------------------------
# App (User) Management
#-------------------------------------------------------------------------------
create_app_directories() {
    local tenant_name="$1"
    local app_name="$2"
    local is_container="${3:-false}"
    local app_user="${tenant_name}_${app_name}"
    local app_dir="${BASE_DIR}/${tenant_name}/${app_name}"
    
    # Create app directories with proper permissions
    # Directory structure:
    # /srv/<tenant>/<app>/
    # ├── read/    (r-x for app, r-x for tenant group)
    # ├── write/   (rwx for app, --- for others)
    # ├── exec/    (r-x for app, executable scripts)
    # ├── shared/  (rwx for app, r-x for tenant group)
    # └── data/    (rwx for app, container persistent data) [container apps only]
    
    mkdir -p "$app_dir"/{read,write,exec,shared}
    
    # Additional directories for container apps
    if [[ "$is_container" == "true" ]]; then
        mkdir -p "$app_dir"/{data,config,logs,secrets}
    fi
    
    # Set ownership: app user owns, tenant group has group access
    chown -R "$app_user":"$tenant_name" "$app_dir"
    
    # App base directory: app can access, tenant group can read
    chmod 2750 "$app_dir"
    
    # read/ - Read-only for app and tenant group
    chmod 2550 "$app_dir/read"
    
    # write/ - Read/write for app only, no access for others
    chmod 2700 "$app_dir/write"
    
    # exec/ - Executable scripts, read-execute for app
    chmod 2550 "$app_dir/exec"
    
    # shared/ - Read/write for app, read for tenant group
    chmod 2750 "$app_dir/shared"
    
    log_info "Created app directories with POSIX permissions:"
    log_info "  $app_dir/read   (550) - Read-only"
    log_info "  $app_dir/write  (700) - App private write"
    log_info "  $app_dir/exec   (550) - Executable scripts"
    log_info "  $app_dir/shared (750) - Shared with tenant"
    
    # Container-specific directories
    if [[ "$is_container" == "true" ]]; then
        chmod 2700 "$app_dir/data"     # Container persistent data
        chmod 2500 "$app_dir/config"   # Read-only config for container
        chmod 2700 "$app_dir/logs"     # Container logs
        chmod 2500 "$app_dir/secrets"  # Secrets (read-only)
        
        log_info "  $app_dir/data    (700) - Container persistent data"
        log_info "  $app_dir/config  (500) - Container config (read-only)"
        log_info "  $app_dir/logs    (700) - Container logs"
        log_info "  $app_dir/secrets (500) - Container secrets (read-only)"
    fi
}

create_app_script() {
    local tenant_name="$1"
    local app_name="$2"
    local app_logic="$3"
    local app_user="${tenant_name}_${app_name}"
    local script_path="${APP_SCRIPTS_DIR}/${tenant_name}/${app_name}.sh"
    
    # Create script directory
    mkdir -p "$(dirname "$script_path")"
    
    # Create the app script with the provided logic
    cat > "$script_path" << EOF
#!/bin/bash
#===============================================================================
# App: ${app_name}
# Tenant: ${tenant_name}
# User: ${app_user}
# Generated: $(date -Iseconds)
#===============================================================================

set -euo pipefail

# App directories
readonly APP_DIR="${BASE_DIR}/${tenant_name}/${app_name}"
readonly READ_DIR="\${APP_DIR}/read"
readonly WRITE_DIR="\${APP_DIR}/write"
readonly EXEC_DIR="\${APP_DIR}/exec"
readonly SHARED_DIR="\${APP_DIR}/shared"
readonly LOG_FILE="${LOG_DIR}/${tenant_name}/${app_name}.log"

# Ensure log directory exists
mkdir -p "\$(dirname "\$LOG_FILE")"

log() {
    echo "[\$(date -Iseconds)] \$1" >> "\$LOG_FILE"
}

log "Starting app: ${app_name}"

#-------------------------------------------------------------------------------
# App Logic (User Provided)
#-------------------------------------------------------------------------------
${app_logic}

#-------------------------------------------------------------------------------
# End of App Logic
#-------------------------------------------------------------------------------

log "App ${app_name} execution completed"
EOF
    
    # Set ownership and permissions
    chown "$app_user":"$tenant_name" "$script_path"
    chmod 550 "$script_path"
    
    log_info "Created app script: $script_path"
}

create_systemd_service() {
    local tenant_name="$1"
    local app_name="$2"
    local service_type="${3:-simple}"  # simple, oneshot, forking
    local restart_policy="${4:-on-failure}"
    local app_user="${tenant_name}_${app_name}"
    local service_name="${tenant_name}-${app_name}"
    local service_file="${SYSTEMD_DIR}/${service_name}.service"
    local script_path="${APP_SCRIPTS_DIR}/${tenant_name}/${app_name}.sh"
    
    cat > "$service_file" << EOF
[Unit]
Description=Tenant App: ${app_name} (Tenant: ${tenant_name})
Documentation=man:systemd.service(5)
After=network.target
Wants=network.target

[Service]
Type=${service_type}
User=${app_user}
Group=${tenant_name}
WorkingDirectory=${BASE_DIR}/${tenant_name}/${app_name}
ExecStart=${script_path}

# Security hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
MemoryDenyWriteExecute=yes

# Allow write access to specific directories
ReadWritePaths=${BASE_DIR}/${tenant_name}/${app_name}/write
ReadWritePaths=${BASE_DIR}/${tenant_name}/${app_name}/shared
ReadWritePaths=${LOG_DIR}/${tenant_name}

# Read-only access
ReadOnlyPaths=${BASE_DIR}/${tenant_name}/${app_name}/read
ReadOnlyPaths=${BASE_DIR}/${tenant_name}/${app_name}/exec

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096

# Restart policy
Restart=${restart_policy}
RestartSec=5

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${service_name}

[Install]
WantedBy=multi-user.target
EOF
    
    # Set permissions
    chmod 644 "$service_file"
    
    # Reload systemd
    systemctl daemon-reload
    
    log_info "Created systemd service: ${service_name}.service"
}

#-------------------------------------------------------------------------------
# Podman Quadlet (Container) Management
#-------------------------------------------------------------------------------
create_quadlet_container() {
    local tenant_name="$1"
    local app_name="$2"
    local image="$3"
    local port_mappings="${4:-}"       # e.g., "8080:80,8443:443"
    local env_vars="${5:-}"            # e.g., "KEY1=val1,KEY2=val2"
    local extra_args="${6:-}"          # Additional podman args
    
    local app_user="${tenant_name}_${app_name}"
    local service_name="${tenant_name}-${app_name}"
    local app_dir="${BASE_DIR}/${tenant_name}/${app_name}"
    local quadlet_file="${QUADLET_DIR}/${service_name}.container"
    
    # Ensure quadlet directory exists
    mkdir -p "$QUADLET_DIR"
    
    # Get UID/GID for the app user
    local user_ids
    user_ids=$(get_user_ids "$app_user") || {
        log_error "Failed to get UID/GID for user: $app_user"
        return 1
    }
    local uid="${user_ids%:*}"
    local gid="${user_ids#*:}"
    
    log_info "Creating Quadlet container with UID:GID = $uid:$gid"
    
    # Build port mapping lines
    local publish_lines=""
    if [[ -n "$port_mappings" ]]; then
        IFS=',' read -ra PORTS <<< "$port_mappings"
        for port in "${PORTS[@]}"; do
            publish_lines+="PublishPort=${port}\n"
        done
    fi
    
    # Build environment variable lines
    local env_lines=""
    if [[ -n "$env_vars" ]]; then
        IFS=',' read -ra ENVS <<< "$env_vars"
        for env in "${ENVS[@]}"; do
            env_lines+="Environment=${env}\n"
        done
    fi
    
    # Create the Quadlet .container file
    cat > "$quadlet_file" << EOF
# Quadlet Container: ${app_name}
# Tenant: ${tenant_name}
# Generated: $(date -Iseconds)
#
# This file is managed by provision-tenant-app.sh
# Systemd will generate: ${service_name}.service

[Unit]
Description=Container App: ${app_name} (Tenant: ${tenant_name})
Documentation=man:podman-systemd.unit(5)
After=network-online.target local-fs.target
Wants=network-online.target

[Container]
# Container image
Image=${image}
ContainerName=${service_name}

# Run as the app user (UID:GID mapping)
User=${uid}
Group=${gid}

# User namespace mapping for rootless-like security
# Maps container user to host app user
UserNS=keep-id:uid=${uid},gid=${gid}

# Volume mounts with proper permissions
# Read-only mounts
Volume=${app_dir}/read:/app/read:ro,Z
Volume=${app_dir}/exec:/app/exec:ro,Z
Volume=${app_dir}/config:/app/config:ro,Z
Volume=${app_dir}/secrets:/run/secrets:ro,Z

# Read-write mounts
Volume=${app_dir}/write:/app/write:rw,Z
Volume=${app_dir}/shared:/app/shared:rw,Z
Volume=${app_dir}/data:/app/data:rw,Z
Volume=${app_dir}/logs:/app/logs:rw,Z

# Environment variables
Environment=APP_NAME=${app_name}
Environment=TENANT_NAME=${tenant_name}
Environment=APP_USER=${app_user}
$(echo -e "$env_lines")

# Port mappings
$(echo -e "$publish_lines")

# Security options
SecurityLabelType=container_runtime_t
NoNewPrivileges=true
ReadOnly=true
ReadWriteTmpfs=true

# Healthcheck (optional - override in app-specific config)
# HealthCmd=/bin/healthcheck.sh
# HealthInterval=30s
# HealthTimeout=10s
# HealthRetries=3

# Resource limits
PodmanArgs=--memory=512m --cpus=1 ${extra_args}

# Labels for management
Label=tenant=${tenant_name}
Label=app=${app_name}
Label=managed-by=provision-tenant-app

[Service]
# Restart policy
Restart=on-failure
RestartSec=10
TimeoutStartSec=300
TimeoutStopSec=30

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${service_name}

[Install]
WantedBy=multi-user.target default.target
EOF
    
    chmod 644 "$quadlet_file"
    
    log_info "Created Quadlet container file: $quadlet_file"
    
    # Reload systemd to generate the service
    systemctl daemon-reload
    
    log_info "Quadlet container '${service_name}' ready. Service: ${service_name}.service"
    return 0
}

create_quadlet_kube() {
    local tenant_name="$1"
    local app_name="$2"
    local kube_yaml="$3"  # Path to Kubernetes YAML file
    
    local app_user="${tenant_name}_${app_name}"
    local service_name="${tenant_name}-${app_name}"
    local app_dir="${BASE_DIR}/${tenant_name}/${app_name}"
    local quadlet_file="${QUADLET_DIR}/${service_name}.kube"
    local kube_dest="${app_dir}/config/${app_name}.yaml"
    
    # Ensure quadlet directory exists
    mkdir -p "$QUADLET_DIR"
    
    # Get UID/GID for the app user
    local user_ids
    user_ids=$(get_user_ids "$app_user") || {
        log_error "Failed to get UID/GID for user: $app_user"
        return 1
    }
    local uid="${user_ids%:*}"
    local gid="${user_ids#*:}"
    
    # Copy Kubernetes YAML to app config directory
    if [[ -f "$kube_yaml" ]]; then
        cp "$kube_yaml" "$kube_dest"
        chown "$app_user":"$tenant_name" "$kube_dest"
        chmod 440 "$kube_dest"
        log_info "Copied Kubernetes YAML to: $kube_dest"
    else
        log_error "Kubernetes YAML file not found: $kube_yaml"
        return 1
    fi
    
    # Create the Quadlet .kube file
    cat > "$quadlet_file" << EOF
# Quadlet Kube: ${app_name}
# Tenant: ${tenant_name}
# Generated: $(date -Iseconds)
#
# This file is managed by provision-tenant-app.sh
# Systemd will generate: ${service_name}.service

[Unit]
Description=Kube App: ${app_name} (Tenant: ${tenant_name})
Documentation=man:podman-systemd.unit(5)
After=network-online.target local-fs.target
Wants=network-online.target

[Kube]
# Kubernetes YAML file
Yaml=${kube_dest}

# User namespace mapping
UserNS=keep-id:uid=${uid},gid=${gid}

# Config maps from directories
ConfigMap=${app_dir}/config

# Publish all exposed ports
PublishPort=

[Service]
Restart=on-failure
RestartSec=10
TimeoutStartSec=900
TimeoutStopSec=60

StandardOutput=journal
StandardError=journal
SyslogIdentifier=${service_name}

[Install]
WantedBy=multi-user.target default.target
EOF
    
    chmod 644 "$quadlet_file"
    
    log_info "Created Quadlet kube file: $quadlet_file"
    
    # Reload systemd to generate the service
    systemctl daemon-reload
    
    log_info "Quadlet kube '${service_name}' ready. Service: ${service_name}.service"
    return 0
}

create_container_app() {
    local tenant_name="$1"
    local app_name="$2"
    local image="$3"
    local port_mappings="${4:-}"
    local env_vars="${5:-}"
    local extra_args="${6:-}"
    
    validate_name "$tenant_name" "tenant" || return 1
    validate_name "$app_name" "app" || return 1
    check_podman || return 1
    
    # Ensure tenant exists
    if ! getent group "$tenant_name" > /dev/null 2>&1; then
        log_info "Tenant '$tenant_name' does not exist, creating..."
        create_tenant "$tenant_name" || return 1
    fi
    
    local app_user="${tenant_name}_${app_name}"
    
    # Check if app user already exists
    if id "$app_user" > /dev/null 2>&1; then
        local existing_uid=$(id -u "$app_user")
        log_info "App user '$app_user' already exists (UID: $existing_uid) - reusing for container"
    else
        # Create app user with specific UID for container mapping
        # Use a high UID range to avoid conflicts (100000+)
        local next_uid
        next_uid=$(awk -F: 'BEGIN{max=100000} $3>=100000 && $3>max {max=$3} END{print max+1}' /etc/passwd)
        
        if ! useradd \
            --system \
            --uid "$next_uid" \
            --gid "$tenant_name" \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --comment "Container_App_${app_name}_Tenant_${tenant_name}" \
            "$app_user"; then
            log_error "Failed to create user: $app_user"
            return 1
        fi
        
        log_info "Created container app user: $app_user (UID: $next_uid, member of group: $tenant_name)"
    fi
    
    # Create log directory
    mkdir -p "${LOG_DIR}/${tenant_name}"
    chown root:"$tenant_name" "${LOG_DIR}/${tenant_name}"
    chmod 2770 "${LOG_DIR}/${tenant_name}"
    
    # Create directories (with container flag)
    create_app_directories "$tenant_name" "$app_name" "true"
    
    # Create Quadlet container
    create_quadlet_container "$tenant_name" "$app_name" "$image" "$port_mappings" "$env_vars" "$extra_args"
    
    log_info "Container app '$app_name' for tenant '$tenant_name' provisioned successfully"
    log_info "To start: systemctl start ${tenant_name}-${app_name}.service"
    return 0
}

delete_container_app() {
    local tenant_name="$1"
    local app_name="$2"
    local app_user="${tenant_name}_${app_name}"
    local service_name="${tenant_name}-${app_name}"
    
    # Stop and disable service
    if systemctl is-active --quiet "${service_name}.service" 2>/dev/null; then
        systemctl stop "${service_name}.service"
        log_info "Stopped container service: ${service_name}"
    fi
    
    if systemctl is-enabled --quiet "${service_name}.service" 2>/dev/null; then
        systemctl disable "${service_name}.service"
        log_info "Disabled container service: ${service_name}"
    fi
    
    # Remove Quadlet files
    local quadlet_container="${QUADLET_DIR}/${service_name}.container"
    local quadlet_kube="${QUADLET_DIR}/${service_name}.kube"
    
    for quadlet_file in "$quadlet_container" "$quadlet_kube"; do
        if [[ -f "$quadlet_file" ]]; then
            rm -f "$quadlet_file"
            log_info "Removed Quadlet file: $quadlet_file"
        fi
    done
    
    systemctl daemon-reload
    
    # Remove container if still exists
    if podman container exists "${service_name}" 2>/dev/null; then
        podman rm -f "${service_name}" 2>/dev/null || true
        log_info "Removed container: ${service_name}"
    fi
    
    # Remove app directories
    local app_dir="${BASE_DIR}/${tenant_name}/${app_name}"
    if [[ -d "$app_dir" ]]; then
        rm -rf "$app_dir"
        log_info "Removed app directory: $app_dir"
    fi
    
    # Remove app user
    if id "$app_user" > /dev/null 2>&1; then
        userdel "$app_user"
        log_info "Deleted app user: $app_user"
    fi
    
    log_info "Container app '$app_name' for tenant '$tenant_name' removed successfully"
    return 0
}

pull_image() {
    local image="$1"
    log_info "Pulling container image: $image"
    podman pull "$image"
}

list_container_apps() {
    local tenant_name="$1"
    
    log_info "Container apps for tenant '$tenant_name':"
    podman ps -a --filter "label=tenant=${tenant_name}" \
        --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
}

#-------------------------------------------------------------------------------
# Provision Command - All-in-One Deployment
#-------------------------------------------------------------------------------
provision_container() {
    local tenant_name="$1"
    local app_name="$2"
    local image="$3"
    local port_mappings="${4:-}"
    local env_vars="${5:-}"
    local extra_args="${6:-}"
    local volumes="${7:-}"          # Additional volumes: "src:dest,src2:dest2"
    local no_start="${8:-false}"    # If true, don't start the service
    
    local service_name="${tenant_name}-${app_name}"
    
    log_info "========================================"
    log_info "Provisioning container app: ${app_name}"
    log_info "Tenant: ${tenant_name}"
    log_info "Image: ${image}"
    log_info "========================================"
    
    # Step 1: Pull the image first
    log_info "[1/4] Pulling container image..."
    if ! podman pull "$image"; then
        log_error "Failed to pull image: $image"
        return 1
    fi
    
    # Step 2: Create container app (includes tenant creation if needed)
    log_info "[2/4] Creating container app..."
    if ! create_container_app "$tenant_name" "$app_name" "$image" "$port_mappings" "$env_vars" "$extra_args"; then
        log_error "Failed to create container app"
        return 1
    fi
    
    # Step 3: Add custom volumes if specified
    if [[ -n "$volumes" ]]; then
        log_info "[3/4] Adding custom volumes..."
        local quadlet_file="${QUADLET_DIR}/${service_name}.container"
        local temp_file=$(mktemp)
        
        # Read file and insert volumes before [Service] section
        while IFS= read -r line; do
            if [[ "$line" == "[Service]" ]]; then
                # Insert volume lines before [Service]
                IFS=',' read -ra VOLS <<< "$volumes"
                for vol in "${VOLS[@]}"; do
                    echo "Volume=${vol}" >> "$temp_file"
                done
                echo "" >> "$temp_file"
            fi
            echo "$line" >> "$temp_file"
        done < "$quadlet_file"
        
        # Replace original file
        mv "$temp_file" "$quadlet_file"
        chmod 644 "$quadlet_file"
        
        # Reload systemd to pick up changes
        systemctl daemon-reload
        log_info "Added custom volumes to quadlet"
    else
        log_info "[3/4] No custom volumes specified, skipping..."
    fi
    
    # Step 4: Start the service
    if [[ "$no_start" != "true" ]]; then
        log_info "[4/4] Starting service..."
        if ! systemctl start "${service_name}.service"; then
            log_error "Failed to start service. Check logs with: journalctl -u ${service_name}.service"
            return 1
        fi
        
        # Wait a moment and check status
        sleep 2
        if systemctl is-active --quiet "${service_name}.service"; then
            log_info "Service ${service_name} is running!"
        else
            log_warn "Service may not be running. Check: systemctl status ${service_name}.service"
        fi
    else
        log_info "[4/4] Skipping service start (--no-start specified)"
    fi
    
    log_info "========================================"
    log_info "Provisioning complete!"
    log_info "========================================"
    log_info "Service: ${service_name}.service"
    log_info "Quadlet: ${QUADLET_DIR}/${service_name}.container"
    log_info "App Dir: ${BASE_DIR}/${tenant_name}/${app_name}/"
    log_info ""
    log_info "Useful commands:"
    log_info "  Status:  systemctl status ${service_name}.service"
    log_info "  Logs:    journalctl -u ${service_name}.service -f"
    log_info "  Restart: systemctl restart ${service_name}.service"
    log_info "  Stop:    systemctl stop ${service_name}.service"
    
    return 0
}

create_app() {
    local tenant_name="$1"
    local app_name="$2"
    local app_logic="${3:-echo 'Hello from app'}"
    local service_type="${4:-simple}"
    
    validate_name "$tenant_name" "tenant" || return 1
    validate_name "$app_name" "app" || return 1
    
    # Ensure tenant exists
    if ! getent group "$tenant_name" > /dev/null 2>&1; then
        log_info "Tenant '$tenant_name' does not exist, creating..."
        create_tenant "$tenant_name" || return 1
    fi
    
    local app_user="${tenant_name}_${app_name}"
    
    # Check if app user already exists
    if id "$app_user" > /dev/null 2>&1; then
        log_warn "App user '$app_user' already exists"
        return 0
    fi
    
    # Create app user (system user, no login shell, belongs to tenant group)
    if ! useradd \
        --system \
        --gid "$tenant_name" \
        --no-create-home \
        --shell /usr/sbin/nologin \
        --comment "App_${app_name}_Tenant_${tenant_name}" \
        "$app_user"; then
        log_error "Failed to create user: $app_user"
        return 1
    fi
    
    log_info "Created app user: $app_user (member of group: $tenant_name)"
    
    # Create log directory
    mkdir -p "${LOG_DIR}/${tenant_name}"
    chown root:"$tenant_name" "${LOG_DIR}/${tenant_name}"
    chmod 2770 "${LOG_DIR}/${tenant_name}"
    
    # Create directories
    create_app_directories "$tenant_name" "$app_name"
    
    # Create app script
    create_app_script "$tenant_name" "$app_name" "$app_logic"
    
    # Create systemd service
    create_systemd_service "$tenant_name" "$app_name" "$service_type"
    
    log_info "App '$app_name' for tenant '$tenant_name' provisioned successfully"
    return 0
}

delete_app() {
    local tenant_name="$1"
    local app_name="$2"
    local app_user="${tenant_name}_${app_name}"
    local service_name="${tenant_name}-${app_name}"
    
    # Stop and disable service
    if systemctl is-active --quiet "${service_name}.service" 2>/dev/null; then
        systemctl stop "${service_name}.service"
        log_info "Stopped service: ${service_name}"
    fi
    
    if systemctl is-enabled --quiet "${service_name}.service" 2>/dev/null; then
        systemctl disable "${service_name}.service"
        log_info "Disabled service: ${service_name}"
    fi
    
    # Remove service file
    local service_file="${SYSTEMD_DIR}/${service_name}.service"
    if [[ -f "$service_file" ]]; then
        rm -f "$service_file"
        systemctl daemon-reload
        log_info "Removed service file: $service_file"
    fi
    
    # Remove app script
    local script_path="${APP_SCRIPTS_DIR}/${tenant_name}/${app_name}.sh"
    if [[ -f "$script_path" ]]; then
        rm -f "$script_path"
        log_info "Removed app script: $script_path"
    fi
    
    # Remove app directories
    local app_dir="${BASE_DIR}/${tenant_name}/${app_name}"
    if [[ -d "$app_dir" ]]; then
        rm -rf "$app_dir"
        log_info "Removed app directory: $app_dir"
    fi
    
    # Remove app user
    if id "$app_user" > /dev/null 2>&1; then
        userdel "$app_user"
        log_info "Deleted app user: $app_user"
    fi
    
    log_info "App '$app_name' for tenant '$tenant_name' removed successfully"
    return 0
}

#-------------------------------------------------------------------------------
# Service Management
#-------------------------------------------------------------------------------
start_app() {
    local tenant_name="$1"
    local app_name="$2"
    local service_name="${tenant_name}-${app_name}"
    
    systemctl start "${service_name}.service"
    log_info "Started service: ${service_name}"
}

stop_app() {
    local tenant_name="$1"
    local app_name="$2"
    local service_name="${tenant_name}-${app_name}"
    
    systemctl stop "${service_name}.service"
    log_info "Stopped service: ${service_name}"
}

enable_app() {
    local tenant_name="$1"
    local app_name="$2"
    local service_name="${tenant_name}-${app_name}"
    
    systemctl enable "${service_name}.service"
    log_info "Enabled service: ${service_name}"
}

disable_app() {
    local tenant_name="$1"
    local app_name="$2"
    local service_name="${tenant_name}-${app_name}"
    
    systemctl disable "${service_name}.service"
    log_info "Disabled service: ${service_name}"
}

status_app() {
    local tenant_name="$1"
    local app_name="$2"
    local service_name="${tenant_name}-${app_name}"
    
    systemctl status "${service_name}.service"
}

#-------------------------------------------------------------------------------
# Listing Functions
#-------------------------------------------------------------------------------
list_tenants() {
    log_info "Registered tenants:"
    for dir in "${BASE_DIR}"/*/; do
        if [[ -d "$dir" ]]; then
            local tenant_name
            tenant_name=$(basename "$dir")
            if getent group "$tenant_name" > /dev/null 2>&1; then
                echo "  - $tenant_name"
            fi
        fi
    done
}

list_apps() {
    local tenant_name="$1"
    
    if ! getent group "$tenant_name" > /dev/null 2>&1; then
        log_error "Tenant '$tenant_name' does not exist"
        return 1
    fi
    
    log_info "Apps for tenant '$tenant_name':"
    for dir in "${BASE_DIR}/${tenant_name}"/*/; do
        if [[ -d "$dir" ]]; then
            local app_name
            app_name=$(basename "$dir")
            local app_user="${tenant_name}_${app_name}"
            local service_name="${tenant_name}-${app_name}"
            local status="unknown"
            
            if systemctl is-active --quiet "${service_name}.service" 2>/dev/null; then
                status="running"
            elif systemctl is-enabled --quiet "${service_name}.service" 2>/dev/null; then
                status="stopped (enabled)"
            else
                status="stopped (disabled)"
            fi
            
            echo "  - $app_name (user: $app_user, status: $status)"
        fi
    done
}

#-------------------------------------------------------------------------------
# Usage
#-------------------------------------------------------------------------------
usage() {
    cat << EOF
Usage: $(basename "$0") <command> [options]

Tenant Commands:
  create-tenant <tenant_name>          Create a new tenant (OS group)
  delete-tenant <tenant_name>          Delete a tenant (must have no apps)
  list-tenants                         List all tenants

Script-Based App Commands:
  create-app <tenant> <app> [script_file] [service_type]
                                       Create a script-based app for a tenant
                                       script_file: Path to script with app logic
                                       service_type: simple|oneshot|forking (default: simple)
  delete-app <tenant> <app>            Delete a script-based app
  list-apps <tenant>                   List apps for a tenant

Container App Commands (Podman Quadlet):
  provision <tenant> <app> <image> [ports] [env_vars] [extra_args] [volumes] [--no-start]
                                       All-in-one: pull image, create tenant/app, add volumes, start
                                       This is the recommended way to deploy a container app!
                                       image: Docker/OCI image (e.g., docker.io/nginx:latest)
                                       ports: Port mappings (e.g., "8080:80,8443:443")
                                       env_vars: Environment variables (e.g., "KEY=val,KEY2=val2")
                                       extra_args: Additional podman arguments (e.g., "--memory=1g")
                                       volumes: Custom volume mounts (e.g., "/data:/app/data:rw,vol:/mnt:ro")
                                       --no-start: Don't start the service after provisioning

  create-container <tenant> <app> <image> [ports] [env_vars] [extra_args]
                                       Create a container app (without starting)
                                       image: Docker/OCI image (e.g., docker.io/nginx:latest)
                                       ports: Port mappings (e.g., "8080:80,8443:443")
                                       env_vars: Environment variables (e.g., "KEY=val,KEY2=val2")
                                       extra_args: Additional podman arguments
  create-kube <tenant> <app> <kube_yaml>
                                       Create a Kubernetes-style pod using Podman Quadlet
                                       kube_yaml: Path to Kubernetes YAML file
  delete-container <tenant> <app>      Delete a container app
  list-containers <tenant>             List container apps for a tenant
  pull-image <image>                   Pull a container image

Service Commands (works for both script and container apps):
  start <tenant> <app>                 Start app service
  stop <tenant> <app>                  Stop app service
  restart <tenant> <app>               Restart app service
  enable <tenant> <app>                Enable app service at boot
  disable <tenant> <app>               Disable app service at boot
  status <tenant> <app>                Show app service status
  logs <tenant> <app>                  Show app service logs

Examples:
  # Quick provision (recommended - all-in-one command)
  $(basename "$0") provision xdoc api docker.io/myapp:latest "3000:3000" "NODE_ENV=production"
  
  # Provision with custom volumes
  $(basename "$0") provision xdoc api docker.io/myapp:latest "3000:3000" "NODE_ENV=prod" "" "/uploads:/app/uploads:rw,pg-vol:/var/run/postgresql"

  # Provision without auto-start
  $(basename "$0") provision xdoc api docker.io/myapp:latest "3000:3000" "" "" "" --no-start

  # Tenant management
  $(basename "$0") create-tenant acme
  $(basename "$0") list-tenants

  # Script-based app
  $(basename "$0") create-app acme webapp ./webapp-logic.sh simple
  $(basename "$0") start acme webapp

  # Container app (manual steps - use 'provision' instead for simplicity)
  $(basename "$0") create-container acme nginx docker.io/nginx:latest "8080:80" "NGINX_HOST=localhost"
  $(basename "$0") start acme nginx
  $(basename "$0") logs acme nginx

  # Kubernetes-style pod
  $(basename "$0") create-kube acme myapp ./myapp-pod.yaml
  
  # List and status
  $(basename "$0") list-apps acme
  $(basename "$0") list-containers acme
  $(basename "$0") status acme nginx

Directory Structure (Script Apps):
  /srv/<tenant>/<app>/
  ├── read/    (550) - Read-only data
  ├── write/   (700) - Private writable data
  ├── exec/    (550) - Executable scripts
  └── shared/  (750) - Shared with tenant group

Directory Structure (Container Apps):
  /srv/<tenant>/<app>/
  ├── read/    (550) - Read-only data        -> /app/read
  ├── write/   (700) - Private writable      -> /app/write
  ├── exec/    (550) - Executable scripts    -> /app/exec
  ├── shared/  (750) - Shared with tenant    -> /app/shared
  ├── data/    (700) - Persistent data       -> /app/data
  ├── config/  (500) - Config files          -> /app/config
  ├── logs/    (700) - Container logs        -> /app/logs
  └── secrets/ (500) - Secrets               -> /run/secrets

Container User Mapping:
  - Each container app user gets a unique UID (100000+)
  - Container runs with UserNS=keep-id for UID/GID mapping
  - Host user permissions directly apply inside container

EOF
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    check_root
    
    local command="${1:-}"
    shift || true
    
    case "$command" in
        # Tenant commands
        create-tenant)
            [[ $# -lt 1 ]] && { usage; exit 1; }
            create_tenant "$1"
            ;;
        delete-tenant)
            [[ $# -lt 1 ]] && { usage; exit 1; }
            delete_tenant "$1"
            ;;
        list-tenants)
            list_tenants
            ;;
        
        # Script-based app commands
        create-app)
            [[ $# -lt 2 ]] && { usage; exit 1; }
            local tenant="$1"
            local app="$2"
            local script_file="${3:-}"
            local service_type="${4:-simple}"
            local app_logic="echo 'Hello from $app'"
            
            if [[ -n "$script_file" && -f "$script_file" ]]; then
                app_logic=$(cat "$script_file")
            fi
            
            create_app "$tenant" "$app" "$app_logic" "$service_type"
            ;;
        delete-app)
            [[ $# -lt 2 ]] && { usage; exit 1; }
            delete_app "$1" "$2"
            ;;
        list-apps)
            [[ $# -lt 1 ]] && { usage; exit 1; }
            list_apps "$1"
            ;;
        
        # Container app commands (Podman Quadlet)
        provision)
            [[ $# -lt 3 ]] && { usage; exit 1; }
            local tenant="$1"
            local app="$2"
            local image="$3"
            local ports="${4:-}"
            local env_vars="${5:-}"
            local extra_args="${6:-}"
            local volumes="${7:-}"
            local no_start="false"
            
            # Check for --no-start flag in any position
            for arg in "$@"; do
                if [[ "$arg" == "--no-start" ]]; then
                    no_start="true"
                fi
            done
            
            check_podman || exit 1
            provision_container "$tenant" "$app" "$image" "$ports" "$env_vars" "$extra_args" "$volumes" "$no_start"
            ;;
        create-container)
            [[ $# -lt 3 ]] && { usage; exit 1; }
            local tenant="$1"
            local app="$2"
            local image="$3"
            local ports="${4:-}"
            local env_vars="${5:-}"
            local extra_args="${6:-}"
            
            create_container_app "$tenant" "$app" "$image" "$ports" "$env_vars" "$extra_args"
            ;;
        create-kube)
            [[ $# -lt 3 ]] && { usage; exit 1; }
            local tenant="$1"
            local app="$2"
            local kube_yaml="$3"
            
            # First create the app user and directories
            validate_name "$tenant" "tenant" || exit 1
            validate_name "$app" "app" || exit 1
            check_podman || exit 1
            
            if ! getent group "$tenant" > /dev/null 2>&1; then
                create_tenant "$tenant" || exit 1
            fi
            
            local app_user="${tenant}_${app}"
            if ! id "$app_user" > /dev/null 2>&1; then
                local next_uid
                next_uid=$(awk -F: 'BEGIN{max=100000} $3>=100000 && $3>max {max=$3} END{print max+1}' /etc/passwd)
                if ! useradd --system --uid "$next_uid" --gid "$tenant" --no-create-home \
                    --shell /usr/sbin/nologin --comment "Kube_App_${app}_Tenant_${tenant}" "$app_user"; then
                    log_error "Failed to create user: $app_user"
                    exit 1
                fi
                log_info "Created kube app user: $app_user (UID: $next_uid)"
            fi
            
            create_app_directories "$tenant" "$app" "true"
            create_quadlet_kube "$tenant" "$app" "$kube_yaml"
            ;;
        delete-container)
            [[ $# -lt 2 ]] && { usage; exit 1; }
            delete_container_app "$1" "$2"
            ;;
        list-containers)
            [[ $# -lt 1 ]] && { usage; exit 1; }
            list_container_apps "$1"
            ;;
        pull-image)
            [[ $# -lt 1 ]] && { usage; exit 1; }
            check_podman || exit 1
            pull_image "$1"
            ;;
        
        # Service commands (works for both script and container apps)
        start)
            [[ $# -lt 2 ]] && { usage; exit 1; }
            start_app "$1" "$2"
            ;;
        stop)
            [[ $# -lt 2 ]] && { usage; exit 1; }
            stop_app "$1" "$2"
            ;;
        restart)
            [[ $# -lt 2 ]] && { usage; exit 1; }
            local service_name="${1}-${2}"
            systemctl restart "${service_name}.service"
            log_info "Restarted service: ${service_name}"
            ;;
        enable)
            [[ $# -lt 2 ]] && { usage; exit 1; }
            enable_app "$1" "$2"
            ;;
        disable)
            [[ $# -lt 2 ]] && { usage; exit 1; }
            disable_app "$1" "$2"
            ;;
        status)
            [[ $# -lt 2 ]] && { usage; exit 1; }
            status_app "$1" "$2"
            ;;
        logs)
            [[ $# -lt 2 ]] && { usage; exit 1; }
            local service_name="${1}-${2}"
            journalctl -u "${service_name}.service" -f
            ;;
        
        # Help
        help|--help|-h)
            usage
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"

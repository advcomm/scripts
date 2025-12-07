#!/bin/bash
#===============================================================================
# Script to install NGINX using Podman Quadlet with IPv4/IPv6 support
# 
# This uses Quadlet (.container file) instead of manual podman run commands.
# Systemd automatically generates the service from the Quadlet specification.
#
# Author: System Architect
# Version: 1.0.0
#===============================================================================

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Configuration
readonly QUADLET_DIR="/etc/containers/systemd"
readonly NGINX_CONFIG_DIR="/etc/nginx-podman"
readonly NGINX_LOG_DIR="/var/log/nginx-podman"
readonly NGINX_HTML_DIR="/var/www/html-podman"
readonly SERVICE_NAME="nginx-proxy"

#-------------------------------------------------------------------------------
# Logging Functions
#-------------------------------------------------------------------------------
log_info() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2
    exit 1
}

#-------------------------------------------------------------------------------
# Utility Functions
#-------------------------------------------------------------------------------
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS. /etc/os-release not found."
    fi
}

#-------------------------------------------------------------------------------
# Podman Installation
#-------------------------------------------------------------------------------
install_podman_debian() {
    log_info "Installing Podman on Ubuntu/Debian..."
    apt-get update
    apt-get install -y podman
    systemctl enable --now podman.socket
    log_info "Podman installed successfully"
}

install_podman_rhel() {
    log_info "Installing Podman on RHEL/CentOS/Fedora..."
    if command_exists dnf; then
        dnf install -y podman
    elif command_exists yum; then
        yum install -y podman
    else
        log_error "Neither dnf nor yum found"
    fi
    systemctl enable --now podman.socket
    log_info "Podman installed successfully"
}

install_podman() {
    if command_exists podman; then
        log_info "Podman already installed: $(podman --version)"
        return 0
    fi
    
    detect_os
    case $OS in
        ubuntu|debian)
            install_podman_debian
            ;;
        centos|rhel|fedora|rocky|almalinux)
            install_podman_rhel
            ;;
        *)
            log_error "Unsupported OS: $OS. Please install Podman manually."
            ;;
    esac
}

#-------------------------------------------------------------------------------
# Directory and Configuration Setup
#-------------------------------------------------------------------------------
create_directories() {
    log_info "Creating NGINX directories..."
    
    mkdir -p "${NGINX_CONFIG_DIR}/conf.d"
    mkdir -p "${NGINX_CONFIG_DIR}/ssl"
    mkdir -p "${NGINX_LOG_DIR}"
    mkdir -p "${NGINX_HTML_DIR}"
    mkdir -p "${QUADLET_DIR}"
    
    # Set permissions - nginx in container runs as nginx user (UID 101)
    chown -R 101:101 "${NGINX_LOG_DIR}"
    chmod 755 "${NGINX_CONFIG_DIR}"
    chmod 755 "${NGINX_HTML_DIR}"
    
    log_info "Directories created successfully"
}

create_nginx_config() {
    log_info "Creating NGINX configuration..."
    
    cat > "${NGINX_CONFIG_DIR}/nginx.conf" << 'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    multi_accept on;
    use epoll;
}

http {
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 4096;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript 
               application/rss+xml application/atom+xml image/svg+xml;

    # Include additional configurations
    include /etc/nginx/conf.d/*.conf;

    # Default server block with IPv4 and IPv6 support
    server {
        listen 80;
        listen [::]:80;  # IPv6 support
        server_name localhost _;

        root /usr/share/nginx/html;
        index index.html index.htm;

        location / {
            try_files $uri $uri/ =404;
        }

        # Health check endpoint
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }

        # Error pages
        error_page 500 502 503 504 /50x.html;
        location = /50x.html {
            root /usr/share/nginx/html;
        }
    }
}
EOF

    log_info "NGINX configuration created"
}

create_sample_html() {
    log_info "Creating sample HTML file..."
    
    cat > "${NGINX_HTML_DIR}/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>NGINX Quadlet - Running!</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            max-width: 800px;
            margin: 50px auto;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
        }
        .container {
            background: white;
            border-radius: 10px;
            padding: 40px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.2);
        }
        h1 { color: #333; margin-bottom: 10px; }
        .badge {
            display: inline-block;
            background: #28a745;
            color: white;
            padding: 5px 15px;
            border-radius: 20px;
            font-size: 14px;
            margin-bottom: 20px;
        }
        .info {
            background: #f8f9fa;
            border-left: 4px solid #667eea;
            padding: 15px;
            margin: 20px 0;
        }
        code {
            background: #e9ecef;
            padding: 2px 6px;
            border-radius: 3px;
            font-family: 'Courier New', monospace;
        }
    </style>
</head>
<body>
    <div class="container">
        <span class="badge">✓ Quadlet Powered</span>
        <h1>Welcome to NGINX via Podman Quadlet!</h1>
        <p>This NGINX instance is running as a <strong>systemd-managed Podman container</strong> using Quadlet.</p>
        
        <div class="info">
            <strong>Features:</strong>
            <ul>
                <li>IPv4 and IPv6 support</li>
                <li>Host networking for optimal performance</li>
                <li>Automatic restart on failure</li>
                <li>Systemd integration</li>
                <li>Configuration files on host</li>
            </ul>
        </div>
        
        <h3>Quick Commands</h3>
        <p>
            <code>systemctl status nginx-proxy</code> - Check status<br>
            <code>systemctl restart nginx-proxy</code> - Restart<br>
            <code>journalctl -u nginx-proxy -f</code> - View logs
        </p>
    </div>
</body>
</html>
EOF

    # Set ownership for nginx user in container
    chown 101:101 "${NGINX_HTML_DIR}/index.html"
    
    log_info "Sample HTML created"
}

create_upstream_config() {
    log_info "Creating sample upstream configuration..."
    
    cat > "${NGINX_CONFIG_DIR}/conf.d/upstreams.conf.example" << 'EOF'
# Example upstream configuration for tenant apps
# Rename to upstreams.conf to enable

# upstream acme_webapp {
#     server 127.0.0.1:8080;
#     keepalive 32;
# }
#
# server {
#     listen 80;
#     listen [::]:80;
#     server_name acme.example.com;
#
#     location / {
#         proxy_pass http://acme_webapp;
#         proxy_http_version 1.1;
#         proxy_set_header Upgrade $http_upgrade;
#         proxy_set_header Connection 'upgrade';
#         proxy_set_header Host $host;
#         proxy_set_header X-Real-IP $remote_addr;
#         proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
#         proxy_set_header X-Forwarded-Proto $scheme;
#         proxy_cache_bypass $http_upgrade;
#     }
# }
EOF

    log_info "Sample upstream config created"
}

#-------------------------------------------------------------------------------
# Quadlet Creation
#-------------------------------------------------------------------------------
cleanup_existing() {
    log_info "Cleaning up existing installation..."
    
    # Stop and disable old service if exists
    if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
        systemctl stop "${SERVICE_NAME}.service"
    fi
    
    # Remove old manual service file if exists
    if [[ -f "/etc/systemd/system/nginx-podman.service" ]]; then
        systemctl disable nginx-podman.service 2>/dev/null || true
        rm -f "/etc/systemd/system/nginx-podman.service"
    fi
    
    # Remove old container
    if podman ps -a --format "{{.Names}}" | grep -q "^nginx-server$"; then
        podman stop nginx-server 2>/dev/null || true
        podman rm nginx-server 2>/dev/null || true
    fi
    
    if podman ps -a --format "{{.Names}}" | grep -q "^${SERVICE_NAME}$"; then
        podman stop "${SERVICE_NAME}" 2>/dev/null || true
        podman rm "${SERVICE_NAME}" 2>/dev/null || true
    fi
    
    log_info "Cleanup completed"
}

create_quadlet() {
    log_info "Creating Podman Quadlet for NGINX..."
    
    cat > "${QUADLET_DIR}/${SERVICE_NAME}.container" << EOF
# NGINX Reverse Proxy Quadlet
# Generated: $(date -Iseconds)
#
# This file is processed by systemd-generators to create:
#   ${SERVICE_NAME}.service
#
# Manage with:
#   systemctl start|stop|restart|status ${SERVICE_NAME}
#   journalctl -u ${SERVICE_NAME} -f

[Unit]
Description=NGINX Reverse Proxy (Podman Quadlet)
Documentation=https://nginx.org/en/docs/
After=network-online.target local-fs.target
Wants=network-online.target

[Container]
# Container image
Image=docker.io/library/nginx:latest
ContainerName=${SERVICE_NAME}

# Use host networking for direct IPv4/IPv6 access
# This is optimal for a reverse proxy - no port mapping overhead
Network=host

# Volume mounts - read configuration from host
Volume=${NGINX_CONFIG_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro,Z
Volume=${NGINX_CONFIG_DIR}/conf.d:/etc/nginx/conf.d:ro,Z
Volume=${NGINX_CONFIG_DIR}/ssl:/etc/nginx/ssl:ro,Z
Volume=${NGINX_HTML_DIR}:/usr/share/nginx/html:ro,Z
Volume=${NGINX_LOG_DIR}:/var/log/nginx:rw,Z

# Environment variables
Environment=NGINX_ENTRYPOINT_QUIET_LOGS=1
Environment=TZ=UTC

# Health check
HealthCmd=curl -f http://localhost/health || exit 1
HealthInterval=30s
HealthTimeout=10s
HealthRetries=3
HealthStartPeriod=10s

# Security options
NoNewPrivileges=true

# Auto-update support (optional)
AutoUpdate=registry

# Labels
Label=app=nginx-proxy
Label=managed-by=quadlet

[Service]
# Restart policy
Restart=always
RestartSec=5
TimeoutStartSec=120
TimeoutStopSec=30

# Logging to journal
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# Reload nginx config without restart
ExecReload=/usr/bin/podman exec ${SERVICE_NAME} nginx -s reload

[Install]
WantedBy=multi-user.target default.target
EOF

    chmod 644 "${QUADLET_DIR}/${SERVICE_NAME}.container"
    
    log_info "Quadlet file created: ${QUADLET_DIR}/${SERVICE_NAME}.container"
}

#-------------------------------------------------------------------------------
# IPv6 Configuration
#-------------------------------------------------------------------------------
enable_ipv6() {
    log_info "Checking IPv6 configuration..."
    
    if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
        if [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" == "1" ]]; then
            log_warn "IPv6 is disabled. Enabling..."
            
            sysctl -w net.ipv6.conf.all.disable_ipv6=0
            sysctl -w net.ipv6.conf.default.disable_ipv6=0
            
            # Make persistent
            if ! grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf; then
                echo "net.ipv6.conf.all.disable_ipv6 = 0" >> /etc/sysctl.conf
                echo "net.ipv6.conf.default.disable_ipv6 = 0" >> /etc/sysctl.conf
            fi
            
            log_info "IPv6 enabled"
        else
            log_info "IPv6 is already enabled"
        fi
    fi
}

#-------------------------------------------------------------------------------
# Service Activation
#-------------------------------------------------------------------------------
activate_quadlet() {
    log_info "Activating Quadlet service..."
    
    # Pull the image first
    log_info "Pulling NGINX image..."
    podman pull docker.io/library/nginx:latest
    
    # Reload systemd to process Quadlet files
    # This triggers the quadlet generator to create the service
    systemctl daemon-reload
    
    # Note: Quadlet-generated services are automatically enabled via [Install] section
    # We don't need to run 'systemctl enable' - it will fail with "transient or generated"
    # The WantedBy= in [Install] handles auto-start
    
    # Start the service
    log_info "Starting NGINX service..."
    systemctl start "${SERVICE_NAME}.service"
    
    # Wait for container to be ready
    log_info "Waiting for NGINX to start..."
    sleep 3
    
    # Verify it's running
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        log_info "NGINX Quadlet service is running!"
    else
        log_error "Failed to start NGINX service. Check: journalctl -u ${SERVICE_NAME}"
    fi
}

#-------------------------------------------------------------------------------
# Status Display
#-------------------------------------------------------------------------------
show_status() {
    echo ""
    echo "=========================================="
    echo "  NGINX Quadlet Installation Complete"
    echo "=========================================="
    echo ""
    
    echo "=== Service Status ==="
    systemctl status "${SERVICE_NAME}.service" --no-pager -l || true
    
    echo ""
    echo "=== Container Status ==="
    podman ps --filter "name=${SERVICE_NAME}" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"
    
    echo ""
    echo "=== Network Addresses ==="
    echo "IPv4:"
    ip -4 addr show | grep -E "inet.*scope global" | awk '{print "  " $2}' | head -5
    echo "IPv6:"
    ip -6 addr show | grep -E "inet6.*scope global" | awk '{print "  " $2}' | head -5
    
    echo ""
    echo "=== Connection Test ==="
    echo -n "IPv4 (http://127.0.0.1): "
    curl -sf http://127.0.0.1/health && echo "OK" || echo "FAILED"
    echo -n "IPv6 (http://[::1]): "
    curl -sf http://[::1]/health 2>/dev/null && echo "OK" || echo "Not available"
    
    echo ""
    echo "=== File Locations ==="
    echo "  Quadlet file:    ${QUADLET_DIR}/${SERVICE_NAME}.container"
    echo "  NGINX config:    ${NGINX_CONFIG_DIR}/nginx.conf"
    echo "  Virtual hosts:   ${NGINX_CONFIG_DIR}/conf.d/"
    echo "  SSL certificates: ${NGINX_CONFIG_DIR}/ssl/"
    echo "  Web root:        ${NGINX_HTML_DIR}/"
    echo "  Logs:            ${NGINX_LOG_DIR}/"
    
    echo ""
    echo "=== Useful Commands ==="
    echo "  systemctl status ${SERVICE_NAME}      # Check status"
    echo "  systemctl restart ${SERVICE_NAME}     # Restart service"
    echo "  systemctl reload ${SERVICE_NAME}      # Reload config (no downtime)"
    echo "  journalctl -u ${SERVICE_NAME} -f      # Follow logs"
    echo "  podman exec ${SERVICE_NAME} nginx -t  # Test config"
    echo ""
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    log_info "Starting NGINX Quadlet installation..."
    
    check_root
    install_podman
    enable_ipv6
    cleanup_existing
    create_directories
    create_nginx_config
    create_sample_html
    create_upstream_config
    create_quadlet
    activate_quadlet
    show_status
    
    log_info "Installation completed successfully!"
}

main "$@"

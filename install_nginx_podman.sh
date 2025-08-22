#!/bin/bash

# Script to install NGINX container in Podman with IPv4/IPv6 support
# Author: Generated Script
# Date: $(date)

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        error "Cannot detect OS. /etc/os-release not found."
    fi
}

# Function to install Podman on Ubuntu/Debian
install_podman_debian() {
    log "Installing Podman on Ubuntu/Debian..."
    
    # Update package list
    sudo apt-get update
    
    # Install required packages
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common
    
    # Install Podman
    sudo apt-get install -y podman
    
    # Enable and start podman service
    sudo systemctl enable podman
    sudo systemctl start podman
    
    log "Podman installed successfully on Ubuntu/Debian"
}

# Function to install Podman on CentOS/RHEL/Fedora
install_podman_rhel() {
    log "Installing Podman on CentOS/RHEL/Fedora..."
    
    if command_exists dnf; then
        sudo dnf install -y podman
    elif command_exists yum; then
        sudo yum install -y podman
    else
        error "Neither dnf nor yum package manager found"
    fi
    
    # Enable and start podman service
    sudo systemctl enable podman
    sudo systemctl start podman
    
    log "Podman installed successfully on CentOS/RHEL/Fedora"
}

# Function to install Podman
install_podman() {
    if command_exists podman; then
        log "Podman is already installed: $(podman --version)"
        return 0
    fi
    
    log "Podman not found. Installing Podman..."
    
    detect_os
    
    case $OS in
        ubuntu|debian)
            install_podman_debian
            ;;
        centos|rhel|fedora)
            install_podman_rhel
            ;;
        *)
            error "Unsupported OS: $OS. Please install Podman manually."
            ;;
    esac
}

# Function to create NGINX configuration directories
create_nginx_directories() {
    log "Creating NGINX configuration directories..."
    
    # Create directories for NGINX configurations
    sudo mkdir -p /etc/nginx-podman/conf.d
    sudo mkdir -p /etc/nginx-podman/ssl
    sudo mkdir -p /var/log/nginx-podman
    sudo mkdir -p /var/www/html-podman
    
    # Set proper permissions
    sudo chown -R $USER:$USER /etc/nginx-podman
    sudo chown -R $USER:$USER /var/log/nginx-podman
    sudo chown -R $USER:$USER /var/www/html-podman
    
    log "NGINX directories created successfully"
}

# Function to create default NGINX configuration with IPv4/IPv6 support
create_nginx_config() {
    log "Creating default NGINX configuration..."
    
    cat <<'EOF' | sudo tee /etc/nginx-podman/nginx.conf > /dev/null
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    types_hash_max_size 4096;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Include additional configurations
    include /etc/nginx/conf.d/*.conf;

    # Default server block with IPv4 and IPv6 support
    server {
        listen 80;
        listen [::]:80;  # IPv6 support
        server_name localhost;

        location / {
            root /usr/share/nginx/html;
            index index.html index.htm;
        }

        # Error pages
        error_page 500 502 503 504 /50x.html;
        location = /50x.html {
            root /usr/share/nginx/html;
        }
    }
}
EOF

    log "Default NGINX configuration created"
}

# Function to create sample HTML file
create_sample_html() {
    log "Creating sample HTML file..."
    
    cat <<'EOF' > /var/www/html-podman/index.html
<!DOCTYPE html>
<html>
<head>
    <title>Welcome to NGINX in Podman!</title>
    <style>
        body {
            width: 35em;
            margin: 0 auto;
            font-family: Tahoma, Verdana, Arial, sans-serif;
        }
    </style>
</head>
<body>
    <h1>Welcome to NGINX in Podman!</h1>
    <p>If you can see this page, the NGINX web server is successfully installed and
    working in a Podman container with IPv4/IPv6 support.</p>

    <p>For online documentation and support please refer to
    <a href="http://nginx.org/">nginx.org</a>.<br/>

    <p><em>Thank you for using NGINX in Podman.</em></p>
</body>
</html>
EOF

    log "Sample HTML file created"
}

# Function to stop and remove existing NGINX container
cleanup_existing_container() {
    if podman ps -a --format "{{.Names}}" | grep -q "^nginx-server$"; then
        log "Stopping and removing existing nginx-server container..."
        podman stop nginx-server 2>/dev/null || true
        podman rm nginx-server 2>/dev/null || true
    fi
}

# Function to run NGINX container
run_nginx_container() {
    log "Starting NGINX container with Podman..."
    
    # Clean up any existing container
    cleanup_existing_container
    
    # Pull the latest NGINX image
    podman pull docker.io/library/nginx:latest
    
    # Run NGINX container with host networking and volume mounts
    podman run -d \
        --name nginx-server \
        --network host \
        -v /etc/nginx-podman/nginx.conf:/etc/nginx/nginx.conf:ro \
        -v /etc/nginx-podman/conf.d:/etc/nginx/conf.d:ro \
        -v /etc/nginx-podman/ssl:/etc/nginx/ssl:ro \
        -v /var/log/nginx-podman:/var/log/nginx:rw \
        -v /var/www/html-podman:/usr/share/nginx/html:ro \
        --restart unless-stopped \
        docker.io/library/nginx:latest
    
    log "NGINX container started successfully!"
}

# Function to enable IPv6 (if not already enabled)
enable_ipv6() {
    log "Checking IPv6 configuration..."
    
    if [ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
        if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = "1" ]; then
            warn "IPv6 is disabled. Enabling IPv6..."
            echo 0 | sudo tee /proc/sys/net/ipv6/conf/all/disable_ipv6 > /dev/null
            echo 0 | sudo tee /proc/sys/net/ipv6/conf/default/disable_ipv6 > /dev/null
            
            # Make it persistent
            echo "net.ipv6.conf.all.disable_ipv6 = 0" | sudo tee -a /etc/sysctl.conf > /dev/null
            echo "net.ipv6.conf.default.disable_ipv6 = 0" | sudo tee -a /etc/sysctl.conf > /dev/null
            
            log "IPv6 enabled successfully"
        else
            log "IPv6 is already enabled"
        fi
    fi
}

# Function to create systemd service for auto-start
create_systemd_service() {
    log "Creating systemd service for NGINX container..."
    
    cat <<'EOF' | sudo tee /etc/systemd/system/nginx-podman.service > /dev/null
[Unit]
Description=NGINX Podman Container
After=network.target podman.service
Requires=podman.service

[Service]
Type=forking
RemainAfterExit=yes
ExecStart=/usr/bin/podman start nginx-server
ExecStop=/usr/bin/podman stop nginx-server
ExecReload=/usr/bin/podman restart nginx-server
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and enable service
    sudo systemctl daemon-reload
    sudo systemctl enable nginx-podman.service
    
    log "Systemd service created and enabled"
}

# Function to display container status and info
show_status() {
    log "Checking NGINX container status..."
    
    echo ""
    echo "=== Container Status ==="
    podman ps --filter name=nginx-server
    
    echo ""
    echo "=== Container Logs (last 10 lines) ==="
    podman logs --tail 10 nginx-server
    
    echo ""
    echo "=== Network Information ==="
    echo "IPv4 addresses:"
    ip -4 addr show | grep -E "inet.*scope global" | awk '{print $2}' | head -5
    
    echo "IPv6 addresses:"
    ip -6 addr show | grep -E "inet6.*scope global" | awk '{print $2}' | head -5
    
    echo ""
    echo "=== Testing Connections ==="
    echo "Testing IPv4 connection:"
    curl -I http://127.0.0.1 2>/dev/null | head -1 || echo "IPv4 connection failed"
    
    echo "Testing IPv6 connection:"
    curl -I http://[::1] 2>/dev/null | head -1 || echo "IPv6 connection failed or not available"
    
    echo ""
    log "NGINX is accessible on:"
    echo "  - IPv4: http://localhost or http://$(hostname -I | awk '{print $1}')"
    echo "  - IPv6: http://[::1] (if available)"
    echo ""
    echo "Configuration files are in: /etc/nginx-podman/"
    echo "Log files are in: /var/log/nginx-podman/"
    echo "Web root is in: /var/www/html-podman/"
}

# Main function
main() {
    log "Starting NGINX Podman installation script..."
    
    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        warn "Running as root. This script will create some files with root ownership."
    fi
    
    # Install Podman if not present
    install_podman
    
    # Enable IPv6
    enable_ipv6
    
    # Create necessary directories
    create_nginx_directories
    
    # Create NGINX configuration
    create_nginx_config
    
    # Create sample HTML file
    create_sample_html
    
    # Run NGINX container
    run_nginx_container
    
    # Create systemd service
    create_systemd_service
    
    # Wait a moment for container to start
    sleep 3
    
    # Show status
    show_status
    
    log "NGINX Podman installation completed successfully!"
    
    echo ""
    echo "=== Next Steps ==="
    echo "1. Modify /etc/nginx-podman/nginx.conf to customize your configuration"
    echo "2. Add virtual hosts in /etc/nginx-podman/conf.d/"
    echo "3. Place SSL certificates in /etc/nginx-podman/ssl/"
    echo "4. Restart the container: podman restart nginx-server"
    echo "5. Check logs: podman logs nginx-server"
    echo "6. To stop: systemctl stop nginx-podman"
    echo "7. To start: systemctl start nginx-podman"
}

# Run main function
main "$@"

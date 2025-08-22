#!/bin/bash

# Script to configure NGINX container for gRPC reverse proxy with SSL support
# Usage: ./nginx_grpc_proxy_container.sh <ip_address> <app_name> <grpc_port> [cert_name]

set -e

# Variables
IP_ADDRESS="$1"
APP_NAME="$2"
GRPC_PORT="$3"
CERT_NAME="${4:-ssl-cert}"
NGINX_CONF_DIR="/etc/nginx-podman/conf.d"
NGINX_CONF_FILE="${NGINX_CONF_DIR}/grpc-proxy.conf"
NGINX_SSL_CONF_FILE="${NGINX_CONF_DIR}/grpc-ssl-proxy.conf"
NGINX_SSL_DIR="/etc/nginx-podman/ssl"
CONTAINER_NAME="nginx-server"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No color

# Functions
print_success() {
    echo -e "${GREEN}[✔] $1${NC}"
}

print_error() {
    echo -e "${RED}[✘] $1${NC}"
    exit 1
}

print_warning() {
    echo -e "${YELLOW}[⚠] $1${NC}"
}

check_command() {
    if ! command -v "$1" &>/dev/null; then
        print_error "$1 is not installed. Please install it first."
    fi
}

# Validate input
if [ -z "$IP_ADDRESS" ] || [ -z "$APP_NAME" ] || [ -z "$GRPC_PORT" ]; then
    echo "Usage: $0 <ip_address> <app_name> <grpc_port> [cert_name]"
    echo ""
    echo "Arguments:"
    echo "  ip_address  - Server IP address"
    echo "  app_name    - gRPC application name"
    echo "  grpc_port   - gRPC service port"
    echo "  cert_name   - SSL certificate name (optional, default: ssl-cert)"
    echo ""
    echo "Examples:"
    echo "  $0 95.216.189.60 mtdd 50051"
    echo "  $0 95.216.189.60 mtddlookup 50054 myserver"
    echo ""
    echo "SSL Certificate:"
    echo "  If SSL certificate exists, HTTPS gRPC proxy will be configured"
    echo "  If no SSL certificate, HTTP-only gRPC proxy will be configured"
    echo "  Generate SSL certificate first: sudo ./create_ssl_cert_ip.sh <ip> [cert_name]"
    exit 1
fi

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    print_error "This script requires sudo privileges"
fi

# Ensure Podman is installed
check_command podman

# Check if NGINX container is running
if ! podman ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    print_error "NGINX container '${CONTAINER_NAME}' is not running. Please run install_nginx_podman.sh first."
fi

# Create NGINX configuration directory if it doesn't exist
sudo mkdir -p "$NGINX_CONF_DIR"

# Function to check if SSL certificate exists
check_ssl_certificate() {
    local cert_file="${NGINX_SSL_DIR}/${CERT_NAME}.crt"
    local key_file="${NGINX_SSL_DIR}/${CERT_NAME}.key"
    
    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        print_success "SSL certificate found: $CERT_NAME"
        return 0
    else
        print_warning "SSL certificate not found: $CERT_NAME"
        print_warning "Certificate: $cert_file"
        print_warning "Key: $key_file"
        print_warning "Run gen_sscertificate.sh first to generate SSL certificate"
        return 1
    fi
}

# Function to check if SSL server block already exists
check_existing_ssl_server() {
    local ssl_cert_conf="/etc/nginx-podman/conf.d/ssl-${CERT_NAME}.conf"
    
    if [[ -f "$ssl_cert_conf" ]]; then
        print_success "Found existing SSL server configuration: ssl-${CERT_NAME}.conf"
        return 0
    else
        print_warning "No existing SSL server configuration found"
        return 1
    fi
}

# Function to create HTTP gRPC configuration
create_http_grpc_config() {
    # Check if the unified HTTP gRPC configuration exists, if not create it
    if [ ! -f "$NGINX_CONF_FILE" ]; then
        echo "Creating unified HTTP gRPC reverse proxy configuration..."
        cat << 'EOF' | sudo tee "$NGINX_CONF_FILE" > /dev/null
# Unified HTTP gRPC reverse proxy configuration
server {
    listen 80;
    listen [::]:80;
    http2 on;
    
    server_name IP_ADDRESS_PLACEHOLDER;
    
    # Default location (can be customized)
    location / {
        return 404 "gRPC service not found";
    }
    
    # Custom error page for gRPC 502 errors
    location = /grpc_502_error {
        internal;
        default_type application/grpc;
        add_header grpc-status 14;
        add_header grpc-message "Service Unavailable";
        return 204;
    }
}
EOF
        
        # Replace placeholder with actual IP
        sudo sed -i "s/IP_ADDRESS_PLACEHOLDER/$IP_ADDRESS/g" "$NGINX_CONF_FILE"
        print_success "Created unified HTTP gRPC configuration file"
    fi
}

# Function to create HTTPS gRPC configuration
create_https_grpc_config() {
    # Check if the unified HTTPS gRPC configuration exists, if not create it
    if [ ! -f "$NGINX_SSL_CONF_FILE" ]; then
        echo "Creating unified HTTPS gRPC reverse proxy configuration..."
        cat << 'EOF' | sudo tee "$NGINX_SSL_CONF_FILE" > /dev/null
# Unified HTTPS gRPC reverse proxy configuration
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    
    server_name IP_ADDRESS_PLACEHOLDER;
    
    # SSL Certificate Configuration
    ssl_certificate /etc/nginx/ssl/CERT_NAME_PLACEHOLDER.crt;
    ssl_certificate_key /etc/nginx/ssl/CERT_NAME_PLACEHOLDER.key;
    
    # SSL Security Settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    # Security Headers
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Default location (can be customized)
    location / {
        return 404 "gRPC service not found";
    }
    
    # Custom error page for gRPC 502 errors
    location = /grpc_502_error {
        internal;
        default_type application/grpc;
        add_header grpc-status 14;
        add_header grpc-message "Service Unavailable";
        return 204;
    }
}

# HTTP to HTTPS redirect for gRPC
server {
    listen 80;
    listen [::]:80;
    server_name IP_ADDRESS_PLACEHOLDER;
    
    # Redirect HTTP to HTTPS
    return 301 https://$server_name$request_uri;
}
EOF
        
        # Replace placeholders with actual values
        sudo sed -i "s/IP_ADDRESS_PLACEHOLDER/$IP_ADDRESS/g" "$NGINX_SSL_CONF_FILE"
        sudo sed -i "s/CERT_NAME_PLACEHOLDER/$CERT_NAME/g" "$NGINX_SSL_CONF_FILE"
        print_success "Created unified HTTPS gRPC configuration file"
    fi
}

# Function to add gRPC location to configuration
add_grpc_location() {
    local config_file="$1"
    local protocol="$2"
    
    # Check if this app location already exists
    if grep -q "location /$APP_NAME/" "$config_file"; then
        print_error "Configuration for $APP_NAME already exists in $config_file"
    fi
    
    # Add the new gRPC location block before the closing brace
    echo "Adding $protocol gRPC location for $APP_NAME..."
    sudo sed -i "/^}$/i\\
    # gRPC location for $APP_NAME\\
    location /$APP_NAME/ {\\
        grpc_pass grpc://127.0.0.1:$GRPC_PORT;\\
        grpc_set_header Host \$host;\\
        grpc_set_header X-Real-IP \$remote_addr;\\
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\\
        grpc_set_header X-Forwarded-Proto \$scheme;\\
        \\
        # gRPC specific settings\\
        grpc_read_timeout 300;\\
        grpc_send_timeout 300;\\
        client_max_body_size 0;\\
        \\
        # Error handling for gRPC\\
        error_page 502 = /grpc_502_error;\\
    }\\
" "$config_file"
}

# Function to add gRPC location to existing SSL configuration
add_grpc_to_existing_ssl_config() {
    local ssl_cert_conf="/etc/nginx-podman/conf.d/ssl-${CERT_NAME}.conf"
    local app_name="$1"
    local grpc_port="$2"
    
    # Check if this app location already exists in the SSL config
    if grep -q "location /$app_name/" "$ssl_cert_conf"; then
        print_error "Configuration for $app_name already exists in $ssl_cert_conf"
        return 1
    fi
    
    print_success "Adding gRPC location for $app_name to existing SSL server block"
    
    # Find the main server block (the one with listen 443 ssl) and add the location
    # Look for the server block that has listen 443 ssl and add before the closing brace
    sudo sed -i "/listen 443 ssl;/,/^}$/ {
        /^}$/ i\\
    # gRPC location for $app_name\\
    location /$app_name/ {\\
        grpc_pass grpc://127.0.0.1:$grpc_port;\\
        grpc_set_header Host \$host;\\
        grpc_set_header X-Real-IP \$remote_addr;\\
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\\
        grpc_set_header X-Forwarded-Proto \$scheme;\\
        \\
        # gRPC specific settings\\
        grpc_read_timeout 300;\\
        grpc_send_timeout 300;\\
        client_max_body_size 0;\\
        \\
        # Error handling for gRPC\\
        error_page 502 = @grpc_error;\\
    }\\

    }" "$ssl_cert_conf"
    
    # Also add the gRPC error handler if it doesn't exist
    if ! grep -q "@grpc_error" "$ssl_cert_conf"; then
        sudo sed -i "/listen 443 ssl;/,/^}$/ {
            /^}$/ i\\
    # gRPC error handler\\
    location @grpc_error {\\
        internal;\\
        default_type application/grpc;\\
        add_header grpc-status 14;\\
        add_header grpc-message \"Service Unavailable\";\\
        return 204;\\
    }\\

        }" "$ssl_cert_conf"
    fi
    
    return 0
}

# Check if SSL certificate exists and configure accordingly
ssl_available=false
if check_ssl_certificate; then
    ssl_available=true
    
    # Check if we already have an SSL server block from certificate generation
    if check_existing_ssl_server; then
        echo "Using existing SSL server configuration. Adding gRPC location..."
        
        # Add gRPC location to existing SSL server block
        if add_grpc_to_existing_ssl_config "$APP_NAME" "$GRPC_PORT"; then
            config_file_used="/etc/nginx-podman/conf.d/ssl-${CERT_NAME}.conf"
            protocol_used="HTTPS (existing server block)"
            
            # Remove any conflicting HTTP-only configuration
            if [ -f "$NGINX_CONF_FILE" ]; then
                print_warning "Removing HTTP-only configuration to avoid conflicts"
                sudo rm -f "$NGINX_CONF_FILE"
            fi
            
            # Remove any conflicting gRPC-SSL configuration
            if [ -f "$NGINX_SSL_CONF_FILE" ]; then
                print_warning "Removing separate gRPC SSL configuration to avoid conflicts"
                sudo rm -f "$NGINX_SSL_CONF_FILE"
            fi
        else
            print_error "Failed to add gRPC location to existing SSL configuration"
        fi
    else
        echo "SSL certificate found but no existing server block. Creating new HTTPS gRPC proxy..."
        
        # Create HTTPS gRPC configuration
        create_https_grpc_config
        
        # Add gRPC location to HTTPS config
        add_grpc_location "$NGINX_SSL_CONF_FILE" "HTTPS"
        
        # Set proper permissions for SSL config
        sudo chown root:root "$NGINX_SSL_CONF_FILE"
        sudo chmod 644 "$NGINX_SSL_CONF_FILE"
        
        # Remove any conflicting HTTP-only configuration
        if [ -f "$NGINX_CONF_FILE" ]; then
            print_warning "Removing HTTP-only configuration to avoid conflicts"
            sudo rm -f "$NGINX_CONF_FILE"
        fi
        
        config_file_used="$NGINX_SSL_CONF_FILE"
        protocol_used="HTTPS (new server block)"
    fi
else
    echo "SSL certificate not found. Configuring HTTP-only gRPC proxy..."
    
    # Create HTTP gRPC configuration
    create_http_grpc_config
    
    # Add gRPC location to HTTP config
    add_grpc_location "$NGINX_CONF_FILE" "HTTP"
    
    # Set proper permissions for HTTP config
    sudo chown root:root "$NGINX_CONF_FILE"
    sudo chmod 644 "$NGINX_CONF_FILE"
    
    config_file_used="$NGINX_CONF_FILE"
    protocol_used="HTTP"
fi

print_success "Added gRPC location for $APP_NAME to unified $protocol_used configuration"

# Clean up any old individual configuration files to prevent conflicts
OLD_CONF_FILE="${NGINX_CONF_DIR}/grpc-${APP_NAME}.conf"
if [ -f "$OLD_CONF_FILE" ]; then
    print_warning "Removing old individual config file: $OLD_CONF_FILE"
    sudo rm -f "$OLD_CONF_FILE"
fi

# Test NGINX configuration in container
echo "Testing NGINX configuration..."
if podman exec "$CONTAINER_NAME" nginx -t; then
    print_success "NGINX configuration test passed"
else
    print_error "NGINX configuration test failed"
fi

# Reload NGINX container
echo "Reloading NGINX container..."
if podman exec "$CONTAINER_NAME" nginx -s reload; then
    print_success "NGINX container reloaded successfully"
else
    print_error "Failed to reload NGINX container"
fi

# Show current gRPC services in the configuration
echo ""
echo "=== Current gRPC Services ==="
echo "Server IP: $IP_ADDRESS"
echo "Protocol: $protocol_used"
echo "Config File: $config_file_used"
echo "SSL Certificate: $CERT_NAME (available: $ssl_available)"
echo "Services configured:"

# Look for gRPC location blocks in the configuration file
if [ -f "$config_file_used" ]; then
    grep -o "location /[^/]*/\s" "$config_file_used" 2>/dev/null | sed 's/location \///g' | sed 's/\/.*//g' | sort | uniq | while read service; do
        if [ -n "$service" ] && [ "$service" != "grpc_502_error" ] && [ "$service" != "@grpc_error" ]; then
            echo "  - $service"
        fi
    done
else
    echo "  No configuration file found"
fi

echo ""
print_success "gRPC reverse proxy for $APP_NAME configured successfully!"
echo ""
if [ "$ssl_available" = true ]; then
    echo "Your gRPC service is now accessible at:"
    echo "  grpcs://$IP_ADDRESS:443/$APP_NAME/ (HTTPS/TLS)"
    echo "  grpc://$IP_ADDRESS:80/$APP_NAME/ (redirects to HTTPS)"
    echo ""
    echo "SSL/TLS Configuration:"
    echo "  - Certificate: ${NGINX_SSL_DIR}/${CERT_NAME}.crt"
    echo "  - Private Key: ${NGINX_SSL_DIR}/${CERT_NAME}.key"
    echo "  - Protocols: TLSv1.2, TLSv1.3"
    echo "  - HTTP requests are automatically redirected to HTTPS"
    echo ""
    echo "Testing with grpcurl:"
    echo "  # HTTPS (secure)"
    echo "  grpcurl -insecure $IP_ADDRESS:443 list"
    echo "  grpcurl -insecure -d '{\"data\":\"test\"}' $IP_ADDRESS:443 ServiceName/MethodName"
else
    echo "Your gRPC service is now accessible at:"
    echo "  grpc://$IP_ADDRESS:80/$APP_NAME/ (HTTP only)"
    echo ""
    echo "To enable SSL/TLS:"
    echo "  1. Run: sudo ./create_ssl_cert_ip.sh $IP_ADDRESS $CERT_NAME"
    echo "  2. Re-run this script: sudo $0 $IP_ADDRESS $APP_NAME $GRPC_PORT $CERT_NAME"
    echo ""
    echo "Testing with grpcurl:"
    echo "  # HTTP (insecure)"
    echo "  grpcurl -plaintext $IP_ADDRESS:80 list"
    echo "  grpcurl -plaintext -d '{\"data\":\"test\"}' $IP_ADDRESS:80 ServiceName/MethodName"
fi
echo ""
echo "All gRPC services share the same server block to avoid conflicts."
echo ""
echo "To remove this configuration:"
echo "  1. Edit $config_file_used"
echo "  2. Remove the location /$APP_NAME/ block"
echo "  3. Run: podman exec $CONTAINER_NAME nginx -s reload"

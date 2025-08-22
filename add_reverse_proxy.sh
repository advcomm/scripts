#!/bin/bash

# Minimal script to add reverse proxy to existing SSL server block
# Usage: ./add_reverse_proxy.sh <domain> <backend_port>

set -e

# Variables
DOMAIN="$1"
BACKEND_PORT="$2"
NGINX_CONF_DIR="/etc/nginx-podman/conf.d"
CONTAINER_NAME="nginx-server"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No color

# Logging functions
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

print_info() {
    echo -e "${BLUE}[ℹ] $1${NC}"
}

# Help function
show_help() {
    cat << EOF
Add Reverse Proxy to Existing SSL Server Block

Usage: $0 <domain> <backend_port>

Arguments:
  domain       - Domain name (e.g., api.xdoc.app)
  backend_port - Backend service port (e.g., 3000)

Examples:
  $0 api.xdoc.app 3000
  $0 app.example.com 8080

This script modifies existing SSL server configuration to add reverse proxy
to the root location (/), replacing the default static file serving.

Requirements:
  - Existing SSL server configuration (from gen_cert_aws.sh)
  - NGINX Podman container running
  - Backend service running on specified port
EOF
}

# Validate input
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

if [ -z "$DOMAIN" ] || [ -z "$BACKEND_PORT" ]; then
    echo "Usage: $0 <domain> <backend_port>"
    echo ""
    echo "Examples:"
    echo "  $0 api.xdoc.app 3000"
    echo "  $0 app.example.com 8080"
    echo ""
    echo "Use -h or --help for detailed information"
    exit 1
fi

# Validate port
if [[ ! "$BACKEND_PORT" =~ ^[0-9]+$ ]] || [ "$BACKEND_PORT" -lt 1 ] || [ "$BACKEND_PORT" -gt 65535 ]; then
    print_error "Invalid port number: $BACKEND_PORT (must be 1-65535)"
fi

print_info "Adding reverse proxy for $DOMAIN to port $BACKEND_PORT"

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    print_error "This script requires sudo privileges"
fi

# Check if NGINX container is running
if ! podman ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    print_error "NGINX container '${CONTAINER_NAME}' is not running"
fi

# Find the SSL configuration file
SSL_CONF_FILE="${NGINX_CONF_DIR}/ssl-${DOMAIN}.conf"

if [[ ! -f "$SSL_CONF_FILE" ]]; then
    print_error "SSL configuration file not found: $SSL_CONF_FILE"
    print_error "Please generate SSL certificate first: sudo ./gen_cert_aws.sh $DOMAIN"
fi

print_success "Found SSL configuration: $SSL_CONF_FILE"

# Test backend connectivity
print_info "Testing backend connectivity to localhost:$BACKEND_PORT..."
if command -v curl &>/dev/null; then
    if curl -s --connect-timeout 5 "http://localhost:$BACKEND_PORT" >/dev/null 2>&1; then
        print_success "Backend service is accessible on port $BACKEND_PORT"
    else
        print_warning "Backend service may not be running on port $BACKEND_PORT"
        print_warning "Make sure your application is running before testing"
    fi
else
    print_warning "curl not available, skipping backend test"
fi

# Backup the original configuration
BACKUP_FILE="${SSL_CONF_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
sudo cp "$SSL_CONF_FILE" "$BACKUP_FILE"
print_info "Backup created: $BACKUP_FILE"

# Replace the default location block with reverse proxy
print_info "Modifying SSL configuration to add reverse proxy..."

# Create a temporary file with the new configuration
TEMP_FILE=$(mktemp)

# Read the original file and replace the default location block
awk -v port="$BACKEND_PORT" '
BEGIN { in_default_location = 0; replaced = 0 }

# Detect start of default location block
/^[[:space:]]*# Default location/ {
    in_default_location = 1
    print "    # Reverse proxy to backend application"
    next
}

# Detect location / block start
/^[[:space:]]*location \/ \{/ && in_default_location {
    print "    location / {"
    print "        # Proxy settings"
    print "        proxy_pass http://127.0.0.1:" port ";"
    print "        proxy_http_version 1.1;"
    print "        proxy_set_header Upgrade $http_upgrade;"
    print "        proxy_set_header Connection \"upgrade\";"
    print "        proxy_set_header Host $host;"
    print "        proxy_set_header X-Real-IP $remote_addr;"
    print "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
    print "        proxy_set_header X-Forwarded-Proto https;"
    print "        proxy_set_header X-Forwarded-Host $server_name;"
    print ""
    print "        # Timeout settings"
    print "        proxy_connect_timeout 60s;"
    print "        proxy_send_timeout 60s;"
    print "        proxy_read_timeout 60s;"
    print ""
    print "        # Buffer settings"
    print "        proxy_buffering on;"
    print "        proxy_buffer_size 4k;"
    print "        proxy_buffers 8 4k;"
    print ""
    print "        # Client settings"
    print "        client_max_body_size 50M;"
    print "    }"
    
    # Skip until the end of the original location block
    while ((getline line) > 0) {
        if (line ~ /^[[:space:]]*\}[[:space:]]*$/) {
            break
        }
    }
    in_default_location = 0
    replaced = 1
    next
}

# Print all other lines as-is
{ print }

END {
    if (!replaced) {
        print "Warning: Default location block not found or not replaced" > "/dev/stderr"
    }
}
' "$SSL_CONF_FILE" > "$TEMP_FILE"

# Check if the modification was successful
if [[ $? -eq 0 ]] && [[ -s "$TEMP_FILE" ]]; then
    # Replace the original file with the modified version
    sudo cp "$TEMP_FILE" "$SSL_CONF_FILE"
    rm "$TEMP_FILE"
    print_success "SSL configuration updated with reverse proxy"
else
    rm -f "$TEMP_FILE"
    print_error "Failed to modify SSL configuration"
fi

# Add health check endpoint if not present
if ! grep -q "location /health" "$SSL_CONF_FILE"; then
    print_info "Adding health check endpoint..."
    
    # Add health check before the security section
    sudo sed -i '/# Security: Deny access to hidden files/i\
    # Health check endpoint\
    location /health {\
        proxy_pass http://127.0.0.1:'$BACKEND_PORT'/health;\
        proxy_http_version 1.1;\
        proxy_set_header Host $host;\
        proxy_set_header X-Real-IP $remote_addr;\
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\
        proxy_set_header X-Forwarded-Proto https;\
        \
        # Faster timeouts for health checks\
        proxy_connect_timeout 5s;\
        proxy_send_timeout 5s;\
        proxy_read_timeout 5s;\
    }\
    \
' "$SSL_CONF_FILE"
    
    print_success "Health check endpoint added"
fi

# Test NGINX configuration
print_info "Testing NGINX configuration..."
if podman exec "$CONTAINER_NAME" nginx -t; then
    print_success "NGINX configuration test passed"
else
    print_error "NGINX configuration test failed. Restoring backup..."
    sudo cp "$BACKUP_FILE" "$SSL_CONF_FILE"
    exit 1
fi

# Reload NGINX
print_info "Reloading NGINX..."
if podman exec "$CONTAINER_NAME" nginx -s reload; then
    print_success "NGINX reloaded successfully"
else
    print_error "Failed to reload NGINX. Restoring backup..."
    sudo cp "$BACKUP_FILE" "$SSL_CONF_FILE"
    podman exec "$CONTAINER_NAME" nginx -s reload
    exit 1
fi

# Show configuration summary
echo ""
echo "=== Reverse Proxy Configuration Complete ==="
echo "Domain: $DOMAIN"
echo "Backend Port: $BACKEND_PORT"
echo "SSL Config: $SSL_CONF_FILE"
echo "Backup: $BACKUP_FILE"

echo ""
print_success "Reverse proxy configured successfully!"
echo ""
echo "Your application is now accessible at:"
echo "  HTTPS: https://$DOMAIN"
echo "  Health Check: https://$DOMAIN/health"
echo ""
echo "Testing commands:"
echo "  curl -I https://$DOMAIN"
echo "  curl -I https://$DOMAIN/health"
echo ""
echo "View logs:"
echo "  podman exec $CONTAINER_NAME tail -f /var/log/nginx/access.log"
echo "  podman exec $CONTAINER_NAME tail -f /var/log/nginx/error.log"
echo ""
echo "To revert changes:"
echo "  sudo cp $BACKUP_FILE $SSL_CONF_FILE"
echo "  podman exec $CONTAINER_NAME nginx -s reload"

print_success "Configuration complete! Your reverse proxy is ready."

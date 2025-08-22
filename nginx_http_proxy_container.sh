#!/bin/bash

# Script to configure NGINX container for HTTP reverse proxy with SSL support
# Usage: ./nginx_http_proxy_container.sh <domain> <app_name> <http_port> [cert_name]

set -e

# Variables
DOMAIN="$1"
APP_NAME="$2"
HTTP_PORT="$3"
CERT_NAME="${4:-${DOMAIN}}"
NGINX_CONF_DIR="/etc/nginx-podman/conf.d"
NGINX_CONF_FILE="${NGINX_CONF_DIR}/http-proxy.conf"
NGINX_SSL_CONF_FILE="${NGINX_CONF_DIR}/http-ssl-proxy.conf"
NGINX_SSL_DIR="/etc/nginx-podman/ssl"
CONTAINER_NAME="nginx-server"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

print_info() {
    echo -e "${BLUE}[ℹ] $1${NC}"
}

check_command() {
    if ! command -v "$1" &>/dev/null; then
        print_error "$1 is not installed. Please install it first."
    fi
}

# Help function
show_help() {
    cat << EOF
HTTP Reverse Proxy Configuration for NGINX Podman

Usage: $0 <domain> <app_name> <http_port> [cert_name]

Arguments:
  domain      - Domain name (e.g., api.example.com)
  app_name    - Application name for location path
  http_port   - Backend HTTP service port
  cert_name   - SSL certificate name (optional, defaults to domain)

Examples:
  $0 api.example.com myapi 3000
  $0 app.mydomain.com webapp 8080 mydomain.com
  $0 subdomain.example.com service 5000

Features:
  - HTTP reverse proxy with SSL termination
  - Automatic SSL detection and configuration
  - Load balancing ready
  - WebSocket support
  - Security headers
  - Caching configuration
  - Integrates with install_nginx_podman.sh infrastructure

SSL Certificate:
  If SSL certificate exists, HTTPS proxy will be configured
  If no SSL certificate, HTTP-only proxy will be configured
  Generate SSL certificate first: sudo ./gen_cert_aws.sh <domain>

Requirements:
  - NGINX Podman container running (from install_nginx_podman.sh)
  - Backend service running on specified port
  - SSL certificate (optional, for HTTPS)

Output:
  - NGINX configuration in /etc/nginx-podman/conf.d/
  - Access logs in /var/log/nginx-podman/
  - Service accessible via domain name
EOF
}

# Validate input
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

if [ -z "$DOMAIN" ] || [ -z "$APP_NAME" ] || [ -z "$HTTP_PORT" ]; then
    echo "Usage: $0 <domain> <app_name> <http_port> [cert_name]"
    echo ""
    echo "Arguments:"
    echo "  domain      - Domain name (e.g., api.example.com)"
    echo "  app_name    - Application name for location path"
    echo "  http_port   - Backend HTTP service port"
    echo "  cert_name   - SSL certificate name (optional, defaults to domain)"
    echo ""
    echo "Examples:"
    echo "  $0 api.example.com myapi 3000"
    echo "  $0 app.mydomain.com webapp 8080 mydomain.com"
    echo ""
    echo "SSL Certificate:"
    echo "  If SSL certificate exists, HTTPS proxy will be configured"
    echo "  If no SSL certificate, HTTP-only proxy will be configured"
    echo "  Generate SSL certificate first: sudo ./gen_cert_aws.sh <domain>"
    echo ""
    echo "Use -h or --help for detailed information"
    exit 1
fi

# Validate domain format
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        print_error "Invalid domain format: $domain"
    fi
}

# Validate port
validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        print_error "Invalid port number: $port (must be 1-65535)"
    fi
}

# Validate app name
validate_app_name() {
    local app="$1"
    if [[ ! "$app" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        print_error "Invalid app name: $app (only alphanumeric, underscore, and dash allowed)"
    fi
}

print_info "Starting HTTP reverse proxy configuration..."
print_info "Domain: $DOMAIN"
print_info "App Name: $APP_NAME"
print_info "Backend Port: $HTTP_PORT"
print_info "Certificate Name: $CERT_NAME"

# Validate inputs
validate_domain "$DOMAIN"
validate_port "$HTTP_PORT"
validate_app_name "$APP_NAME"

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
        print_warning "Run gen_cert_aws.sh first to generate SSL certificate"
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

# Function to test backend connectivity
test_backend() {
    print_info "Testing backend connectivity to localhost:$HTTP_PORT..."
    
    if command -v curl &>/dev/null; then
        if curl -s --connect-timeout 5 "http://localhost:$HTTP_PORT" >/dev/null 2>&1; then
            print_success "Backend service is accessible on port $HTTP_PORT"
        else
            print_warning "Backend service may not be running on port $HTTP_PORT"
            print_warning "Make sure your application is running before testing the proxy"
        fi
    else
        print_warning "curl not available, skipping backend connectivity test"
    fi
}

# Function to create HTTP proxy configuration
create_http_proxy_config() {
    print_info "Creating HTTP reverse proxy configuration..."
    
    cat << EOF | sudo tee "${NGINX_CONF_DIR}/http-${APP_NAME}.conf" > /dev/null
# HTTP reverse proxy configuration for ${APP_NAME} (${DOMAIN})
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    
    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # Logging
    access_log /var/log/nginx/${APP_NAME}_access.log;
    error_log /var/log/nginx/${APP_NAME}_error.log;
    
    # Main application location
    location / {
        # Proxy settings
        proxy_pass http://127.0.0.1:${HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        
        # Timeout settings
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # Buffer settings
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
        proxy_busy_buffers_size 8k;
        
        # Cache control
        proxy_cache_bypass \$http_upgrade;
        
        # Client settings
        client_max_body_size 50M;
        client_body_timeout 60s;
        client_header_timeout 60s;
    }
    
    # Health check endpoint
    location /health {
        proxy_pass http://127.0.0.1:${HTTP_PORT}/health;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Faster timeouts for health checks
        proxy_connect_timeout 5s;
        proxy_send_timeout 5s;
        proxy_read_timeout 5s;
    }
    
    # Static assets (if any)
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        proxy_pass http://127.0.0.1:${HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        
        # Cache static assets
        expires 1y;
        add_header Cache-Control "public, immutable";
        
        # Gzip compression
        gzip_static on;
    }
    
    # Security: Deny access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    # Security: Deny access to backup and config files
    location ~* \.(bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist)\$ {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF
    
    print_success "HTTP proxy configuration created for $APP_NAME"
}

# Function to create HTTPS proxy configuration
create_https_proxy_config() {
    print_info "Creating HTTPS reverse proxy configuration..."
    
    cat << EOF | sudo tee "${NGINX_CONF_DIR}/https-${APP_NAME}.conf" > /dev/null
# HTTPS reverse proxy configuration for ${APP_NAME} (${DOMAIN})
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};
    
    # SSL Certificate Configuration
    ssl_certificate /etc/nginx/ssl/${CERT_NAME}.crt;
    ssl_certificate_key /etc/nginx/ssl/${CERT_NAME}.key;
    
    # Modern SSL Configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/nginx/ssl/${CERT_NAME}.crt;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Content-Security-Policy "default-src 'self'" always;
    
    # Logging
    access_log /var/log/nginx/${APP_NAME}_ssl_access.log;
    error_log /var/log/nginx/${APP_NAME}_ssl_error.log;
    
    # Main application location
    location / {
        # Proxy settings
        proxy_pass http://127.0.0.1:${HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$server_name;
        proxy_set_header X-Forwarded-Ssl on;
        
        # Timeout settings
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # Buffer settings
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
        proxy_busy_buffers_size 8k;
        
        # Cache control
        proxy_cache_bypass \$http_upgrade;
        
        # Client settings
        client_max_body_size 50M;
        client_body_timeout 60s;
        client_header_timeout 60s;
    }
    
    # Health check endpoint
    location /health {
        proxy_pass http://127.0.0.1:${HTTP_PORT}/health;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        
        # Faster timeouts for health checks
        proxy_connect_timeout 5s;
        proxy_send_timeout 5s;
        proxy_read_timeout 5s;
    }
    
    # API endpoints (if any)
    location /api/ {
        proxy_pass http://127.0.0.1:${HTTP_PORT}/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        
        # API-specific settings
        proxy_connect_timeout 30s;
        proxy_send_timeout 30s;
        proxy_read_timeout 30s;
        
        # CORS headers (if needed)
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-Requested-With" always;
        
        # Handle preflight requests
        if (\$request_method = 'OPTIONS') {
            add_header Access-Control-Allow-Origin "*";
            add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS";
            add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-Requested-With";
            add_header Content-Length 0;
            add_header Content-Type text/plain;
            return 200;
        }
    }
    
    # Static assets (if any)
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        proxy_pass http://127.0.0.1:${HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        
        # Cache static assets
        expires 1y;
        add_header Cache-Control "public, immutable";
        
        # Gzip compression
        gzip_static on;
    }
    
    # Security: Deny access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    # Security: Deny access to backup and config files
    location ~* \.(bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist)\$ {
        deny all;
        access_log off;
        log_not_found off;
    }
}

# HTTP to HTTPS redirect for ${DOMAIN}
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    
    # ACME challenge location (for certificate renewals)
    location /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        try_files \$uri =404;
    }
    
    # Redirect all other traffic to HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}
EOF
    
    print_success "HTTPS proxy configuration created for $APP_NAME"
}

# Function to add HTTP location to existing SSL configuration
add_http_to_existing_ssl_config() {
    local ssl_cert_conf="/etc/nginx-podman/conf.d/ssl-${CERT_NAME}.conf"
    local app_name="$1"
    local http_port="$2"
    local domain="$3"
    
    # Check if this app location already exists in the SSL config
    if grep -q "location /${app_name}/" "$ssl_cert_conf"; then
        print_error "Configuration for $app_name already exists in $ssl_cert_conf"
        return 1
    fi
    
    print_success "Adding HTTP proxy location for $app_name to existing SSL server block"
    
    # Add server name if not present
    if ! grep -q "server_name.*${domain}" "$ssl_cert_conf"; then
        sudo sed -i "/server_name /s/;/ ${domain};/" "$ssl_cert_conf"
    fi
    
    # Find the main server block (the one with listen 443 ssl) and add the location
    sudo sed -i "/listen 443 ssl;/,/^}$/ {
        /^}$/ i\\
    # HTTP proxy location for $app_name\\
    location /${app_name}/ {\\
        proxy_pass http://127.0.0.1:${http_port}/;\\
        proxy_http_version 1.1;\\
        proxy_set_header Upgrade \$http_upgrade;\\
        proxy_set_header Connection 'upgrade';\\
        proxy_set_header Host \$host;\\
        proxy_set_header X-Real-IP \$remote_addr;\\
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\\
        proxy_set_header X-Forwarded-Proto https;\\
        proxy_set_header X-Forwarded-Host \$server_name;\\
        \\
        # Timeout settings\\
        proxy_connect_timeout 60s;\\
        proxy_send_timeout 60s;\\
        proxy_read_timeout 60s;\\
        \\
        # Client settings\\
        client_max_body_size 50M;\\
    }\\

    }" "$ssl_cert_conf"
    
    return 0
}

# Test backend connectivity
test_backend

# Check if SSL certificate exists and configure accordingly
ssl_available=false
if check_ssl_certificate; then
    ssl_available=true
    
    # Check if we already have an SSL server block from certificate generation
    if check_existing_ssl_server; then
        echo "Using existing SSL server configuration. Adding HTTP proxy location..."
        
        # Add HTTP proxy location to existing SSL server block
        if add_http_to_existing_ssl_config "$APP_NAME" "$HTTP_PORT" "$DOMAIN"; then
            config_file_used="/etc/nginx-podman/conf.d/ssl-${CERT_NAME}.conf"
            protocol_used="HTTPS (existing server block)"
        else
            print_error "Failed to add HTTP proxy location to existing SSL configuration"
        fi
    else
        echo "SSL certificate found but no existing server block. Creating new HTTPS proxy..."
        
        # Create HTTPS proxy configuration
        create_https_proxy_config
        
        config_file_used="${NGINX_CONF_DIR}/https-${APP_NAME}.conf"
        protocol_used="HTTPS (new configuration)"
    fi
else
    echo "SSL certificate not found. Configuring HTTP-only proxy..."
    
    # Create HTTP proxy configuration
    create_http_proxy_config
    
    config_file_used="${NGINX_CONF_DIR}/http-${APP_NAME}.conf"
    protocol_used="HTTP"
fi

# Set proper permissions
sudo chown root:root "$config_file_used"
sudo chmod 644 "$config_file_used"

print_success "HTTP reverse proxy for $APP_NAME configured with $protocol_used"

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

# Show configuration summary
echo ""
echo "=== HTTP Reverse Proxy Configuration Summary ==="
echo "Domain: $DOMAIN"
echo "Application: $APP_NAME"
echo "Backend Port: $HTTP_PORT"
echo "Protocol: $protocol_used"
echo "Config File: $config_file_used"
echo "SSL Certificate: $CERT_NAME (available: $ssl_available)"

echo ""
print_success "HTTP reverse proxy for $APP_NAME configured successfully!"
echo ""

if [ "$ssl_available" = true ]; then
    echo "Your application is now accessible at:"
    echo "  HTTPS: https://$DOMAIN"
    echo "  HTTP: http://$DOMAIN (redirects to HTTPS)"
    echo ""
    echo "SSL/TLS Configuration:"
    echo "  - Certificate: ${NGINX_SSL_DIR}/${CERT_NAME}.crt"
    echo "  - Private Key: ${NGINX_SSL_DIR}/${CERT_NAME}.key"
    echo "  - Protocols: TLSv1.2, TLSv1.3"
    echo "  - HSTS enabled with preload"
    echo ""
    echo "Testing commands:"
    echo "  curl -I https://$DOMAIN"
    echo "  curl -I https://$DOMAIN/health"
    echo "  curl -I https://$DOMAIN/api/"
else
    echo "Your application is now accessible at:"
    echo "  HTTP: http://$DOMAIN"
    echo ""
    echo "To enable SSL/TLS:"
    echo "  1. Run: sudo ./gen_cert_aws.sh $DOMAIN"
    echo "  2. Re-run this script: sudo $0 $DOMAIN $APP_NAME $HTTP_PORT"
    echo ""
    echo "Testing commands:"
    echo "  curl -I http://$DOMAIN"
    echo "  curl -I http://$DOMAIN/health"
    echo "  curl -I http://$DOMAIN/api/"
fi

echo ""
echo "=== Log Files ==="
if [ "$ssl_available" = true ]; then
    echo "  Access Log: /var/log/nginx-podman/${APP_NAME}_ssl_access.log"
    echo "  Error Log: /var/log/nginx-podman/${APP_NAME}_ssl_error.log"
else
    echo "  Access Log: /var/log/nginx-podman/${APP_NAME}_access.log"
    echo "  Error Log: /var/log/nginx-podman/${APP_NAME}_error.log"
fi

echo ""
echo "=== Management Commands ==="
echo "  View logs: podman exec $CONTAINER_NAME tail -f /var/log/nginx/${APP_NAME}*.log"
echo "  Test config: podman exec $CONTAINER_NAME nginx -t"
echo "  Reload: podman exec $CONTAINER_NAME nginx -s reload"
echo "  Remove config: sudo rm $config_file_used && podman exec $CONTAINER_NAME nginx -s reload"

echo ""
echo "=== Features Enabled ==="
echo "  ✅ HTTP/2 support (HTTPS only)"
echo "  ✅ WebSocket support"
echo "  ✅ Static asset caching"
echo "  ✅ Security headers"
echo "  ✅ CORS support (API endpoints)"
echo "  ✅ Health check endpoint"
echo "  ✅ Gzip compression"
echo "  ✅ File upload support (50MB limit)"

print_success "Configuration complete! Your HTTP reverse proxy is ready."

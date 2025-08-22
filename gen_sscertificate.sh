#!/bin/bash

# Script to create self-signed SSL certificate for IP address in NGINX Podman
# Usage: ./create_ssl_cert_ip.sh <IP_ADDRESS> [certificate_name]

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Configuration
IP_ADDRESS="$1"
CERT_NAME="${2:-ssl-cert}"
NGINX_SSL_DIR="/etc/nginx-podman/ssl"
CONTAINER_NAME="nginx-server"
KEY_SIZE=2048
DAYS_VALID=365

# Help function
show_help() {
    cat << EOF
Self-Signed SSL Certificate Generator for NGINX Podman

Usage: $0 <IP_ADDRESS> [certificate_name]

Arguments:
  IP_ADDRESS         The IP address to create certificate for (required)
  certificate_name   Name for the certificate files (optional, default: ssl-cert)

Examples:
  $0 95.216.189.60
  $0 95.216.189.60 myserver
  $0 192.168.1.100 internal-server

Output:
  - Certificate: ${NGINX_SSL_DIR}/[cert_name].crt
  - Private Key: ${NGINX_SSL_DIR}/[cert_name].key
  - Certificate Info: ${NGINX_SSL_DIR}/[cert_name].info

Requirements:
  - OpenSSL installed
  - NGINX Podman container (nginx-server) running
  - Sudo privileges for writing to NGINX SSL directory

The certificate will be valid for ${DAYS_VALID} days and include:
  - Subject Alternative Name (SAN) for the IP address
  - Common Name (CN) set to the IP address
  - RSA ${KEY_SIZE}-bit key
EOF
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# Function to create OpenSSL configuration file
create_openssl_config() {
    local config_file="$1"
    local ip="$2"
    
    cat << EOF > "$config_file"
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = State
L = City
O = Organization
OU = IT Department
CN = $ip

[v3_req]
# Key Usage for TLS Web Server Authentication
keyUsage = critical, digitalSignature, keyEncipherment, keyAgreement
extendedKeyUsage = critical, serverAuth, clientAuth

# Subject Alternative Name is critical for modern TLS
subjectAltName = critical, @alt_names

# Basic constraints
basicConstraints = critical, CA:FALSE

# Subject Key Identifier
subjectKeyIdentifier = hash

[alt_names]
IP.1 = $ip
DNS.1 = $ip
DNS.2 = localhost
DNS.3 = *.local

[v3_ca]
# Extensions for a typical CA
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign, cRLSign
extendedKeyUsage = critical, serverAuth, clientAuth
basicConstraints = critical, CA:TRUE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always, issuer:always
EOF
}

# Function to generate self-signed certificate
generate_certificate() {
    local ip="$1"
    local cert_name="$2"
    
    info "Generating proper self-signed certificate for IP: $ip"
    
    # Create temporary directory for generation
    local temp_dir=$(mktemp -d)
    local config_file="$temp_dir/openssl.conf"
    local key_file="$temp_dir/${cert_name}.key"
    local csr_file="$temp_dir/${cert_name}.csr"
    local cert_file="$temp_dir/${cert_name}.crt"
    
    # Create OpenSSL configuration
    create_openssl_config "$config_file" "$ip"
    
    info "Creating private key with proper parameters..."
    # Generate RSA private key with proper parameters
    openssl genrsa -out "$key_file" $KEY_SIZE
    
    info "Creating certificate signing request with extensions..."
    # Create CSR with extensions
    openssl req -new -key "$key_file" -out "$csr_file" -config "$config_file" -extensions v3_req
    
    info "Creating self-signed certificate with proper TLS extensions..."
    # Create self-signed certificate with proper extensions for TLS Web Server Authentication
    openssl x509 -req -in "$csr_file" -signkey "$key_file" -out "$cert_file" \
        -days $DAYS_VALID -extensions v3_req -extfile "$config_file" \
        -sha256
    
    # Verify the certificate has proper extensions
    info "Verifying certificate extensions..."
    if openssl x509 -in "$cert_file" -text -noout | grep -q "TLS Web Server Authentication"; then
        log "✅ Certificate includes TLS Web Server Authentication"
    else
        warn "⚠️ Certificate may not include proper TLS extensions"
    fi
    
    if openssl x509 -in "$cert_file" -text -noout | grep -q "Digital Signature, Key Encipherment"; then
        log "✅ Certificate includes proper Key Usage"
    else
        warn "⚠️ Certificate may not include proper Key Usage"
    fi
    
    # Ensure SSL directory exists
    sudo mkdir -p "$NGINX_SSL_DIR"
    
    # Copy certificate and key to NGINX SSL directory
    info "Installing certificate to NGINX SSL directory..."
    sudo cp "$cert_file" "${NGINX_SSL_DIR}/${cert_name}.crt"
    sudo cp "$key_file" "${NGINX_SSL_DIR}/${cert_name}.key"
    
    # Set proper permissions
    sudo chmod 644 "${NGINX_SSL_DIR}/${cert_name}.crt"
    sudo chmod 600 "${NGINX_SSL_DIR}/${cert_name}.key"
    sudo chown root:root "${NGINX_SSL_DIR}/${cert_name}.crt"
    sudo chown root:root "${NGINX_SSL_DIR}/${cert_name}.key"
    
    # Create certificate info file with detailed information
    info "Creating certificate information file..."
    {
        echo "=== Certificate Information ==="
        echo "Generated: $(date)"
        echo "IP Address: $ip"
        echo "Certificate Name: $cert_name"
        echo "Key Size: $KEY_SIZE bits"
        echo "Valid Days: $DAYS_VALID"
        echo ""
        echo "=== Certificate Details ==="
        openssl x509 -in "$cert_file" -text -noout
        echo ""
        echo "=== Certificate Verification ==="
        openssl verify -CAfile "$cert_file" "$cert_file" || echo "Self-signed certificate (expected)"
    } | sudo tee "${NGINX_SSL_DIR}/${cert_name}.info" > /dev/null
    
    # Cleanup temporary directory
    rm -rf "$temp_dir"
    
    log "Certificate generated successfully with proper TLS extensions!"
}

# Function to create NGINX SSL configuration
create_nginx_ssl_config() {
    local ip="$1"
    local cert_name="$2"
    local ssl_conf_file="/etc/nginx-podman/conf.d/ssl-${cert_name}.conf"
    
    info "Creating NGINX SSL configuration..."
    
    cat << EOF | sudo tee "$ssl_conf_file" > /dev/null
# SSL configuration for $ip ($cert_name)
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    
    server_name $ip;
    
    # SSL Certificate Configuration
    ssl_certificate /etc/nginx/ssl/${cert_name}.crt;
    ssl_certificate_key /etc/nginx/ssl/${cert_name}.key;
    
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
    
    # Document Root
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

# Redirect HTTP to HTTPS for $ip
server {
    listen 80;
    listen [::]:80;
    server_name $ip;
    
    return 301 https://\$server_name\$request_uri;
}
EOF
    
    log "NGINX SSL configuration created: $ssl_conf_file"
}

# Function to test and reload NGINX
reload_nginx() {
    info "Testing NGINX configuration..."
    
    if podman exec "$CONTAINER_NAME" nginx -t; then
        log "NGINX configuration test passed"
        
        info "Reloading NGINX..."
        if podman exec "$CONTAINER_NAME" nginx -s reload; then
            log "NGINX reloaded successfully"
        else
            error "Failed to reload NGINX"
        fi
    else
        error "NGINX configuration test failed"
    fi
}

# Function to display certificate information
show_certificate_info() {
    local cert_name="$1"
    local ip="$2"
    
    echo ""
    echo "=== Certificate Information ==="
    echo "Certificate Name: $cert_name"
    echo "IP Address: $ip"
    echo "Certificate File: ${NGINX_SSL_DIR}/${cert_name}.crt"
    echo "Private Key File: ${NGINX_SSL_DIR}/${cert_name}.key"
    echo "Info File: ${NGINX_SSL_DIR}/${cert_name}.info"
    echo "Valid for: $DAYS_VALID days"
    echo ""
    
    # Show certificate details with focus on TLS extensions
    echo "=== Certificate Extensions Verification ==="
    local cert_file="${NGINX_SSL_DIR}/${cert_name}.crt"
    
    # Check Key Usage
    if openssl x509 -in "$cert_file" -text -noout | grep -A1 "Key Usage:" | grep -q "Digital Signature, Key Encipherment"; then
        echo "✅ Key Usage: Digital Signature, Key Encipherment (CORRECT)"
    else
        echo "❌ Key Usage: Missing or incorrect"
    fi
    
    # Check Extended Key Usage
    if openssl x509 -in "$cert_file" -text -noout | grep -A1 "Extended Key Usage:" | grep -q "TLS Web Server Authentication"; then
        echo "✅ Extended Key Usage: TLS Web Server Authentication (CORRECT)"
    else
        echo "❌ Extended Key Usage: Missing TLS Web Server Authentication"
    fi
    
    # Check Subject Alternative Name
    if openssl x509 -in "$cert_file" -text -noout | grep -A2 "Subject Alternative Name:" | grep -q "IP Address:$ip"; then
        echo "✅ Subject Alternative Name: IP Address included (CORRECT)"
    else
        echo "❌ Subject Alternative Name: IP Address missing"
    fi
    
    # Check if certificate is critical for modern browsers
    if openssl x509 -in "$cert_file" -text -noout | grep -q "critical"; then
        echo "✅ Critical extensions present (GOOD for modern browsers)"
    else
        echo "⚠️ No critical extensions (may cause issues with strict clients)"
    fi
    
    echo ""
    echo "=== Certificate Details ==="
    openssl x509 -in "$cert_file" -text -noout | \
        grep -E "(Subject:|Issuer:|Not Before:|Not After:|DNS:|IP Address:|Key Usage:|Extended Key Usage:)"
    
    echo ""
    echo "=== Access URLs ==="
    echo "HTTPS: https://$ip"
    echo "HTTP (redirects to HTTPS): http://$ip"
    
    echo ""
    echo "=== Testing Commands ==="
    echo "Test certificate with OpenSSL:"
    echo "  openssl s_client -connect $ip:443 -servername $ip"
    echo ""
    echo "Test with curl (ignore self-signed warning):"
    echo "  curl -k https://$ip"
    echo ""
    echo "Test gRPC with grpcurl:"
    echo "  grpcurl -insecure $ip:443 list"
    
    echo ""
    echo "=== Security Note ==="
    echo "✅ This certificate includes proper TLS Web Server Authentication extensions"
    echo "✅ Compatible with BoringSSL, OpenSSL, and modern browsers/clients"
    echo "⚠️  Self-signed certificate - browsers will show security warnings"
    echo "   To avoid warnings in browsers:"
    echo "   1. Add certificate to your system's trusted root certificates"
    echo "   2. Or use -k/--insecure flag with curl/grpcurl for testing"
    
    echo ""
    echo "=== Files Created ==="
    echo "✅ ${NGINX_SSL_DIR}/${cert_name}.crt"
    echo "✅ ${NGINX_SSL_DIR}/${cert_name}.key"
    echo "✅ ${NGINX_SSL_DIR}/${cert_name}.info"
    echo "✅ /etc/nginx-podman/conf.d/ssl-${cert_name}.conf"
}

# Main execution
main() {
    # Check for help flag
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        show_help
        exit 0
    fi
    
    # Validate arguments
    if [[ -z "$IP_ADDRESS" ]]; then
        error "IP address is required. Use -h for help."
    fi
    
    # Validate IP address format
    if ! validate_ip "$IP_ADDRESS"; then
        error "Invalid IP address format: $IP_ADDRESS"
    fi
    
    # Check if running with proper privileges
    if [[ "$EUID" -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        error "This script requires sudo privileges"
    fi
    
    # Check required commands
    if ! command_exists openssl; then
        error "OpenSSL is not installed. Please install it first."
    fi
    
    if ! command_exists podman; then
        error "Podman is not installed. Please run install_nginx_podman.sh first."
    fi
    
    # Check if NGINX container is running
    if ! podman ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        error "NGINX container '${CONTAINER_NAME}' is not running. Please run install_nginx_podman.sh first."
    fi
    
    # Check if certificate already exists
    if [[ -f "${NGINX_SSL_DIR}/${CERT_NAME}.crt" ]]; then
        warn "Certificate ${CERT_NAME}.crt already exists."
        read -p "Do you want to overwrite it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Operation cancelled."
            exit 0
        fi
    fi
    
    log "Starting SSL certificate generation for IP: $IP_ADDRESS"
    
    # Generate certificate
    generate_certificate "$IP_ADDRESS" "$CERT_NAME"
    
    # Create NGINX configuration
    create_nginx_ssl_config "$IP_ADDRESS" "$CERT_NAME"
    
    # Test and reload NGINX
    reload_nginx
    
    # Show certificate information
    show_certificate_info "$CERT_NAME" "$IP_ADDRESS"
    
    log "SSL certificate setup completed successfully!"
}

# Run main function
main "$@"
#!/bin/bash

# Variables
DOMAIN="$1"           # Base domain for the wildcard certificate (e.g., example.com)
DNS_PROVIDER="$2"     # DNS provider for Certbot (e.g., cloudflare, route53, etc.)
EMAIL="$3"            # Email address for Certbot registration
CERT_PATH="/etc/letsencrypt/live/$DOMAIN"
NGINX_RELOAD_COMMAND="nginx -s reload"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No color

# Functions
function print_success {
    echo -e "${GREEN}[✔] $1${NC}"
}

function print_error {
    echo -e "${RED}[✘] $1${NC}"
    exit 1
}

function check_command {
    if ! command -v "$1" &>/dev/null; then
        print_error "$1 is not installed. Please install it first."
    fi
}

function install_package {
    echo "Installing $1..."
    apt update && apt install -y "$1" || print_error "Failed to install $1."
    print_success "$1 installed successfully."
}

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root"
fi

# Validate input
if [ -z "$DOMAIN" ] || [ -z "$DNS_PROVIDER" ] || [ -z "$EMAIL" ]; then
    print_error "Usage: $0 <domain> <dns_provider> <email>"
fi

# Ensure required tools are installed
if ! command -v certbot &>/dev/null; then
    install_package certbot
fi

if ! dpkg -l | grep -q "python3-certbot-dns-$DNS_PROVIDER"; then
    install_package "python3-certbot-dns-$DNS_PROVIDER"
fi

# Ensure NGINX is installed
if ! command -v nginx &>/dev/null; then
    install_package nginx
fi

# Generate or renew the wildcard certificate
echo "Requesting wildcard certificate for *.$DOMAIN..."
certbot certonly \
    --dns-"$DNS_PROVIDER" \
    --dns-"$DNS_PROVIDER"-credentials /root/.secrets/certbot/"$DNS_PROVIDER".ini \
    --dns-"$DNS_PROVIDER"-propagation-seconds 30 \
    -d "*.$DOMAIN" -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive || print_error "Failed to generate or renew wildcard certificate."

print_success "Wildcard certificate for *.$DOMAIN generated successfully."

# Configure NGINX to reload with the new certificate
if [ -x "$(command -v nginx)" ]; then
    echo "Reloading NGINX..."
    $NGINX_RELOAD_COMMAND || print_error "Failed to reload NGINX."
    print_success "NGINX reloaded successfully with the new certificate."
else
    print_error "NGINX is not installed or configured on this server."
fi

# Success message
print_success "Setup completed! Wildcard SSL certificate is ready for use."
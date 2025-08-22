#!/bin/bash

# Enhanced SSL Certificate Generator for NGINX Podman with Let's Encrypt
# Compatible with install_nginx_podman.sh infrastructure
# Usage: ./generate_domain_certificate.sh <domain.com> [email] [--staging]

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DOMAIN="$1"
EMAIL="${2:-admin@${DOMAIN}}"
STAGING_FLAG="$3"
NGINX_SSL_DIR="/etc/nginx-podman/ssl"
NGINX_CONF_DIR="/etc/nginx-podman/conf.d"
CONTAINER_NAME="nginx-server"
WEBROOT_DIR="/var/www/html-podman"
CERTBOT_DIR="/etc/letsencrypt"
LOG_FILE="/var/log/certbot-$(date +%Y%m%d-%H%M%S).log"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Help function
show_help() {
    cat << EOF
Enhanced SSL Certificate Generator for NGINX Podman

Usage: $0 <domain.com> [email] [--staging]

Arguments:
  domain.com     The domain name for the certificate (required)
  email          Email for Let's Encrypt registration (optional, defaults to admin@domain.com)
  --staging      Use Let's Encrypt staging environment for testing (optional)

Examples:
  $0 example.com
  $0 example.com admin@example.com
  $0 test.example.com admin@example.com --staging

Features:
  - Generates Let's Encrypt SSL certificates
  - Creates wildcard certificates (*.domain.com + domain.com)
  - Integrates with NGINX Podman container from install_nginx_podman.sh
  - Automatic NGINX configuration with SSL
  - Sets up certificate auto-renewal
  - Supports both staging and production environments

Requirements:
  - NGINX Podman container running (from install_nginx_podman.sh)
  - Domain pointing to this server
  - AWS CLI configured (for Route53 DNS validation)
  - Port 80/443 accessible from internet

Output:
  - SSL certificates in ${NGINX_SSL_DIR}/
  - NGINX SSL configuration in ${NGINX_CONF_DIR}/
  - Automatic certificate renewal setup
EOF
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to validate domain
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_error "Invalid domain format: $domain"
        exit 1
    fi
}

# Function to validate email
validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log_error "Invalid email format: $email"
        exit 1
    fi
}

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if domain argument is provided
    if [[ -z "$DOMAIN" ]]; then
        log_error "Domain name is required"
        show_help
        exit 1
    fi
    
    # Validate domain and email
    validate_domain "$DOMAIN"
    validate_email "$EMAIL"
    
    # Check if running with proper privileges
    if [[ "$EUID" -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        log_error "This script requires sudo privileges"
        exit 1
    fi
    
    # Check if NGINX Podman container exists
    if ! podman ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        log_error "NGINX container '${CONTAINER_NAME}' not found!"
        log_error "Please run install_nginx_podman.sh first to set up the NGINX container."
        exit 1
    fi
    
    # Check if NGINX directories exist (from install_nginx_podman.sh)
    if [[ ! -d "$NGINX_SSL_DIR" ]] || [[ ! -d "$NGINX_CONF_DIR" ]]; then
        log_error "NGINX Podman directories not found!"
        log_error "Please run install_nginx_podman.sh first to set up the directory structure."
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Function to install required packages
install_dependencies() {
    log_info "Installing required dependencies..."
    
    # Update package list
    sudo apt-get update
    
    # Install AWS CLI if not present
    if ! command_exists aws; then
        log_info "Installing AWS CLI v2..."
        
        # Install prerequisites for AWS CLI
        sudo apt-get install -y curl unzip
        
        # Download and install AWS CLI v2
        cd /tmp
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip -q awscliv2.zip
        sudo ./aws/install
        
        # Clean up
        rm -rf awscliv2.zip aws/
        
        # Verify installation
        if command_exists aws; then
            log_success "AWS CLI v2 installed successfully"
            aws --version
        else
            log_error "AWS CLI installation failed"
            exit 1
        fi
    else
        log_info "AWS CLI already installed: $(aws --version)"
    fi
    
    # Install Certbot if not present
    if ! command_exists certbot; then
        log_info "Installing Certbot..."
        sudo apt-get install -y certbot
    fi
    
    # Install Certbot Route53 plugin
    if ! dpkg -l | grep -q "python3-certbot-dns-route53"; then
        log_info "Installing Certbot Route53 plugin..."
        sudo apt-get install -y python3-certbot-dns-route53
    fi
    
    log_success "Dependencies installed successfully"
}

# Function to check AWS credentials
check_aws_credentials() {
    log_info "Checking AWS credentials for Route53 DNS validation..."
    
    if [[ ! -f "$HOME/.aws/credentials" ]]; then
        log_error "AWS credentials not found at ~/.aws/credentials"
        log_error "Please configure AWS credentials with Route53 permissions:"
        echo "  aws configure"
        echo "Or create ~/.aws/credentials with:"
        echo "[default]"
        echo "aws_access_key_id = YOUR_ACCESS_KEY"
        echo "aws_secret_access_key = YOUR_SECRET_KEY"
        exit 1
    fi
    
    # Test AWS access
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS credentials are not working. Please check your configuration."
        exit 1
    fi
    
    log_success "AWS credentials verified"
}

# Function to create temporary NGINX configuration for challenge
create_challenge_config() {
    log_info "Creating temporary NGINX configuration for ACME challenge..."
    
    cat << EOF | sudo tee "${NGINX_CONF_DIR}/temp-${DOMAIN}.conf" > /dev/null
# Temporary configuration for ACME challenge - ${DOMAIN}
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} *.${DOMAIN};
    
    # ACME challenge location
    location /.well-known/acme-challenge/ {
        root ${WEBROOT_DIR};
        try_files \$uri =404;
    }
    
    # Redirect everything else to HTTPS (after certificate is obtained)
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}
EOF

    # Reload NGINX to apply temporary configuration
    if podman exec "$CONTAINER_NAME" nginx -t; then
        podman exec "$CONTAINER_NAME" nginx -s reload
        log_success "Temporary NGINX configuration applied"
    else
        log_error "NGINX configuration test failed"
        exit 1
    fi
}

# Function to generate SSL certificate
generate_certificate() {
    log_info "Generating SSL certificate for domain: $DOMAIN"
    
    # Determine if using staging environment
    local staging_args=""
    if [[ "$STAGING_FLAG" == "--staging" ]]; then
        staging_args="--staging"
        log_warning "Using Let's Encrypt STAGING environment (certificates will not be trusted)"
    fi
    
    # Create certbot directories
    sudo mkdir -p "$CERTBOT_DIR"
    sudo mkdir -p "${WEBROOT_DIR}/.well-known/acme-challenge"
    
    # Set proper permissions
    sudo chown -R www-data:www-data "${WEBROOT_DIR}/.well-known" 2>/dev/null || true
    
    log_info "Requesting SSL certificate using Route53 DNS validation..."
    
    # Request certificate using Route53 DNS validation
    if sudo certbot certonly \
        --dns-route53 \
        -d "$DOMAIN" \
        -d "*.${DOMAIN}" \
        --non-interactive \
        --agree-tos \
        --email "$EMAIL" \
        $staging_args \
        --config-dir "$CERTBOT_DIR" \
        --work-dir /var/lib/letsencrypt \
        --logs-dir /var/log/letsencrypt \
        2>&1 | tee -a "$LOG_FILE"; then
        
        log_success "SSL certificate generated successfully!"
    else
        log_error "Failed to generate SSL certificate. Check log: $LOG_FILE"
        exit 1
    fi
}

# Function to copy certificates to NGINX directory
copy_certificates() {
    log_info "Copying certificates to NGINX SSL directory..."
    
    local cert_dir="${CERTBOT_DIR}/live/${DOMAIN}"
    
    if [[ ! -d "$cert_dir" ]]; then
        log_error "Certificate directory not found: $cert_dir"
        exit 1
    fi
    
    # Copy certificates with proper names
    sudo cp "${cert_dir}/fullchain.pem" "${NGINX_SSL_DIR}/${DOMAIN}.crt"
    sudo cp "${cert_dir}/privkey.pem" "${NGINX_SSL_DIR}/${DOMAIN}.key"
    
    # Set proper permissions
    sudo chmod 644 "${NGINX_SSL_DIR}/${DOMAIN}.crt"
    sudo chmod 600 "${NGINX_SSL_DIR}/${DOMAIN}.key"
    sudo chown root:root "${NGINX_SSL_DIR}/${DOMAIN}.crt"
    sudo chown root:root "${NGINX_SSL_DIR}/${DOMAIN}.key"
    
    log_success "Certificates copied to NGINX SSL directory"
}

# Function to create production NGINX SSL configuration
create_ssl_config() {
    log_info "Creating production NGINX SSL configuration..."
    
    # Remove temporary configuration
    sudo rm -f "${NGINX_CONF_DIR}/temp-${DOMAIN}.conf"
    
    # Create production SSL configuration
    cat << EOF | sudo tee "${NGINX_CONF_DIR}/ssl-${DOMAIN}.conf" > /dev/null
# SSL configuration for ${DOMAIN} and *.${DOMAIN}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN} *.${DOMAIN};
    
    # SSL Certificate Configuration
    ssl_certificate /etc/nginx/ssl/${DOMAIN}.crt;
    ssl_certificate_key /etc/nginx/ssl/${DOMAIN}.key;
    
    # Modern SSL Configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    # Security Headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/nginx/ssl/${DOMAIN}.crt;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;
    
    # Document Root
    root /usr/share/nginx/html;
    index index.html index.htm;
    
    # Default location
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # Security: Deny access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    # Error pages
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}

# Redirect HTTP to HTTPS for ${DOMAIN} and *.${DOMAIN}
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} *.${DOMAIN};
    
    # ACME challenge location (for renewals)
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

    log_success "Production NGINX SSL configuration created"
}

# Function to test and reload NGINX
reload_nginx() {
    log_info "Testing and reloading NGINX configuration..."
    
    if podman exec "$CONTAINER_NAME" nginx -t; then
        log_success "NGINX configuration test passed"
        
        if podman exec "$CONTAINER_NAME" nginx -s reload; then
            log_success "NGINX reloaded successfully"
        else
            log_error "Failed to reload NGINX"
            exit 1
        fi
    else
        log_error "NGINX configuration test failed"
        # Show recent logs
        podman logs --tail 20 "$CONTAINER_NAME"
        exit 1
    fi
}

# Function to setup automatic renewal
setup_auto_renewal() {
    log_info "Setting up automatic certificate renewal..."
    
    # Create renewal script
    cat << EOF | sudo tee /usr/local/bin/certbot-renew-${DOMAIN}.sh > /dev/null
#!/bin/bash
# Automatic certificate renewal script for ${DOMAIN}

# Renew certificate
certbot renew --config-dir ${CERTBOT_DIR} --quiet

# Copy renewed certificates to NGINX directory
if [[ -f "${CERTBOT_DIR}/live/${DOMAIN}/fullchain.pem" ]]; then
    cp "${CERTBOT_DIR}/live/${DOMAIN}/fullchain.pem" "${NGINX_SSL_DIR}/${DOMAIN}.crt"
    cp "${CERTBOT_DIR}/live/${DOMAIN}/privkey.pem" "${NGINX_SSL_DIR}/${DOMAIN}.key"
    
    # Set permissions
    chmod 644 "${NGINX_SSL_DIR}/${DOMAIN}.crt"
    chmod 600 "${NGINX_SSL_DIR}/${DOMAIN}.key"
    
    # Reload NGINX
    podman exec ${CONTAINER_NAME} nginx -s reload
    
    echo "Certificate for ${DOMAIN} renewed and NGINX reloaded"
fi
EOF

    sudo chmod +x "/usr/local/bin/certbot-renew-${DOMAIN}.sh"
    
    # Add to crontab if not already present
    local cron_entry="0 2 * * * /usr/local/bin/certbot-renew-${DOMAIN}.sh >> /var/log/certbot-renew-${DOMAIN}.log 2>&1"
    
    if ! sudo crontab -l 2>/dev/null | grep -q "certbot-renew-${DOMAIN}.sh"; then
        (sudo crontab -l 2>/dev/null; echo "$cron_entry") | sudo crontab -
        log_success "Automatic renewal cron job added"
    else
        log_info "Automatic renewal cron job already exists"
    fi
}

# Function to test SSL certificate
test_certificate() {
    log_info "Testing SSL certificate..."
    
    # Wait a moment for NGINX to apply changes
    sleep 3
    
    # Test SSL connection
    if command_exists openssl; then
        log_info "Testing SSL connection to ${DOMAIN}..."
        if echo | openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" 2>/dev/null | grep -q "Verify return code: 0"; then
            log_success "SSL certificate is working correctly"
        else
            log_warning "SSL test inconclusive (may be due to DNS propagation)"
        fi
    fi
    
    # Test HTTP redirect
    log_info "Testing HTTP to HTTPS redirect..."
    if command_exists curl; then
        local redirect_test=$(curl -s -I "http://${DOMAIN}" | grep -i "location:" | grep "https://")
        if [[ -n "$redirect_test" ]]; then
            log_success "HTTP to HTTPS redirect is working"
        else
            log_warning "HTTP redirect test inconclusive"
        fi
    fi
}

# Function to display final information
show_certificate_info() {
    log_success "SSL certificate setup completed successfully!"
    
    echo ""
    echo "=== Certificate Information ==="
    echo "Domain: $DOMAIN (including *.${DOMAIN})"
    echo "Email: $EMAIL"
    echo "Certificate Path: ${NGINX_SSL_DIR}/${DOMAIN}.crt"
    echo "Private Key Path: ${NGINX_SSL_DIR}/${DOMAIN}.key"
    echo "NGINX Config: ${NGINX_CONF_DIR}/ssl-${DOMAIN}.conf"
    
    if [[ "$STAGING_FLAG" == "--staging" ]]; then
        echo "Environment: STAGING (not trusted by browsers)"
    else
        echo "Environment: PRODUCTION (trusted by browsers)"
    fi
    
    echo ""
    echo "=== Certificate Details ==="
    if [[ -f "${NGINX_SSL_DIR}/${DOMAIN}.crt" ]]; then
        openssl x509 -in "${NGINX_SSL_DIR}/${DOMAIN}.crt" -text -noout | \
            grep -E "(Subject:|Issuer:|Not Before:|Not After:|DNS:)"
    fi
    
    echo ""
    echo "=== Access URLs ==="
    echo "HTTPS: https://${DOMAIN}"
    echo "HTTPS (wildcard): https://subdomain.${DOMAIN}"
    echo "HTTP (redirects): http://${DOMAIN}"
    
    echo ""
    echo "=== Renewal Information ==="
    echo "Automatic renewal: Enabled (daily check at 2 AM)"
    echo "Manual renewal: sudo /usr/local/bin/certbot-renew-${DOMAIN}.sh"
    echo "Renewal logs: /var/log/certbot-renew-${DOMAIN}.log"
    
    echo ""
    echo "=== Next Steps ==="
    echo "1. Update your DNS to point ${DOMAIN} to this server"
    echo "2. Configure your application in the NGINX SSL server block"
    echo "3. Test your SSL configuration at: https://www.ssllabs.com/ssltest/"
    echo "4. Monitor renewal logs for any issues"
    
    if [[ "$STAGING_FLAG" == "--staging" ]]; then
        echo ""
        echo "=== STAGING ENVIRONMENT WARNING ==="
        echo "This certificate is from Let's Encrypt staging environment."
        echo "It will show as untrusted in browsers."
        echo "For production, run again without --staging flag."
    fi
}

# Main execution function
main() {
    log_info "Starting SSL certificate generation for domain: $DOMAIN"
    
    # Check prerequisites
    check_prerequisites
    
    # Install dependencies
    install_dependencies
    
    # Check AWS credentials
    check_aws_credentials
    
    # Create temporary NGINX configuration
    create_challenge_config
    
    # Generate SSL certificate
    generate_certificate
    
    # Copy certificates to NGINX directory
    copy_certificates
    
    # Create production SSL configuration
    create_ssl_config
    
    # Test and reload NGINX
    reload_nginx
    
    # Setup automatic renewal
    setup_auto_renewal
    
    # Test certificate
    test_certificate
    
    # Show final information
    show_certificate_info
    
    log_success "SSL certificate setup completed for $DOMAIN!"
}

# Run main function with all arguments
main "$@"
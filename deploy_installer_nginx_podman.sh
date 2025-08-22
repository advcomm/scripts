#!/bin/bash

# Script to deploy NGINX app for serving downloadable installers
# Usage: ./deploy_installer_nginx_podman.sh <domain> <installers_path>
# Example: ./deploy_installer_nginx_podman.sh installers.xdoc.app /srv/installers

set -e

DOMAIN="$1"
INSTALLERS_PATH="$2"
NGINX_CONF_DIR="/etc/nginx-podman/conf.d"
SSL_DIR="/etc/nginx-podman/ssl"
NGINX_CONF_FILE="$NGINX_CONF_DIR/ssl-$DOMAIN.conf"
WEB_ROOT="/var/www/html-podman/installers"
CONTAINER_NAME="nginx-server"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No color

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
    exit 1
}

# Usage message
show_usage() {
    cat << EOF
Usage: $0 <domain> <installers_path>

Arguments:
  domain           Domain name for the installer service (e.g., installers.xdoc.app)
  installers_path  Host path containing installer files (e.g., /srv/installers)

Example:
  $0 installers.xdoc.app /srv/installers

Directory Structure Expected:
  /srv/installers/
  ├── windows/
  │   ├── installer.exe
  │   └── setup.msi
  ├── macos/
  │   ├── app.dmg
  │   └── installer.pkg
  ├── linux/
  │   ├── app.deb
  │   ├── app.rpm
  │   └── install.sh
  └── android/
      └── app.apk

Accessible URLs:
  https://$domain/installers/windows/installer.exe
  https://$domain/installers/macos/app.dmg
  https://$domain/installers/linux/app.deb
  https://$domain/installers/android/app.apk

Features:
  - SSL/HTTPS support with automatic certificate detection
  - Download acceleration and resume support
  - Directory browsing for each platform
  - MIME type detection for various installer formats
  - Security headers for safe downloads
  - Access logging for download analytics
EOF
}

# Validate input
if [ -z "$DOMAIN" ] || [ -z "$INSTALLERS_PATH" ]; then
    log_error "Missing required arguments"
    show_usage
    exit 1
fi

if [ ! -d "$INSTALLERS_PATH" ]; then
    log_error "Installers path does not exist: $INSTALLERS_PATH"
    exit 1
fi

# Check if running with proper privileges
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    log_error "This script requires sudo privileges"
fi

# Check if NGINX container is running
if ! podman ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    log_error "NGINX container '${CONTAINER_NAME}' is not running. Please run install_nginx_podman.sh first."
fi

log_info "Setting up installer download service for domain: $DOMAIN"

# Create web directory
log_info "Creating web directory structure..."
sudo mkdir -p "$WEB_ROOT"

# Copy installer files to web directory with proper structure
log_info "Copying installer files to web directory..."
sudo cp -r "$INSTALLERS_PATH"/* "$WEB_ROOT/"

# Set proper permissions for web files
log_info "Setting file permissions..."
sudo chown -R root:root "$WEB_ROOT"
sudo find "$WEB_ROOT" -type d -exec chmod 755 {} \;
sudo find "$WEB_ROOT" -type f -exec chmod 644 {} \;

# Check if SSL certificate exists
ssl_available=false
if [ -f "$SSL_DIR/$DOMAIN.crt" ] && [ -f "$SSL_DIR/$DOMAIN.key" ]; then
    ssl_available=true
    log_success "SSL certificate found for $DOMAIN"
else
    log_warning "SSL certificate not found for $DOMAIN"
    log_warning "Run: sudo /srv/scripts/gen_cert_aws.sh $DOMAIN first to enable HTTPS"
fi

# Remove old SSL config if present to avoid conflicts
# Remove any old <domain>.conf to avoid duplicate configs
OLD_CONF="$NGINX_CONF_DIR/$DOMAIN.conf"
if [ -f "$OLD_CONF" ]; then
    sudo rm -f "$OLD_CONF"
    log_info "Removed old config $OLD_CONF to avoid duplicate configs."
fi
# Always overwrite ssl-<domain>.conf

# Create NGINX configuration
log_info "Creating NGINX configuration..."

if [ "$ssl_available" = true ]; then
    # HTTPS configuration
    cat << EOF | sudo tee "$NGINX_CONF_FILE" > /dev/null
# Installer Download Service - HTTPS Configuration for $DOMAIN
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
    # Redirect HTTP to HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    # SSL Certificate Configuration
    ssl_certificate /etc/nginx/ssl/$DOMAIN.crt;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
    
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
    
    # Download-specific headers
    add_header X-Content-Type-Options nosniff always;
    add_header Content-Security-Policy "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:;" always;

    # Document Root
    root /usr/share/nginx/html/installers;
    index index.html;

    # Access and Error Logs
    access_log /var/log/nginx/installers-access.log combined;
    error_log /var/log/nginx/installers-error.log warn;

    # Main installer location
    location /installers/ {
        alias /usr/share/nginx/html/installers/;
        
        # Enable directory browsing
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        autoindex_format html;
        
        # Download acceleration
        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        
        # Enable range requests for resume support
        add_header Accept-Ranges bytes;
        
        # Cache control for installers
        location ~* \.(exe|msi|dmg|pkg|deb|rpm|apk|tar\.gz|zip|rar)$ {
            expires 30d;
            add_header Cache-Control "public, immutable";
            add_header Accept-Ranges bytes;
        }
        
        # Text files (README, changelogs, etc.)
        location ~* \.(txt|md|log|changelog)$ {
            expires 1d;
            add_header Cache-Control "public";
            add_header Content-Type "text/plain; charset=utf-8";
        }
    }

    # Root redirect to installers
    location = / {
        return 301 /installers/;
    }

    # Platform-specific shortcuts
    location /windows/ {
        return 301 /installers/windows/;
    }
    
    location /macos/ {
        return 301 /installers/macos/;
    }
    
    location /linux/ {
        return 301 /installers/linux/;
    }
    
    location /android/ {
        return 301 /installers/android/;
    }

    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Security: Deny access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Error pages
    error_page 404 /404.html;
    location = /404.html {
        root /usr/share/nginx/html;
        internal;
    }
}
EOF
else
    # HTTP-only configuration
    cat << EOF | sudo tee "$NGINX_CONF_FILE" > /dev/null
# Installer Download Service - HTTP Configuration for $DOMAIN
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # Document Root
    root /usr/share/nginx/html/installers;
    index index.html;

    # Access and Error Logs
    access_log /var/log/nginx/installers-access.log combined;
    error_log /var/log/nginx/installers-error.log warn;

    # Main installer location
    location /installers/ {
        alias /usr/share/nginx/html/installers/;
        
        # Enable directory browsing
        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        autoindex_format html;
        
        # Download acceleration
        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        
        # Enable range requests for resume support
        add_header Accept-Ranges bytes;
        
        # Cache control for installers
        location ~* \.(exe|msi|dmg|pkg|deb|rpm|apk|tar\.gz|zip|rar)$ {
            expires 30d;
            add_header Cache-Control "public, immutable";
            add_header Accept-Ranges bytes;
        }
        
        # Text files (README, changelogs, etc.)
        location ~* \.(txt|md|log|changelog)$ {
            expires 1d;
            add_header Cache-Control "public";
            add_header Content-Type "text/plain; charset=utf-8";
        }
    }

    # Root redirect to installers
    location = / {
        return 301 /installers/;
    }

    # Platform-specific shortcuts
    location /windows/ {
        return 301 /installers/windows/;
    }
    
    location /macos/ {
        return 301 /installers/macos/;
    }
    
    location /linux/ {
        return 301 /installers/linux/;
    }
    
    location /android/ {
        return 301 /installers/android/;
    }

    # Health check endpoint
    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Security: Deny access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Error pages
    error_page 404 /404.html;
    location = /404.html {
        root /usr/share/nginx/html;
        internal;
    }
}
EOF
fi

# Create a simple index page
log_info "Creating installer index page..."
cat << EOF | sudo tee "$WEB_ROOT/index.html" > /dev/null
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Installer Downloads - $DOMAIN</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #333; border-bottom: 2px solid #007acc; padding-bottom: 10px; }
        .platform { margin: 20px 0; padding: 15px; border: 1px solid #ddd; border-radius: 5px; }
        .platform h3 { margin-top: 0; color: #007acc; }
        .download-link { display: inline-block; margin: 5px 10px 5px 0; padding: 8px 15px; background: #007acc; color: white; text-decoration: none; border-radius: 4px; }
        .download-link:hover { background: #005a99; }
        .browse-link { color: #666; font-size: 0.9em; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Installer Downloads</h1>
        <p>Download the latest version of our software for your platform:</p>
        
        <div class="platform">
            <h3>🪟 Windows</h3>
            <a href="/installers/windows/" class="browse-link">Browse all Windows installers</a>
        </div>
        
        <div class="platform">
            <h3>🍎 macOS</h3>
            <a href="/installers/macos/" class="browse-link">Browse all macOS installers</a>
        </div>
        
        <div class="platform">
            <h3>🐧 Linux</h3>
            <a href="/installers/linux/" class="browse-link">Browse all Linux packages</a>
        </div>
        
        <div class="platform">
            <h3>📱 Android</h3>
            <a href="/installers/android/" class="browse-link">Browse all Android packages</a>
        </div>
        
        <hr style="margin: 30px 0;">
        <p><small>All downloads are served securely with resume support. If you need help, please contact our support team.</small></p>
    </div>
</body>
</html>
EOF

# Test NGINX configuration
log_info "Testing NGINX configuration..."
if podman exec "$CONTAINER_NAME" nginx -t; then
    log_success "NGINX configuration test passed"
else
    log_error "NGINX configuration test failed"
fi

# Reload NGINX
log_info "Reloading NGINX container..."
if podman exec "$CONTAINER_NAME" nginx -s reload; then
    log_success "NGINX container reloaded successfully"
else
    log_error "Failed to reload NGINX container"
fi

# Show summary
log_success "Installer download service deployed successfully!"

echo ""
echo "=== Installation Summary ==="
echo "Domain: $DOMAIN"
echo "Installers Path: $INSTALLERS_PATH"
echo "Web Root: $WEB_ROOT"
echo "NGINX Config: $NGINX_CONF_FILE"

if [ "$ssl_available" = true ]; then
    echo "Protocol: HTTPS (SSL enabled)"
    echo ""
    echo "=== Access URLs ==="
    echo "Main page: https://$DOMAIN/"
    echo "All installers: https://$DOMAIN/installers/"
    echo "Windows: https://$DOMAIN/installers/windows/"
    echo "macOS: https://$DOMAIN/installers/macos/"
    echo "Linux: https://$DOMAIN/installers/linux/"
    echo "Android: https://$DOMAIN/installers/android/"
else
    echo "Protocol: HTTP (SSL not configured)"
    echo ""
    echo "=== Access URLs ==="
    echo "Main page: http://$DOMAIN/"
    echo "All installers: http://$DOMAIN/installers/"
    echo "Windows: http://$DOMAIN/installers/windows/"
    echo "macOS: http://$DOMAIN/installers/macos/"
    echo "Linux: http://$DOMAIN/installers/linux/"
    echo "Android: http://$DOMAIN/installers/android/"
    echo ""
    echo "To enable HTTPS:"
    echo "  sudo /srv/scripts/gen_cert_aws.sh $DOMAIN"
    echo "  sudo $0 $DOMAIN $INSTALLERS_PATH"
fi

echo ""
echo "=== Features Enabled ==="
echo "✅ Directory browsing for each platform"
echo "✅ Download resume support (HTTP Range requests)"
echo "✅ File caching (30 days for installers, 1 day for docs)"
echo "✅ Security headers and access controls"
echo "✅ Download analytics via access logs"
echo "✅ Health check endpoint: /health"

echo ""
echo "=== Directory Structure ==="
echo "Organize your installer files like this in $INSTALLERS_PATH:"
echo "├── windows/"
echo "│   ├── app-setup.exe"
echo "│   └── app-installer.msi"
echo "├── macos/"
echo "│   ├── app.dmg"
echo "│   └── app-installer.pkg"
echo "├── linux/"
echo "│   ├── app.deb"
echo "│   ├── app.rpm"
echo "│   └── install.sh"
echo "└── android/"
echo "    └── app.apk"

echo ""
echo "=== Management Commands ==="
echo "View access logs: podman exec $CONTAINER_NAME tail -f /var/log/nginx/installers-access.log"
echo "View error logs: podman exec $CONTAINER_NAME tail -f /var/log/nginx/installers-error.log"
echo "Update installers: sudo cp -r $INSTALLERS_PATH/* $WEB_ROOT/ && sudo podman exec $CONTAINER_NAME nginx -s reload"

log_success "Setup complete! Your installer download service is now live."
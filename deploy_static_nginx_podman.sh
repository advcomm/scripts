#!/bin/bash

# Usage: ./deploy_static_nginx_podman.sh <domain> <static_path>
# Example: ./deploy_static_nginx_podman.sh s.xdoc.app /srv/xdocweb/prod/web

set -e

DOMAIN="$1"
APP_NAME="$2"
STATIC_PATH="/var/www/html-podman/$APP_NAME"
NGINX_CONF_DIR="/etc/nginx-podman/conf.d"
SSL_DIR="/etc/nginx-podman/ssl"
NGINX_CONF_FILE="$NGINX_CONF_DIR/$DOMAIN.conf"

if [ -z "$DOMAIN" ] || [ -z "$APP_NAME" ]; then
  echo "Usage: $0 <domain> <APP_NAME>"
  exit 1
fi

if [ ! -d "$STATIC_PATH" ]; then
  echo "App path does not exist: $STATIC_PATH"
  exit 1
fi

if [ ! -f "$SSL_DIR/$DOMAIN.crt" ] || [ ! -f "$SSL_DIR/$DOMAIN.key" ]; then
  echo "SSL certificate files not found: $SSL_DIR/$DOMAIN.crt or $SSL_DIR/$DOMAIN.key"
  exit 1
fi

# Set permissions for static path (readable by container)
chown -R $USER:$USER "$STATIC_PATH"
chmod -R 755 "$STATIC_PATH"

# Remove old SSL config if present to avoid conflicts
OLD_SSL_CONF="$NGINX_CONF_DIR/ssl-$DOMAIN.conf"
if [ -f "$OLD_SSL_CONF" ]; then
  mv "$OLD_SSL_CONF" "$OLD_SSL_CONF.bak"
  echo "Old SSL config $OLD_SSL_CONF moved to $OLD_SSL_CONF.bak"
fi

# Create NGINX config for the domain
cat > "$NGINX_CONF_FILE" <<EOL
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/ssl/$DOMAIN.crt;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;

    root /usr/share/nginx/html/$APP_NAME;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    error_page 404 /index.html;

    location ~* \.(?:ico|css|js|gif|jpe?g|png|svg|woff2?|eot|ttf|otf|webp)$ {
        expires 6M;
        access_log off;
        add_header Cache-Control "public";
    }

    gzip on;
    gzip_types text/plain application/xml text/css application/javascript;
}
EOL

echo "NGINX config created at $NGINX_CONF_FILE"

# Reload NGINX container
podman exec nginx-server nginx -t && podman exec nginx-server nginx -s reload

echo "Deployment complete. Static site for $DOMAIN is now live via NGINX in Podman."
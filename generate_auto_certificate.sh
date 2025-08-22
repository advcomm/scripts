#!/bin/bash

# Check if domain name argument is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <yourdomain.com>"
    exit 1
fi

# Set domain variables
DOMAIN="$1"
WILDCARD_DOMAIN="*.$DOMAIN"
CERTBOT_DIR="/etc/letsencrypt/live/$DOMAIN"
AWS_CREDENTIALS_FILE="$HOME/.aws/credentials"

# Function to check if a package is installed
is_installed() {
    dpkg -l | grep -q "$1"
}

# Install AWS CLI if not installed
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    sudo apt update
    sudo apt install -y awscli
fi

# Install Certbot if not installed
if ! command -v certbot &> /dev/null; then
    echo "Installing Certbot..."
    sudo apt install -y certbot
fi

# Install Certbot Route 53 plugin if not installed
if ! is_installed "python3-certbot-dns-route53"; then
    echo "Installing Certbot Route 53 plugin..."
    sudo apt install -y python3-certbot-dns-route53
fi

# Check if AWS credentials exist
if [ ! -f "$AWS_CREDENTIALS_FILE" ]; then
    echo "AWS credentials not found. Please configure them in ~/.aws/credentials."
    exit 1
fi

# Request the wildcard SSL certificate
echo "Requesting SSL certificate for $WILDCARD_DOMAIN and $DOMAIN..."
sudo certbot certonly --dns-route53 \
    -d "$WILDCARD_DOMAIN" -d "$DOMAIN" \
    --non-interactive --agree-tos --email dev1@hostingcontroller.com \
    --config-dir /etc/nginx-podman/ssl \
    --work-dir /var/lib/letsencrypt \
    --logs-dir /var/log/letsencrypt

# Check if certificate was generated
if [ -d "$CERTBOT_DIR" ]; then
    echo "✅ SSL Certificate generated successfully!"
    echo "Certificate files are stored in: $CERTBOT_DIR"
else
    echo "❌ Failed to generate SSL certificate."
    exit 1
fi

# Display certificate file paths
echo "Certificate files:"
ls -l "$CERTBOT_DIR"

# Set up automatic renewal if not already added
if ! sudo crontab -l | grep -q "certbot renew"; then
    echo "Setting up automatic renewal..."
    (sudo crontab -l 2>/dev/null; echo "0 2 * * * certbot renew --quiet") | sudo crontab -
fi

echo "🎉 Wildcard SSL certificate setup complete for $DOMAIN!"

#!/bin/bash
# filepath: ~/add_aws_credentials.sh

set -e

AWS_DIR="$HOME/.aws"
CRED_FILE="$AWS_DIR/credentials"

read -p "Enter AWS Access Key ID: " ACCESS_KEY
read -p "Enter AWS Secret Access Key: " SECRET_KEY

mkdir -p "$AWS_DIR"
cat > "$CRED_FILE" <<EOF
[default]
aws_access_key_id = $ACCESS_KEY
aws_secret_access_key = $SECRET_KEY
EOF

chmod 600 "$CRED_FILE"

echo "AWS credentials saved to $CRED_FILE"
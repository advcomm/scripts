#!/bin/bash
# filepath: create_directories.sh

set -e

APP_NAME="$1"
SSH_KEY="$2"
GIT_URL="$3"

if [ -z "$APP_NAME" ] || [ -z "$SSH_KEY" ] || [ -z "$GIT_URL" ]; then
    echo "Usage: $0 <app_name> <ssh_private_key> <git_url>"
    exit 1
fi

APP_DIR="/srv/${APP_NAME}"
SSH_DIR="${APP_DIR}/ssh"
REPO_DIR="${APP_DIR}/repo"
KEY_PATH="${SSH_DIR}/${APP_NAME}"

# Create directory structure
mkdir -p "${APP_DIR}/"{prod,repo,conf,rbck,scripts,ssh}

# Add/Replace SSH key in file
echo "$SSH_KEY" > "$KEY_PATH"
chmod 600 "$KEY_PATH"

# Clone the repo (if not already cloned)
if [ -d "$REPO_DIR/.git" ]; then
    echo "Repo already cloned in $REPO_DIR"
else
    cd "$REPO_DIR/.."  # cd to /srv/<app_name>
    GIT_SSH_COMMAND="ssh -i $KEY_PATH -o StrictHostKeyChecking=no" git clone "$GIT_URL" repo
    if [ $? -ne 0 ]; then
        echo "Git clone failed"
        exit 1
    fi
fi

echo "✅ Directory setup and repo clone complete for $APP_NAME"
exit 0
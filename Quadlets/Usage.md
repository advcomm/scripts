# Multi-Tenant Application Provisioning - Usage Guide

This guide explains how to provision and manage tenant applications using the `provision-tenant-app.sh` script with Podman Quadlets.

## Table of Contents

- [Quick Start](#quick-start)
- [Concepts](#concepts)
- [Examples](#examples)
  - [Example 1: xdoc-api Container](#example-1-xdoc-api-container)
  - [Example 2: PostgreSQL Database](#example-2-postgresql-database)
  - [Example 3: NGINX Web Server](#example-3-nginx-web-server)
- [Directory Structure](#directory-structure)
- [Commands Reference](#commands-reference)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

```bash
# 1. Copy script to server
scp provision-tenant-app.sh root@your-server:/usr/local/bin/
chmod +x /usr/local/bin/provision-tenant-app.sh

# 2. Provision and start in ONE command!
./provision-tenant-app.sh provision xdoc api docker.io/chishtiaq422/xdoc-api:latest "3000:3000" "NODE_ENV=production"
```

That's it! The `provision` command handles everything:
1. ✅ Creates the tenant (if not exists)
2. ✅ Pulls the container image
3. ✅ Creates the app user and directories
4. ✅ Creates the Quadlet systemd service
5. ✅ Starts the service

---

## Concepts

### Naming Convention

| Concept | OS Entity | Example |
|---------|-----------|---------|
| **Tenant** | Linux Group | `xdoc` |
| **App** | Linux User | `xdoc_api` |
| **Service** | Systemd Unit | `xdoc-api.service` |
| **Container** | Podman Container | `xdoc-api` |

### Directory Structure

```
/srv/<tenant>/<app>/
├── read/      (550) - Read-only data mounted to /app/read
├── write/     (700) - Private writable data → /app/write
├── exec/      (550) - Executable scripts → /app/exec
├── shared/    (750) - Shared with tenant group → /app/shared
├── data/      (700) - Persistent data → /app/data
├── config/    (500) - Configuration files → /app/config
├── logs/      (700) - Application logs → /app/logs
└── secrets/   (500) - Secrets → /run/secrets
```

---

## Examples

### Example 1: xdoc-api Container

Deploy the xdoc-api application for tenant `xdoc`:

```bash
# Simple deployment - ONE command does everything!
./provision-tenant-app.sh provision \
    xdoc \
    api \
    docker.io/chishtiaq422/xdoc-api:latest \
    "3000:3000" \
    "NODE_ENV=production,DB_CONFIG={},BACKEND_SERVERS=95.216.189.60,LOOKUP_SERVER=95.216.189.60"

# Check status
./provision-tenant-app.sh status xdoc api

# View logs
./provision-tenant-app.sh logs xdoc api
```

#### With Custom Volumes

For apps requiring additional volumes (like PostgreSQL socket or uploads directory):

```bash
# Provision with custom volumes
./provision-tenant-app.sh provision \
    xdoc \
    api \
    docker.io/chishtiaq422/xdoc-api:latest \
    "3000:3000" \
    "NODE_ENV=production,DB_CONFIG={},BACKEND_SERVERS=95.216.189.60,LOOKUP_SERVER=95.216.189.60" \
    "" \
    "/uploads:/app/uploads:rw,Z,pg-run-volume:/var/run/postgresql:rw"
```

**Parameters breakdown:**
| Position | Parameter | Example |
|----------|-----------|---------|
| 1 | tenant | `xdoc` |
| 2 | app | `api` |
| 3 | image | `docker.io/chishtiaq422/xdoc-api:latest` |
| 4 | ports | `"3000:3000"` |
| 5 | env_vars | `"NODE_ENV=production,KEY=value"` |
| 6 | extra_args | `""` (podman args like `--memory=1g`) |
| 7 | volumes | `"/host/path:/container/path:rw"` |

#### Provision Without Auto-Start

```bash
# Create everything but don't start the service
./provision-tenant-app.sh provision xdoc api docker.io/myapp:latest "3000:3000" "" "" "" --no-start

# Start manually later
./provision-tenant-app.sh start xdoc api
```

---

### Example 2: PostgreSQL Database (Quadlet)

Deploy PostgreSQL as a Quadlet container with peer authentication.

**Key Feature:** The script now **creates the tenant and app user** if they don't exist, so you can install PostgreSQL first!

```bash
# Install PostgreSQL with tenant/app - CREATES the user automatically
# This creates: tenant group 'xdoc', user 'xdoc_api' with UID 100001+
./install_postgres_quadlet.sh install --tenant xdoc --app api

# Or install with default settings (no user mapping)
./install_postgres_quadlet.sh install

# Or get/create the UID first for manual use
./install_postgres_quadlet.sh get-uid xdoc api
```

#### Full Stack Deployment (Database First - Recommended)

```bash
# Step 1: Install PostgreSQL with tenant/app
# This CREATES the user xdoc_api with UID 100001 (or next available)
./install_postgres_quadlet.sh install --tenant xdoc --app api

# Step 2: Get the UID that was created
API_UID=$(id -u xdoc_api)
echo "Created user xdoc_api with UID: $API_UID"

# Step 3: Create the database using pg_deploy_with_update.sh (uses tenant/app naming)
./pg_deploy_with_update.sh xdoc api /backup /repo ~/.ssh/key

# Step 4: Provision the API app (user already exists, will be REUSED)
./provision-tenant-app.sh provision xdoc api docker.io/chishtiaq422/xdoc-api:latest \
    "3000:3000" \
    "NODE_ENV=production,BACKEND_SERVERS=95.216.189.60" \
    "" \
    "/uploads:/app/uploads:rw,Z,pg-run-volume:/var/run/postgresql:rw"

# Both PostgreSQL and xdoc-api now share UID 100001 for peer authentication!
```

#### PostgreSQL Quadlet Commands

```bash
# Check status
./install_postgres_quadlet.sh status

# Connect to database
./install_postgres_quadlet.sh connect postgres postgres
./install_postgres_quadlet.sh connect xdoc xdoc

# Get/create UID for a tenant/app
./install_postgres_quadlet.sh get-uid xdoc api

# Uninstall
./install_postgres_quadlet.sh uninstall
```

---

### Example 3: NGINX Web Server

Deploy NGINX as a reverse proxy for the xdoc tenant:

```bash
# Provision NGINX
./provision-tenant-app.sh provision \
    xdoc \
    nginx \
    docker.io/nginx:latest \
    "80:80,443:443" \
    "NGINX_HOST=xdoc.example.com"

# Add your nginx config
cat > /srv/xdoc/nginx/config/default.conf << 'EOF'
upstream xdoc_api {
    server 127.0.0.1:3000;
}

server {
    listen 80;
    server_name xdoc.example.com;

    location / {
        proxy_pass http://xdoc_api;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

# Restart to pick up config
./provision-tenant-app.sh restart xdoc nginx
```

---

## Commands Reference

### Tenant Management

| Command | Description |
|---------|-------------|
| `create-tenant <name>` | Create a new tenant (OS group + directory) |
| `delete-tenant <name>` | Delete tenant (must have no apps) |
| `list-tenants` | List all registered tenants |

### Container App Management

| Command | Description |
|---------|-------------|
| `provision <tenant> <app> <image> [ports] [env_vars] [extra_args] [volumes] [--no-start]` | **Recommended!** All-in-one: pull, create, start |
| `create-container <tenant> <app> <image> [ports] [env_vars] [extra_args]` | Create without starting |
| `delete-container <tenant> <app>` | Delete container app |
| `list-containers <tenant>` | List container apps for tenant |
| `pull-image <image>` | Pull a container image |

### Service Management

| Command | Description |
|---------|-------------|
| `start <tenant> <app>` | Start the app service |
| `stop <tenant> <app>` | Stop the app service |
| `restart <tenant> <app>` | Restart the app service |
| `status <tenant> <app>` | Show service status |
| `logs <tenant> <app>` | Follow service logs |

### Direct systemctl Commands

Since Quadlets generate systemd services, you can also use:

```bash
# Service name format: <tenant>-<app>.service
systemctl status xdoc-api.service
systemctl restart xdoc-api.service
journalctl -u xdoc-api.service -f
```

---

## Troubleshooting

### Service Won't Start

```bash
# Check service logs
journalctl -u xdoc-api.service --no-pager -n 50

# Verify quadlet file syntax
/usr/libexec/podman/quadlet --dryrun /etc/containers/systemd/

# Try running container manually
podman run --rm -it docker.io/chishtiaq422/xdoc-api:latest
```

### Permission Issues

```bash
# Check directory ownership
ls -la /srv/xdoc/api/

# Check user/group
id xdoc_api
getent group xdoc

# Fix ownership if needed
chown -R xdoc_api:xdoc /srv/xdoc/api/
```

### Container Networking

```bash
# Check if port is in use
ss -tlnp | grep :3000

# Check container networking
podman ps
podman inspect xdoc-api | jq '.[0].NetworkSettings'
```

### SELinux Issues (RHEL/CentOS)

```bash
# Check SELinux status
getenforce

# View SELinux denials
ausearch -m avc -ts recent

# Temporary workaround (not recommended for production)
setenforce 0

# Proper fix: add correct labels
chcon -Rt svirt_sandbox_file_t /srv/xdoc/
```

### Volume Mount Issues

```bash
# List podman volumes
podman volume ls

# Inspect a volume
podman volume inspect pg-run-volume

# Create missing volume
podman volume create pg-run-volume
```

---

## Complete xdoc Deployment Example

Here's the recommended workflow - **database first**, then API:

```bash
#!/bin/bash
# deploy-xdoc.sh - Deploy complete xdoc stack (Database First)

set -e

echo "=== Step 1: Install PostgreSQL with tenant/app ==="
# This CREATES: tenant group 'xdoc', user 'xdoc_api' with UID
./install_postgres_quadlet.sh install --tenant xdoc --app api

echo "=== Step 2: Get the created UID ==="
API_UID=$(id -u xdoc_api)
echo "User xdoc_api has UID: $API_UID"

echo "=== Step 3: Create uploads directory ==="
mkdir -p /uploads
chown $API_UID:xdoc /uploads
chmod 2770 /uploads

echo "=== Step 4: Create database and run migrations ==="
./pg_deploy_with_update.sh xdoc api /backup /path/to/repo ~/.ssh/id_rsa

echo "=== Step 5: Deploy xdoc-api (user already exists) ==="
# provision-tenant-app.sh will REUSE the existing xdoc_api user
./provision-tenant-app.sh provision xdoc api docker.io/chishtiaq422/xdoc-api:latest \
    "3000:3000" \
    "NODE_ENV=production,DB_CONFIG={},BACKEND_SERVERS=95.216.189.60,LOOKUP_SERVER=95.216.189.60" \
    "" \
    "/uploads:/app/uploads:rw,Z,pg-run-volume:/var/run/postgresql:rw"

echo "=== Step 6: Check status ==="
./install_postgres_quadlet.sh status
./provision-tenant-app.sh status xdoc api

echo "=== Done! ==="
echo "PostgreSQL: pg-root-peer.service (shared UID: $API_UID)"
echo "xdoc-api: http://localhost:3000 (UID: $API_UID)"
echo ""
echo "Both services share the same UID for peer authentication!"
```

**Why Database First?**

| Order | What Happens |
|-------|--------------|
| 1. PostgreSQL install | Creates tenant `xdoc`, user `xdoc_api` (UID: 100001) |
| 2. pg_deploy | Creates OS user in container, DB user, database |
| 3. API provision | **Reuses** existing `xdoc_api` user (same UID!) |
| Result | Both containers run as UID 100001 → peer auth works! |

---

## Notes

1. **Quadlet files location**: `/etc/containers/systemd/<tenant>-<app>.container`
2. **Data persistence**: All app data is stored in `/srv/<tenant>/<app>/`
3. **Logs**: Use `journalctl -u <tenant>-<app>.service` or check `/srv/<tenant>/<app>/logs/`
4. **Auto-start**: Services with `[Install] WantedBy=multi-user.target` start on boot automatically
5. **Updates**: To update an image, run `podman pull <image>` then `systemctl restart <service>`

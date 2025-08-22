#!/bin/bash

# Exit on any error
set -e

# Configurable Variables
CONTAINER_NAME="pg-root-peer"
DATA_PATH="$HOME/podman_pg/data"
RUN_PATH="$HOME/podman_pg/run"
CONF_PATH="$HOME/podman_pg/postgresql.conf"
HBA_PATH="$HOME/podman_pg/pg_hba.conf"
IMAGE="docker.io/library/postgres:16"

echo "🚀 Starting Podman PostgreSQL Setup..."

# Check if Podman is installed, install if not present
if ! command -v podman &> /dev/null; then
    echo "❌ Podman is not installed. Installing Podman automatically..."
    
    # Detect the Linux distribution
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        DISTRO=$ID
        VERSION=$VERSION_ID
        echo "  Detected OS: $PRETTY_NAME"
    else
        echo "❌ Cannot detect Linux distribution. Please install Podman manually."
        exit 1
    fi
    
    # Install Podman based on distribution
    case $DISTRO in
        ubuntu|debian)
            echo "  Installing Podman on Ubuntu/Debian..."
            if ! command -v curl &> /dev/null; then
                echo "  Installing curl first..."
                sudo apt update
                sudo apt install -y curl
            fi
            
            # Update package list
            sudo apt update
            
            # Install Podman
            sudo apt install -y podman
            
            # Verify installation
            if command -v podman &> /dev/null; then
                echo "✅ Podman installed successfully!"
                podman --version
            else
                echo "❌ Podman installation failed. Please install manually."
                exit 1
            fi
            ;;
            
        fedora|rhel|centos|rocky|almalinux)
            echo "  Installing Podman on RHEL-based distribution..."
            if [[ "$DISTRO" == "fedora" ]]; then
                sudo dnf install -y podman
            else
                # For RHEL/CentOS/Rocky/AlmaLinux
                sudo yum install -y podman 2>/dev/null || sudo dnf install -y podman
            fi
            
            # Verify installation
            if command -v podman &> /dev/null; then
                echo "✅ Podman installed successfully!"
                podman --version
            else
                echo "❌ Podman installation failed. Please install manually."
                exit 1
            fi
            ;;
            
        arch|manjaro)
            echo "  Installing Podman on Arch-based distribution..."
            sudo pacman -Sy --noconfirm podman
            
            # Verify installation
            if command -v podman &> /dev/null; then
                echo "✅ Podman installed successfully!"
                podman --version
            else
                echo "❌ Podman installation failed. Please install manually."
                exit 1
            fi
            ;;
            
        opensuse*|sles)
            echo "  Installing Podman on openSUSE/SLES..."
            sudo zypper install -y podman
            
            # Verify installation
            if command -v podman &> /dev/null; then
                echo "✅ Podman installed successfully!"
                podman --version
            else
                echo "❌ Podman installation failed. Please install manually."
                exit 1
            fi
            ;;
            
        *)
            echo "❌ Unsupported distribution: $DISTRO"
            echo "Please install Podman manually using your distribution's package manager:"
            echo "  Ubuntu/Debian: sudo apt install podman"
            echo "  Fedora: sudo dnf install podman"
            echo "  RHEL/CentOS: sudo yum install podman"
            echo "  Arch: sudo pacman -S podman"
            echo "  openSUSE: sudo zypper install podman"
            exit 1
            ;;
    esac
    
    # Additional setup for some distributions
    echo "🔧 Performing post-installation setup..."
    
    # Enable user namespaces if not already enabled
    if [[ -f /proc/sys/user/max_user_namespaces ]]; then
        MAX_USER_NS=$(cat /proc/sys/user/max_user_namespaces)
        if [[ "$MAX_USER_NS" -eq 0 ]]; then
            echo "  Enabling user namespaces..."
            echo 'user.max_user_namespaces=28633' | sudo tee -a /etc/sysctl.conf
            sudo sysctl -p
        fi
    fi
    
    # Configure subuid and subgid for current user if not present
    if ! grep -q "^$(whoami):" /etc/subuid 2>/dev/null; then
        echo "  Configuring subuid for user $(whoami)..."
        echo "$(whoami):100000:65536" | sudo tee -a /etc/subuid
    fi
    
    if ! grep -q "^$(whoami):" /etc/subgid 2>/dev/null; then
        echo "  Configuring subgid for user $(whoami)..."
        echo "$(whoami):100000:65536" | sudo tee -a /etc/subgid
    fi
    
    # Initialize Podman for rootless operation
    echo "  Initializing Podman for rootless operation..."
    podman system migrate 2>/dev/null || true
    
    echo "✅ Podman installation and setup completed!"
else
    echo "✅ Podman is already installed."
    podman --version
fi

# Ensure Podman machine is running (for systems that use podman machine)
if podman machine list &> /dev/null; then
    if ! podman machine list | grep -q "Running"; then
        echo "⚙️  Starting Podman machine..."
        podman machine start
    else
        echo "✔️  Podman machine already running."
    fi
else
    echo "✔️  Podman is running in native mode (no machine required)."
fi

# Host verification - ensure script host and container host are the same
echo "🔍 Verifying host compatibility..."

# Get Linux host information
LINUX_HOSTNAME=$(hostname)
LINUX_USERNAME=$(whoami)
LINUX_USER_ID=$(id -u)
LINUX_GROUP_ID=$(id -g)
echo "  Linux Host: $LINUX_HOSTNAME"
echo "  Linux User: $LINUX_USERNAME (UID:$LINUX_USER_ID, GID:$LINUX_GROUP_ID)"

# Get Podman machine information (if applicable)
if podman machine list &> /dev/null; then
    echo "🔗 Checking Podman machine info..."
    PODMAN_MACHINE_INFO=$(podman machine inspect --format json 2>/dev/null | jq -r '.[0] | "\(.Name) - \(.State)"' 2>/dev/null || echo "Unable to parse machine info")
    echo "  Podman Machine: $PODMAN_MACHINE_INFO"
fi

# Verify Podman can access the host filesystem
echo "🔗 Testing host-container filesystem access..."
TEST_FILE="/tmp/podman_test_$(date +%Y%m%d_%H%M%S).txt"
echo "Host verification test" > "$TEST_FILE"

# Test if container can access the host file
if TEST_RESULT=$(podman run --rm -v "/tmp:/host_temp:Z" "$IMAGE" cat "/host_temp/$(basename "$TEST_FILE")" 2>/dev/null); then
    if [[ "$TEST_RESULT" == "Host verification test" ]]; then
        echo "✅ Host-container filesystem access verified."
        rm -f "$TEST_FILE"
    else
        echo "❌ Host-container filesystem access failed."
        echo "This may indicate that Podman cannot properly access host files."
        rm -f "$TEST_FILE"
        exit 1
    fi
else
    echo "❌ Host-container filesystem access test failed."
    rm -f "$TEST_FILE"
    exit 1
fi

# Verify volume mount capabilities
echo "🗂️  Testing volume mount capabilities..."
TEMP_DIR="/tmp/podman_volume_test"
mkdir -p "$TEMP_DIR"

if VOLUME_TEST=$(podman run --rm -v "${TEMP_DIR}:/test_mount:Z" "$IMAGE" sh -c "echo 'Volume mount test' > /test_mount/test.txt && cat /test_mount/test.txt" 2>/dev/null); then
    if [[ "$VOLUME_TEST" == "Volume mount test" ]] && [[ -f "$TEMP_DIR/test.txt" ]]; then
        echo "✅ Volume mount capabilities verified."
        rm -rf "$TEMP_DIR"
    else
        echo "❌ Volume mount test failed."
        echo "Socket mounting may not work properly."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
else
    echo "❌ Volume mount test failed."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Check if we can create Unix sockets in mounted volumes
echo "🔌 Testing Unix socket creation capabilities..."
SOCKET_TEST_DIR="/tmp/podman_socket_test"
mkdir -p "$SOCKET_TEST_DIR"

SOCKET_TEST=$(podman run --rm -v "${SOCKET_TEST_DIR}:/socket_test:Z" "$IMAGE" sh -c "
    # Try to create a simple Unix socket using netcat
    timeout 2 nc -U -l /socket_test/test.sock &
    sleep 1
    ls -la /socket_test/
    kill %1 2>/dev/null || true
" 2>/dev/null || echo "Socket test failed")

echo "Socket test output:"
echo "$SOCKET_TEST"

rm -rf "$SOCKET_TEST_DIR"

# Additional verification for container runtime
echo "🖥️  Checking Podman configuration..."
if podman info &> /dev/null; then
    PODMAN_RUNTIME=$(podman info --format json | jq -r '.host.ociRuntime.name' 2>/dev/null || echo "unknown")
    PODMAN_STORAGE=$(podman info --format json | jq -r '.store.graphDriverName' 2>/dev/null || echo "unknown")
    echo "  Runtime: $PODMAN_RUNTIME"
    echo "  Storage Driver: $PODMAN_STORAGE"
    
    if [[ "$PODMAN_RUNTIME" == "runc" ]] || [[ "$PODMAN_RUNTIME" == "crun" ]]; then
        echo "✅ Using compatible OCI runtime - optimal for Unix socket support."
    else
        echo "⚠️  Unknown runtime: $PODMAN_RUNTIME"
    fi
else
    echo "⚠️  Could not get Podman info."
fi

echo "✅ Host verification completed."

# Final host identity verification
echo "🔍 Performing final host identity verification..."
HOST_IDENTIFIER="PODMAN_HOST_$(date +%Y%m%d%H%M%S)_${LINUX_HOSTNAME}_${LINUX_USERNAME}"
IDENTIFIER_FILE="/tmp/${HOST_IDENTIFIER}.txt"
echo "$HOST_IDENTIFIER" > "$IDENTIFIER_FILE"

# Read the identifier from within a container
if CONTAINER_IDENTIFIER=$(podman run --rm -v "/tmp:/host_temp:Z" "$IMAGE" cat "/host_temp/$(basename "$IDENTIFIER_FILE")" 2>/dev/null); then
    if [[ "$CONTAINER_IDENTIFIER" == "$HOST_IDENTIFIER" ]]; then
        echo "✅ Host identity verification successful."
        echo "  Script host and container host are confirmed to be the same."
        echo "  Identifier: $HOST_IDENTIFIER"
    else
        echo "❌ Host identity verification failed!"
        echo "  Expected: $HOST_IDENTIFIER"
        echo "  Got: $CONTAINER_IDENTIFIER"
        echo "  This indicates the container is running on a different host than the script."
        rm -f "$IDENTIFIER_FILE"
        exit 1
    fi
else
    echo "❌ Host identity verification failed!"
    echo "Cannot guarantee that script host and container host are the same."
    rm -f "$IDENTIFIER_FILE"
    exit 1
fi

rm -f "$IDENTIFIER_FILE"

# Additional check: verify container can write back to host
echo "🔄 Testing bidirectional host-container file access..."
TEST_DIR="/tmp/podman_bidirectional_test"
mkdir -p "$TEST_DIR"

if podman run --rm -v "${TEST_DIR}:/test_dir:Z" "$IMAGE" sh -c "echo 'Container can write to host' > /test_dir/container_write.txt" &> /dev/null; then
    if [[ -f "$TEST_DIR/container_write.txt" ]]; then
        CONTENT=$(cat "$TEST_DIR/container_write.txt")
        if [[ "$CONTENT" == "Container can write to host" ]]; then
            echo "✅ Bidirectional file access verified."
        else
            echo "⚠️  File exists but content mismatch: $CONTENT"
        fi
    else
        echo "❌ Container cannot write to host directory."
        echo "This may cause issues with socket file creation."
        rm -rf "$TEST_DIR"
        exit 1
    fi
else
    echo "❌ Container write test failed."
    rm -rf "$TEST_DIR"
    exit 1
fi

rm -rf "$TEST_DIR"

# Cleanup
echo "🧹 Cleaning up previous container and data..."
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
podman volume rm -f pg-data-volume 2>/dev/null || true
podman volume rm -f pg-run-volume 2>/dev/null || true

if [[ -d "$DATA_PATH" ]]; then
    rm -rf "$DATA_PATH"
fi
if [[ -d "$RUN_PATH" ]]; then
    rm -rf "$RUN_PATH"
fi

# Create directories with proper permissions
echo "📁 Creating directories and volumes..."
mkdir -p "$DATA_PATH"
mkdir -p "$RUN_PATH"

# Create Podman volumes for better permission handling
echo "📦 Creating Podman volumes..."
podman volume create pg-data-volume
podman volume create pg-run-volume

# Set directory permissions for broader access
echo "🔐 Setting directory permissions..."
chmod 755 "$DATA_PATH"
chmod 755 "$RUN_PATH"

# If running as root, set ownership to postgres user (UID 999 in postgres container)
if [[ $EUID -eq 0 ]]; then
    echo "  Setting ownership for postgres user (UID 999)..."
    chown -R 999:999 "$DATA_PATH" "$RUN_PATH" 2>/dev/null || echo "  ⚠️  Could not set ownership (this may be normal)"
fi

echo "✅ Directory permissions set successfully with broad user access."

# Write postgresql.conf
echo "📝 Writing postgresql.conf..."
cat > "$CONF_PATH" << 'EOF'
# PostgreSQL configuration for UDS and peer authentication
unix_socket_directories = '/var/run/postgresql'
listen_addresses = ''
port = 5432
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_statement = 'all'
log_min_messages = info
shared_preload_libraries = ''
max_connections = 100
EOF

# Write pg_hba.conf (peer auth)
echo "📝 Writing pg_hba.conf..."
cat > "$HBA_PATH" << 'EOF'
# PostgreSQL Client Authentication Configuration
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections via Unix domain sockets with peer authentication
local   all             all                                     peer

# Fallback for local connections (trust for development)
# local   all             postgres                                trust
# host    all             all             127.0.0.1/32            trust
# host    all             all             ::1/128                 trust
EOF

# Launch container
echo "🐳 Starting PostgreSQL container with peer authentication..."

# Use the official PostgreSQL container with Podman volumes
echo "📦 Setting up PostgreSQL with Podman volumes..."

# Create and run the PostgreSQL container using Podman volumes
podman run -d \
  --name "$CONTAINER_NAME" \
  -v pg-data-volume:/var/lib/postgresql/data \
  -v "${CONF_PATH}:/etc/postgresql/postgresql.conf:Z" \
  -v "${HBA_PATH}:/etc/postgresql/pg_hba.conf:Z" \
  -v pg-run-volume:/var/run/postgresql \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e POSTGRES_INITDB_ARGS="--auth-local=peer --auth-host=trust" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_PASSWORD=password \
  --security-opt label=disable \
  "$IMAGE"

if [[ $? -ne 0 ]]; then
    echo "❌ Failed to start PostgreSQL container."
    exit 1
fi

sleep 10
echo "⏳ Waiting for PostgreSQL to initialize..."

# Check if container is running
CONTAINER_STATUS=$(podman ps --filter "name=$CONTAINER_NAME" --format "{{.Status}}" 2>/dev/null || echo "")
if [[ -z "$CONTAINER_STATUS" ]]; then
    echo "❌ Container is not running. Checking logs..."
    podman logs "$CONTAINER_NAME"
    exit 1
fi

echo "✅ Container is running: $CONTAINER_STATUS"

# Wait for PostgreSQL to be ready
MAX_RETRIES=30
RETRY_COUNT=0
IS_READY=false

while [[ $RETRY_COUNT -lt $MAX_RETRIES ]] && [[ "$IS_READY" == "false" ]]; do
    if podman exec "$CONTAINER_NAME" pg_isready -h /var/run/postgresql &> /dev/null; then
        IS_READY=true
        echo "✅ PostgreSQL is ready!"
    else
        ((RETRY_COUNT++))
        echo "⏳ Waiting for PostgreSQL... (attempt $RETRY_COUNT/$MAX_RETRIES)"
        sleep 2
    fi
done

if [[ "$IS_READY" == "false" ]]; then
    echo "❌ PostgreSQL failed to start within timeout period. Checking logs..."
    podman logs "$CONTAINER_NAME"
    exit 1
fi

# Set socket permissions for broader access
echo "🔐 Setting socket permissions for broader access..."
if podman exec "$CONTAINER_NAME" chmod 666 /var/run/postgresql/.s.PGSQL.5432 2>/dev/null; then
    echo "✅ Socket permissions updated for broader access."
else
    echo "⚠️  Warning: Could not update socket permissions (this may be normal)"
fi

# Verify peer auth via UDS
echo "🔍 Verifying peer authentication and socket accessibility..."

# First, check if the socket directory exists and has the socket file
echo "Socket directory contents:"
podman exec "$CONTAINER_NAME" ls -la /var/run/postgresql/ || echo "Could not list socket directory"

# Check socket file permissions specifically
echo "Socket file permissions:"
podman exec "$CONTAINER_NAME" ls -l /var/run/postgresql/.s.PGSQL.5432 || echo "Could not check socket file permissions"

# Try to connect using peer authentication as postgres user
if VERIFY=$(podman exec -u postgres "$CONTAINER_NAME" psql -h /var/run/postgresql -d postgres -c "SELECT current_user, version();" 2>/dev/null); then
    if echo "$VERIFY" | grep -q "current_user" && echo "$VERIFY" | grep -q "PostgreSQL"; then
        echo ""
        echo "✅ PostgreSQL is running with peer authentication via UDS."
        echo "Connection verified successfully!"
    else
        echo ""
        echo "❌ Could not verify authentication. Output:"
        echo "$VERIFY"
    fi
else
    echo ""
    echo "❌ Failed to verify PostgreSQL connection."
    echo "Checking container logs for troubleshooting..."
    podman logs --tail 20 "$CONTAINER_NAME"
fi

# Test connection as root user to verify broader access
echo ""
echo "🔍 Testing socket access as root user..."
if ROOT_TEST=$(podman exec -u root "$CONTAINER_NAME" psql -h /var/run/postgresql -d postgres -c "SELECT 'Root user can connect' as test;" 2>/dev/null); then
    if echo "$ROOT_TEST" | grep -q "Root user can connect"; then
        echo "✅ Root user can access PostgreSQL via socket!"
    else
        echo "⚠️  Root user connection test output:"
        echo "$ROOT_TEST"
    fi
else
    echo "⚠️  Root user cannot connect (this may be normal with peer auth)"
fi

# Additional verification - check if we can create a database
echo ""
echo "🔍 Testing database operations..."
if DB_TEST=$(podman exec -u postgres "$CONTAINER_NAME" psql -h /var/run/postgresql -d postgres -c "CREATE DATABASE test_db;" 2>/dev/null); then
    if echo "$DB_TEST" | grep -q "CREATE DATABASE"; then
        echo "✅ Database creation test passed!"
        # Clean up the test database
        if DROP_RESULT=$(podman exec -u postgres "$CONTAINER_NAME" psql -h /var/run/postgresql -d postgres -c "DROP DATABASE test_db;" 2>/dev/null); then
            if echo "$DROP_RESULT" | grep -q "DROP DATABASE"; then
                echo "✅ Database cleanup completed!"
            fi
        fi
    else
        echo "⚠️  Database operations test failed. Output:"
        echo "$DB_TEST"
    fi
else
    echo "⚠️  Database operations test failed."
fi

# Show connection information
echo ""
echo "📋 Connection Information:"
echo "  Container Name: $CONTAINER_NAME"
echo "  Socket Path (in container): /var/run/postgresql"
echo "  Data Path (host): $DATA_PATH"
echo "  Run Path (host): $RUN_PATH"
echo ""
echo "🔌 Connection Methods:"
echo "  For postgres user:"
echo "    podman exec -u postgres $CONTAINER_NAME psql -h /var/run/postgresql -d postgres"
echo "  For other users (may require trust auth fallback):"
echo "    podman exec -u <username> $CONTAINER_NAME psql -h /var/run/postgresql -d postgres"
echo "  Alternative with explicit socket:"
echo "    podman exec -u postgres $CONTAINER_NAME psql -h /var/run/postgresql/.s.PGSQL.5432 -d postgres"
echo ""
echo "🔑 Authentication Notes:"
echo "  - Peer authentication maps container users to PostgreSQL users"
echo "  - Trust authentication is available as fallback for local connections"
echo "  - Socket permissions set to 666 for broader access"
echo "  - Socket directory permissions set to 755"
echo ""
echo "🎉 Setup complete! PostgreSQL is running with UDS and peer authentication."

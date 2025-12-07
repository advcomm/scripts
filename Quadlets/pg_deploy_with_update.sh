#!/bin/bash

#===============================================================================
# PostgreSQL Database Deployment Script
# 
# Follows the tenant/app naming convention:
# - Tenant = OS group
# - App = OS user (tenant_app)
# - UID is automatically retrieved from the OS user
#
# Handles Git updates, database backup, and PostgreSQL deployment using Podman
#===============================================================================

set -e  # Exit on any error

# Default configuration
CONTAINER_NAME="pg-root-peer"
BRANCH="main"
BYPASS_UPDATE=false

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
PostgreSQL Database Deployment Script with Repository Update

Usage: $0 [OPTIONS] <TENANT> <APP> <BACKUP_DIR> <REPO_PATH> <SSH_PATH>

Required Arguments:
  TENANT          Tenant name (OS group, e.g., 'xdoc')
  APP             App name (OS user will be tenant_app, e.g., 'xdoc_api')
  BACKUP_DIR      Directory to store database backups
  REPO_PATH       Path to the Git repository
  SSH_PATH        Path to SSH private key for Git authentication

Options:
  -h, --help              Show this help message
  -b, --bypass-update     Skip Git repository update and deploy directly
  -c, --container NAME    Specify container name (default: pg-root-peer)
  --branch BRANCH         Git branch to use (default: main)
  --db-name NAME          Database name (defaults to TENANT)
  --db-user NAME          Database user (defaults to TENANT)

Naming Convention:
  This script follows the tenant/app naming convention:
  - Tenant 'xdoc' + App 'api' = OS user 'xdoc_api'
  - The UID is automatically retrieved from the OS user
  - Database name defaults to tenant name (e.g., 'xdoc')
  - Database user defaults to tenant name (e.g., 'xdoc')

Description:
  This script performs the following operations:
  1. Updates Git repository (unless --bypass-update is used)
  2. Creates database backup if database exists
  3. Deploys PostgreSQL database with appropriate SQL scripts
  
  If database doesn't exist:
    - Creates OS user in container for peer authentication (using UID from host)
    - Creates the database and user with privileges
    - Runs schema.sql, procs.sql, and templates.sql
  
  If database exists:
    - Creates backup before deployment
    - Runs only alter.sql (preserves existing data)

Workflow (Database First):
  1. Install PostgreSQL with tenant/app:
     ./install_postgres_quadlet.sh install --tenant xdoc --app api
     
  2. Deploy database (this script):
     $0 xdoc api /backup /repo ~/.ssh/id_rsa

  3. Provision API app:
     ./provision-tenant-app.sh provision xdoc api docker.io/myapp:latest "3000:3000"

Examples:
  # Basic usage (database=xdoc, user=xdoc, UID from xdoc_api)
  $0 xdoc api /backup /repo ~/.ssh/id_rsa

  # With custom database name
  $0 xdoc api /backup /repo ~/.ssh/id_rsa --db-name mydb

  # Bypass git update
  $0 -b xdoc api /backup /repo ~/.ssh/id_rsa

  # Custom container
  $0 -c my-postgres xdoc api /backup /repo ~/.ssh/id_rsa
EOF
}

# Variables to be set
TENANT_NAME=""
APP_NAME=""
BACKUP_DIR=""
REPO_PATH=""
SSH_PATH=""
DATABASE_NAME=""
POSTGRES_USER=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -b|--bypass-update)
            BYPASS_UPDATE=true
            shift
            ;;
        -c|--container)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --db-name)
            DATABASE_NAME="$2"
            shift 2
            ;;
        --db-user)
            POSTGRES_USER="$2"
            shift 2
            ;;
        -*)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Validate required arguments
if [ $# -lt 5 ]; then
    log_error "Missing required arguments"
    show_help
    exit 1
fi

# Set variables from arguments
TENANT_NAME="$1"
APP_NAME="$2"
BACKUP_DIR="$3"
REPO_PATH="$4"
SSH_PATH="$5"

# Derive names from tenant/app convention
APP_USER="${TENANT_NAME}_${APP_NAME}"
DATABASE_NAME="${DATABASE_NAME:-$TENANT_NAME}"    # Default to tenant name
POSTGRES_USER="${POSTGRES_USER:-$TENANT_NAME}"    # Default to tenant name

# Get UID from OS user (must exist - created by install_postgres_quadlet.sh)
if ! id "$APP_USER" > /dev/null 2>&1; then
    log_error "OS user '$APP_USER' not found!"
    log_error "Please run install_postgres_quadlet.sh first:"
    log_error "  ./install_postgres_quadlet.sh install --tenant $TENANT_NAME --app $APP_NAME"
    exit 1
fi

OS_USER_UID=$(id -u "$APP_USER")
OS_USER_GID=$(id -g "$APP_USER")

# Generate backup and log file names
BACKUP_FILE="$BACKUP_DIR/${DATABASE_NAME}_backup_$(date +%s%3N).sql"
LOG_FILE="$BACKUP_DIR/${DATABASE_NAME}_update_log_$(date +%s%3N).log"

log_info "Starting PostgreSQL deployment process..."
log_info "Configuration:"
echo "  Tenant: $TENANT_NAME"
echo "  App: $APP_NAME"
echo "  App User: $APP_USER (UID: $OS_USER_UID, GID: $OS_USER_GID)"
echo "  Container: $CONTAINER_NAME"
echo "  Database: $DATABASE_NAME"
echo "  DB User: $POSTGRES_USER"
echo "  Repository: $REPO_PATH"
echo "  Backup Dir: $BACKUP_DIR"
echo "  Bypass Update: $BYPASS_UPDATE"
echo ""

# Function to update repository
update_repository() {
    if [[ "$BYPASS_UPDATE" == "true" ]]; then
        log_info "Bypassing repository update as requested."
        return 0
    fi
    
    log_info "Updating repository..."
    
    # Ensure backup directory exists
    mkdir -p "$BACKUP_DIR"
    
    # Navigate to the repository
    cd "$REPO_PATH" || { log_error "Repository path not found: $REPO_PATH"; exit 1; }
    
    # Fetch updates from the remote repository
    log_info "Fetching updates from remote repository..."
    GIT_SSH_COMMAND="ssh -i ${SSH_PATH} -o StrictHostKeyChecking=no" git fetch origin
    
    # Check for changes
    log_info "Checking for changes in branch $BRANCH..."
    local changes=$(GIT_SSH_COMMAND="ssh -i ${SSH_PATH} -o StrictHostKeyChecking=no" git diff --name-only "origin/$BRANCH")
    
    # If no changes are detected, continue anyway (we might want to redeploy)
    if [[ -z "$changes" ]]; then
        log_info "No changes detected. Repository is up-to-date."
    else
        # If changes are detected, pull the latest changes
        log_info "Changes detected. Pulling latest updates..."
        GIT_SSH_COMMAND="ssh -i ${SSH_PATH} -o StrictHostKeyChecking=no" git reset --hard "origin/$BRANCH" || { 
            log_error "Failed to pull updates from branch $BRANCH."; 
            exit 1; 
        }
        log_success "Repository updated successfully."
        
        # Log changed files
        log_info "Changed files:"
        echo "$changes" | while read -r file; do
            echo "  - $file"
        done
    fi
}

# Function to check if container exists and is running
check_container() {
    log_info "Checking if container '$CONTAINER_NAME' exists..."
    
    if ! podman ps -a --format "table {{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        log_error "Container '$CONTAINER_NAME' not found!"
        log_error "Please ensure the PostgreSQL container is created and running."
        log_error "You can use pg_install.sh to create the container."
        exit 1
    fi
    
    # Check if container is running
    if ! podman ps --format "table {{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        log_warning "Container '$CONTAINER_NAME' exists but is not running."
        log_info "Starting container '$CONTAINER_NAME'..."
        podman start "$CONTAINER_NAME"
        sleep 5  # Wait for container to fully start
    fi
    
    log_success "Container '$CONTAINER_NAME' is running."
}

# Function to create OS user in container for peer authentication
create_os_user() {
    log_info "Ensuring OS user '$POSTGRES_USER' exists in container for peer authentication..."
    
    # Check if OS user exists
    if podman exec --user root "$CONTAINER_NAME" id -u "$POSTGRES_USER" >/dev/null 2>&1; then
        local existing_uid=$(podman exec --user root "$CONTAINER_NAME" id -u "$POSTGRES_USER")
        if [[ "$existing_uid" == "$OS_USER_UID" ]]; then
            log_success "OS user '$POSTGRES_USER' already exists with correct UID $OS_USER_UID."
        else
            log_warning "OS user '$POSTGRES_USER' exists but with different UID $existing_uid (expected $OS_USER_UID)."
            log_info "Updating UID for existing user '$POSTGRES_USER'..."
            if podman exec --user root "$CONTAINER_NAME" usermod -u "$OS_USER_UID" "$POSTGRES_USER"; then
                log_success "OS user '$POSTGRES_USER' UID updated to $OS_USER_UID."
            else
                log_error "Failed to update UID for OS user '$POSTGRES_USER'"
                exit 1
            fi
        fi
    else
        log_info "Creating OS user '$POSTGRES_USER' in container with UID $OS_USER_UID..."
        if podman exec --user root "$CONTAINER_NAME" useradd -u "$OS_USER_UID" "$POSTGRES_USER"; then
            log_success "OS user '$POSTGRES_USER' created in container with UID $OS_USER_UID."
        else
            log_error "Failed to create OS user '$POSTGRES_USER' in container"
            exit 1
        fi
    fi
    
    # Verify the final UID
    local final_uid=$(podman exec --user root "$CONTAINER_NAME" id -u "$POSTGRES_USER")
    log_info "OS user '$POSTGRES_USER' has UID: $final_uid"
}

# Function to check if database user exists
check_database_user() {
    log_info "Checking if database user '$POSTGRES_USER' exists..."
    
    local user_exists=$(podman exec -u postgres "$CONTAINER_NAME" psql -h /var/run/postgresql -t -c "SELECT 1 FROM pg_roles WHERE rolname='$POSTGRES_USER';" 2>/dev/null | xargs || echo "")
    
    if [[ "$user_exists" == "1" ]]; then
        log_success "Database user '$POSTGRES_USER' exists."
        return 0
    else
        log_info "Database user '$POSTGRES_USER' does not exist."
        return 1
    fi
}

# Function to create and configure database user
create_database_user() {
    log_info "Creating and configuring database user '$POSTGRES_USER'..."
    
    # Create user if it doesn't exist
    if ! check_database_user; then
        log_info "Creating database user '$POSTGRES_USER' with CREATEDB privilege..."
        if podman exec -u postgres "$CONTAINER_NAME" psql -h /var/run/postgresql -c "CREATE USER $POSTGRES_USER WITH CREATEDB;"; then
            log_success "Database user '$POSTGRES_USER' created with CREATEDB privilege."
        else
            log_error "Failed to create database user '$POSTGRES_USER'"
            exit 1
        fi
    else
        # User exists, ensure they have CREATEDB privilege
        log_info "Ensuring user '$POSTGRES_USER' has CREATEDB privilege..."
        if podman exec -u postgres "$CONTAINER_NAME" psql -h /var/run/postgresql -c "ALTER USER $POSTGRES_USER CREATEDB;"; then
            log_success "CREATEDB privilege granted to user '$POSTGRES_USER'."
        else
            log_error "Failed to grant CREATEDB privilege to user '$POSTGRES_USER'"
            exit 1
        fi
    fi
}

# Function to create database
create_database() {
    log_info "Creating database '$DATABASE_NAME' owned by user '$POSTGRES_USER'..."
    
    # Create database with the specified user as owner, connecting to postgres database first
    if podman exec -u "$POSTGRES_USER" "$CONTAINER_NAME" psql -h /var/run/postgresql -d postgres -c "CREATE DATABASE $DATABASE_NAME;"; then
        log_success "Database '$DATABASE_NAME' created and owned by user '$POSTGRES_USER'."
    else
        log_error "Failed to create database '$DATABASE_NAME' as user '$POSTGRES_USER'"
        exit 1
    fi
    
    # Verify database ownership
    log_info "Verifying database ownership..."
    local db_owner=$(podman exec -u postgres "$CONTAINER_NAME" psql -h /var/run/postgresql -t -c "SELECT pg_catalog.pg_get_userbyid(d.datdba) FROM pg_catalog.pg_database d WHERE d.datname = '$DATABASE_NAME';" 2>/dev/null | xargs || echo "")
    
    if [[ "$db_owner" == "$POSTGRES_USER" ]]; then
        log_success "Database '$DATABASE_NAME' is owned by user '$POSTGRES_USER'."
    else
        log_warning "Database owner verification failed. Expected: '$POSTGRES_USER', Found: '$db_owner'"
    fi
}

# Function to check database existence
check_database() {
    log_info "Checking if database '$DATABASE_NAME' exists..."
    
    # Check database existence using postgres superuser
    local db_exists=$(podman exec -u postgres "$CONTAINER_NAME" psql -h /var/run/postgresql -t -c "SELECT 1 FROM pg_database WHERE datname='$DATABASE_NAME';" 2>/dev/null | xargs || echo "")
    
    if [[ "$db_exists" == "1" ]]; then
        log_success "Database '$DATABASE_NAME' exists."
        return 0
    else
        log_info "Database '$DATABASE_NAME' does not exist."
        return 1
    fi
}

# Function to backup database
backup_database() {
    log_info "Creating backup of database '$DATABASE_NAME'..."
    
    if podman exec -u postgres "$CONTAINER_NAME" pg_dump -h /var/run/postgresql "$DATABASE_NAME" > "$BACKUP_FILE" 2>>"$LOG_FILE"; then
        log_success "Backup created successfully: $BACKUP_FILE"
        return 0
    else
        log_error "Backup failed. Check log file: $LOG_FILE"
        return 1
    fi
}

# Function to create database with full setup
create_database_with_setup() {
    log_info "Setting up database with full configuration..."
    
    # Step 1: Create OS user in container for peer authentication
    create_os_user
    
    # Step 2: Create and configure database user with CREATEDB privilege
    create_database_user
    
    # Step 3: Create database owned by the user
    create_database
    
    log_success "Database setup completed successfully."
    log_info "Database '$DATABASE_NAME' is owned by user '$POSTGRES_USER' and ready for use."
}

# Function to run SQL script in container
run_sql_script() {
    local script_name="$1"
    local script_path="$REPO_PATH/postgres/$script_name"
    
    if [[ ! -f "$script_path" ]]; then
        log_warning "Script '$script_name' not found in '$REPO_PATH/postgres/'. Skipping..."
        return 0
    fi
    
    log_info "Running script: $script_name"
    
    # Copy script to container and execute it
    podman cp "$script_path" "$CONTAINER_NAME:/tmp/$script_name"
    
    if podman exec -u "$POSTGRES_USER" "$CONTAINER_NAME" psql -h /var/run/postgresql -d "$DATABASE_NAME" -f "/tmp/$script_name" 2>>"$LOG_FILE"; then
        log_success "Script '$script_name' executed successfully."
        # Clean up the temporary file
        podman exec -u root "$CONTAINER_NAME" rm -f "/tmp/$script_name"
    else
        log_error "Failed to execute script '$script_name'"
        log_error "Check log file: $LOG_FILE"
        podman exec -u root "$CONTAINER_NAME" rm -f "/tmp/$script_name"
        exit 1
    fi
}

# Function to run all initialization scripts
run_all_scripts() {
    log_info "Database not found. Running all initialization scripts..."
    
    # List of scripts to run in order
    local scripts=(
        "schema.sql"
        "procs.sql" 
        "templates.sql"
    )
    
    for script in "${scripts[@]}"; do
        run_sql_script "$script"
    done
    
    log_success "All initialization scripts completed successfully."
}

# Function to run only alter script
run_alter_script() {
    log_info "Database exists. Running only alter.sql..."
    run_sql_script "alter.sql"
    log_success "Alter script completed successfully."
}

# Main execution function
main() {
    # Step 1: Update repository (unless bypassed)
    update_repository
    
    # Step 2: Check if Podman is available
    if ! command -v podman &> /dev/null; then
        log_error "Podman is not installed or not in PATH."
        exit 1
    fi
    
    # Step 3: Check container existence and status
    check_container
    
    # Step 4: Wait for PostgreSQL to be ready
    log_info "Waiting for PostgreSQL to be ready..."
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if podman exec -u postgres "$CONTAINER_NAME" pg_isready -h /var/run/postgresql >/dev/null 2>&1; then
            log_success "PostgreSQL is ready."
            break
        fi
        
        log_info "Waiting for PostgreSQL to be ready... (attempt $attempt/$max_attempts)"
        sleep 2
        ((attempt++))
    done
    
    if [[ $attempt -gt $max_attempts ]]; then
        log_error "PostgreSQL failed to become ready within the timeout period."
        exit 1
    fi
    
    # Step 5: Check database existence and handle accordingly
    if check_database; then
        # Database exists - create backup first, then run alter.sql
        if backup_database; then
            log_info "Backup completed successfully."
        else
            log_warning "Backup failed, but continuing with deployment..."
        fi
        
        # Ensure user exists and has proper privileges before running scripts
        if ! check_database_user; then
            create_os_user
            create_database_user
            
            # Since database already exists, grant ownership to the user
            log_info "Granting database ownership to user '$POSTGRES_USER'..."
            if podman exec -u postgres "$CONTAINER_NAME" psql -h /var/run/postgresql -c "ALTER DATABASE $DATABASE_NAME OWNER TO $POSTGRES_USER;"; then
                log_success "Database ownership transferred to user '$POSTGRES_USER'."
            else
                log_warning "Failed to transfer database ownership, but continuing..."
            fi
            
            # Grant all privileges on existing objects
            log_info "Granting privileges on existing database objects..."
            podman exec -u postgres "$CONTAINER_NAME" psql -h /var/run/postgresql -d "$DATABASE_NAME" -c "
                GRANT ALL PRIVILEGES ON DATABASE $DATABASE_NAME TO $POSTGRES_USER;
                GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $POSTGRES_USER;
                GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $POSTGRES_USER;
                GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO $POSTGRES_USER;
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $POSTGRES_USER;
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $POSTGRES_USER;
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO $POSTGRES_USER;
            " 2>/dev/null || log_warning "Some privilege grants may have failed"
        fi
        
        run_alter_script
    else
        # Database doesn't exist - create it with full setup and run all scripts
        create_database_with_setup
        run_all_scripts
    fi
    
    log_success "Deployment completed successfully!"
    echo ""
    log_info "Database '$DATABASE_NAME' is ready for use"
    echo ""
    log_info "Connection Information:"
    echo "  Container: $CONTAINER_NAME"
    echo "  Database: $DATABASE_NAME"
    echo "  User: $POSTGRES_USER (UID: $OS_USER_UID)"
    echo "  Connect: podman exec --user $POSTGRES_USER -it $CONTAINER_NAME psql -h /var/run/postgresql -d $DATABASE_NAME"
    
    if [[ -f "$BACKUP_FILE" ]]; then
        echo "  Backup: $BACKUP_FILE"
    fi
    echo "  Log File: $LOG_FILE"
}

# Run main function
main "$@"

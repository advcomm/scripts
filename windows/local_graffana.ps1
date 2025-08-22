# local_grafana.ps1
# Run this as Administrator

$ErrorActionPreference = 'Stop'

# Parameters
$pgContainer = "pg-root-peer"
$grafanaContainer = "grafana"
$udsHostPath = "C:\pg_socket"
$grafanaVolume = "grafana-data"
$pgImage = "postgres:16"
$grafanaImage = "grafana/grafana-oss"
$pgUser = "grafana"
$pgUid = 472
$grafanaPort = 9000

# Check Podman availability
if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
    "Installing Podman via winget..."
    winget install -e --id RedHat.Podman
} else {
    "Podman is installed."
}

# Check PostgreSQL container
$pgStatus = podman inspect -f "{{.State.Status}}" $pgContainer 2>$null
if (-not $pgStatus) {
    throw "PostgreSQL container '$pgContainer' not found. Please start it first."
}
if ($pgStatus -ne "running") {
    throw "PostgreSQL container '$pgContainer' is not running. Please start it first."
}
"PostgreSQL container '$pgContainer' is running."

# Create Grafana volume if not exists
if (-not (podman volume exists $grafanaVolume)) {
    podman volume create $grafanaVolume | Out-Null
    "Created Grafana volume: $grafanaVolume"
}

# Create system user in PostgreSQL container first
"Creating system user with UID $pgUid in PostgreSQL container..."
# If user exists, update UID; else, create user with UID 472
$existingUid = podman exec $pgContainer sh -c "id -u $pgUser 2>/dev/null || echo ''"
if ($existingUid -and $existingUid -ne $pgUid) {
    podman exec $pgContainer usermod -u $pgUid $pgUser
} elseif (-not $existingUid) {
    podman exec $pgContainer useradd -u $pgUid -r -s /bin/false $pgUser
}

# Create PostgreSQL user if missing
"Creating PostgreSQL user '$pgUser' (if needed)..."
$userCheck = podman exec --user postgres $pgContainer psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$pgUser'" 2>$null
if ($userCheck -ne "1") {
    podman exec --user postgres $pgContainer createuser -s $pgUser
    "PostgreSQL user '$pgUser' created."
    # Grant access to all databases
    $dbList = podman exec --user postgres $pgContainer psql -tAc "SELECT datname FROM pg_database WHERE datistemplate = false;"
    foreach ($db in $dbList -split "\r?\n") {
        if ($db.Trim()) {
            podman exec --user postgres $pgContainer psql -d $db -c "GRANT ALL PRIVILEGES ON DATABASE $db TO $pgUser;"
        }
    }
    "Granted access to all databases for user '$pgUser'."
} else {
    "PostgreSQL user '$pgUser' already exists."
    # Grant access to all databases even if user exists
    $dbList = podman exec --user postgres $pgContainer psql -tAc "SELECT datname FROM pg_database WHERE datistemplate = false;"
    foreach ($db in $dbList -split "\r?\n") {
        if ($db.Trim()) {
            podman exec --user postgres $pgContainer psql -d $db -c "GRANT ALL PRIVILEGES ON DATABASE $db TO $pgUser;"
        }
    }
    "Ensured access to all databases for user '$pgUser'."
}

# Remove old Grafana container if exists
podman rm -f $grafanaContainer -v 2>$null

# Start Grafana container as grafana user (UID 472)
"Starting Grafana container as grafana user (UID 472)..."
$containerId = podman run -d `
    --name $grafanaContainer `
    --user $pgUid `
    -e GF_SECURITY_ADMIN_USER=admin `
    -e GF_SECURITY_ADMIN_PASSWORD=admin `
    -p "${grafanaPort}:3000" `
    -v "${grafanaVolume}:/var/lib/grafana:Z" `
    -v "pg-run-volume:/var/run/postgresql" `
    $grafanaImage

# Verify container is running
Start-Sleep -Seconds 2
$grafanaStatus = podman inspect -f "{{.State.Status}}" $grafanaContainer 2>$null
if ($grafanaStatus -eq "running") {
    "Grafana container started successfully with ID: $containerId"
} else {
    "Failed to start Grafana container. Status: $grafanaStatus"
    "Container logs:"
    podman logs $grafanaContainer
    throw "Grafana container failed to start"
}

# Summary output
"`nGrafana is running at: http://localhost:$grafanaPort`n"
"Grafana PostgreSQL Data Source Settings:"
"  Host: /var/run/postgresql"
"  Database: postgres"
"  User: (leave blank)"
"  Auth: peer (via UID $pgUid)"
"Ensure pg_hba.conf includes:"
"  local all grafana peer (via UID $pgUid)"
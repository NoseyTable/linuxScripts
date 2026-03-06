#!/usr/bin/env bash
###############################################################################
# opengate-prereq.sh
# Prepares a Rocky Linux 9.x host for Enghouse OpenGate Containers deployment.
#
# What it does:
#   1. Sets timezone to Africa/Johannesburg
#   2. Installs Docker CE + Compose v2 plugin from the official Docker repo
#   3. Configures Docker daemon with link-local /26 subnets (169.254.64.0/26+)
#      to avoid collisions with real RFC1918 infrastructure
#   4. Enables and starts the Docker service
#
# Assumptions:
#   - Rocky Linux 9.x (fresh or existing)
#   - Run as root or with sudo
#   - Internet access to download.docker.com
#   - No existing Docker installation from distro repos (script removes conflicts)
#
# Log: /var/log/opengate-prereq.log
###############################################################################
set -euo pipefail

# ── Variables ────────────────────────────────────────────────────────────────
LOGFILE="/var/log/opengate-prereq.log"
TIMEZONE="Africa/Johannesburg"
DOCKER_BRIDGE_BIP="169.254.64.1/26"         # gateway IP for default bridge
DOCKER_POOL_BASE="169.254.64.0/18"         # large block Docker carves /26s from
DOCKER_POOL_SIZE=26                         # each compose network gets a /26
DAEMON_JSON="/etc/docker/daemon.json"

# ── Logging ──────────────────────────────────────────────────────────────────
exec > >(tee -a "${LOGFILE}") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    log "FATAL: $*"
    exit 1
}

# ── Pre-flight checks ───────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root."

if ! grep -qi 'rocky' /etc/os-release 2>/dev/null; then
    die "This script targets Rocky Linux 9.x. Detected a different OS."
fi

MAJOR_VER=$(rpm -E %{rhel} 2>/dev/null || echo "0")
[[ "${MAJOR_VER}" == "9" ]] || die "Expected Rocky Linux 9.x, got major version ${MAJOR_VER}."

log "=== OpenGate prerequisite script starting ==="
log "Host: $(hostname) | OS: $(cat /etc/redhat-release) | Kernel: $(uname -r)"

# ── Step 1: Timezone ─────────────────────────────────────────────────────────
log "Setting timezone to ${TIMEZONE} ..."
timedatectl set-timezone "${TIMEZONE}"
log "Timezone confirmed: $(timedatectl show --property=Timezone --value)"

# ── Step 2: Remove conflicting packages ──────────────────────────────────────
log "Removing any conflicting container packages from distro repos ..."
CONFLICTS=(
    docker
    docker-client
    docker-client-latest
    docker-common
    docker-latest
    docker-latest-logrotate
    docker-logrotate
    docker-engine
    podman
    buildah
    containers-common
)

# dnf remove returns non-zero if nothing matched; tolerate that
dnf remove -y "${CONFLICTS[@]}" 2>/dev/null || true
log "Conflict removal complete."

# ── Step 3: Add Docker CE repo ───────────────────────────────────────────────
log "Adding Docker CE repository ..."
dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
log "Docker CE repo added."

# ── Step 4: Install Docker CE + Compose plugin ───────────────────────────────
log "Installing Docker CE, CLI, containerd, and Compose plugin ..."
dnf install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
log "Docker packages installed."

# ── Step 5: Configure daemon.json ────────────────────────────────────────────
log "Writing Docker daemon configuration to ${DAEMON_JSON} ..."
mkdir -p /etc/docker

cat > "${DAEMON_JSON}" <<DAEMONJSON
{
  "bip": "${DOCKER_BRIDGE_BIP}",
  "default-address-pools": [
    {
      "base": "${DOCKER_POOL_BASE}",
      "size": ${DOCKER_POOL_SIZE}
    }
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  },
  "storage-driver": "overlay2",
  "live-restore": true
}
DAEMONJSON

log "daemon.json written:"
cat "${DAEMON_JSON}"

# ── Step 6: Enable and start Docker ──────────────────────────────────────────
log "Enabling and starting Docker service ..."
systemctl enable --now docker
systemctl enable --now containerd

log "Docker service status:"
systemctl is-active docker
docker --version
docker compose version

# ── Step 7: Verify networking ────────────────────────────────────────────────
log "Verifying Docker bridge network ..."
# Docker needs a moment after first start to create the bridge
sleep 2
BRIDGE_SUBNET=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "NOT_READY")

if [[ "${BRIDGE_SUBNET}" == "169.254.64.0/26" ]]; then
    log "Bridge subnet confirmed: ${BRIDGE_SUBNET}"
else
    log "WARNING: Bridge subnet is '${BRIDGE_SUBNET}', expected '169.254.64.0/26'."
    log "Docker may need a restart. Attempting restart ..."
    systemctl restart docker
    sleep 2
    BRIDGE_SUBNET=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || echo "FAILED")
    log "After restart, bridge subnet: ${BRIDGE_SUBNET}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
log "=== OpenGate prerequisite script completed ==="
log "Timezone:        $(timedatectl show --property=Timezone --value)"
log "Docker version:  $(docker --version)"
log "Compose version: $(docker compose version)"
log "Bridge subnet:   ${BRIDGE_SUBNET}"
log "Pool base:       ${DOCKER_POOL_BASE} (each network: /${DOCKER_POOL_SIZE})"
log "Log file:        ${LOGFILE}"
log ""
log "Next step: Run the OpenGate install script for your chosen mode (master, node, etc.)"

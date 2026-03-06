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
ENGHOUSE_FTP="ftp.emea.enghouseinteractive.com"
ENGHOUSE_REGISTRY="opengate.azurecr.io"

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

# ── Confirmation ─────────────────────────────────────────────────────────────
echo ""
echo "======================================================================"
echo "  OpenGate Prerequisites    What this script will do:"
echo "======================================================================"
echo ""
echo "  1. Set timezone to ${TIMEZONE}"
echo "  2. Remove conflicting packages (podman, buildah, distro docker)"
echo "  3. Add the official Docker CE repo (download.docker.com)"
echo "  4. Install: docker-ce, docker-ce-cli, containerd.io,"
echo "              docker-buildx-plugin, docker-compose-plugin"
echo "  5. Write ${DAEMON_JSON} with:"
echo "       Bridge gateway : ${DOCKER_BRIDGE_BIP}"
echo "       Network pool   : ${DOCKER_POOL_BASE} carved into /${DOCKER_POOL_SIZE} subnets"
echo "       Log rotation   : 20MB x 5 files"
echo "       Storage driver : overlay2"
echo "       Live restore   : enabled"
echo "  6. Enable and start Docker + containerd services"
echo ""
echo "  Log file: ${LOGFILE}"
echo ""
echo "======================================================================"
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    log "User declined. Exiting."
    exit 0
fi
echo ""

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

# ── Step 8: Connectivity tests ───────────────────────────────────────────────
log "Testing connectivity to Enghouse services ..."

# Detect this host's primary IP (the one with a default route)
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $NF; exit}')
if [[ -z "${HOST_IP}" ]]; then
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
HOST_IP="${HOST_IP:-UNKNOWN}"
SSH_USER=$(logname 2>/dev/null || whoami)

# Test FTP (port 21)
FTP_STATUS="FAILED"
if curl -s --max-time 10 --connect-timeout 5 "ftps://${ENGHOUSE_FTP}/" -u "OpenGate_Update:Op3nG3t3" --list-only >/dev/null 2>&1; then
    FTP_STATUS="OK"
elif timeout 5 bash -c "echo >/dev/tcp/${ENGHOUSE_FTP}/21" 2>/dev/null; then
    FTP_STATUS="PORT_OPEN_AUTH_FAILED"
else
    FTP_STATUS="BLOCKED"
fi

# Test container registry (port 443)
REGISTRY_STATUS="FAILED"
if curl -s --max-time 10 --connect-timeout 5 "https://${ENGHOUSE_REGISTRY}/v2/" >/dev/null 2>&1; then
    REGISTRY_STATUS="OK"
elif timeout 5 bash -c "echo >/dev/tcp/${ENGHOUSE_REGISTRY}/443" 2>/dev/null; then
    REGISTRY_STATUS="PORT_OPEN"
else
    REGISTRY_STATUS="BLOCKED"
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
echo ""
echo "======================================================================"
echo "  Connectivity Test Results"
echo "======================================================================"
echo ""

if [[ "${FTP_STATUS}" == "OK" ]]; then
    echo "  FTP  (${ENGHOUSE_FTP}):       REACHABLE"
    echo ""
    echo "  You can use Method A (direct download). Run on this host:"
    echo ""
    echo "    bash -c \"\$(curl -s ftps://OpenGate_Update:Op3nG3t3@${ENGHOUSE_FTP}/install.sh)\" MODE"
    echo ""
    echo "  Replace MODE with: master | masterwebrtc | node | nodewebrtc | webrtc | turn"
    echo "  Optional flags: -norecording  -asterisk22"
    echo ""
elif [[ "${FTP_STATUS}" == "PORT_OPEN_AUTH_FAILED" ]]; then
    echo "  FTP  (${ENGHOUSE_FTP}):       PORT OPEN, AUTH TEST INCONCLUSIVE"
    echo "  FTP port 21 is reachable. Try Method A first."
    echo ""
else
    echo "  FTP  (${ENGHOUSE_FTP}):       BLOCKED"
    echo ""
    echo "  FTP is not reachable from this host. Use Method B instead."
    echo "  Run the following on your local workstation to download and transfer"
    echo "  the install script to this server."
    echo ""
    echo "  Step 1: Download the script (run on your local machine)"
    echo ""
    echo "    Windows (cmd or PowerShell):"
    echo "      curl.exe -s \"ftps://OpenGate_Update:Op3nG3t3@${ENGHOUSE_FTP}/install.sh\" -o install.sh"
    echo ""
    echo "    macOS (Terminal):"
    echo "      curl -s \"ftps://OpenGate_Update:Op3nG3t3@${ENGHOUSE_FTP}/install.sh\" -o install.sh"
    echo ""
    echo "    Fallback: Use FileZilla/WinSCP to ${ENGHOUSE_FTP}"
    echo "              Username: OpenGate_Update   Password: Op3nG3t3"
    echo ""
    echo "  Step 2: Transfer to this server (run on your local machine)"
    echo ""
    echo "      scp install.sh ${SSH_USER}@${HOST_IP}:~/install.sh"
    echo ""
    echo "  Step 3: Run on this server"
    echo ""
    echo "      chmod +x ~/install.sh"
    echo "      sudo ~/install.sh MODE"
    echo ""
    echo "  Replace MODE with: master | masterwebrtc | node | nodewebrtc | webrtc | turn"
    echo "  Optional flags: -norecording  -asterisk22"
    echo ""
fi

if [[ "${REGISTRY_STATUS}" == "OK" || "${REGISTRY_STATUS}" == "PORT_OPEN" ]]; then
    echo "  Registry (${ENGHOUSE_REGISTRY}):       REACHABLE"
    echo "  Docker image pulls will work from this host."
else
    echo "  Registry (${ENGHOUSE_REGISTRY}):       BLOCKED"
    echo "  HTTPS to the container registry is blocked."
    echo "  Docker image pulls will fail. You need outbound access"
    echo "  to ${ENGHOUSE_REGISTRY} on port 443 before proceeding."
fi

echo ""
echo "======================================================================"
echo ""
log "FTP connectivity:      ${FTP_STATUS}"
log "Registry connectivity: ${REGISTRY_STATUS}"
log "Host IP:               ${HOST_IP}"
log ""
log "Next step: Run the OpenGate install script for your chosen mode (master, node, etc.)"

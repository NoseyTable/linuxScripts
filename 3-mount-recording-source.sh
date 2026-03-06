#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mount-smb-source.sh
# Mount a remote Windows SMB share as a recording source
# Rocky Linux 9.x
# Idempotent: safe to rerun
# =============================================================================

LOGFILE="/var/log/mount-smb-source.log"
SAMBA_USER="recordings"
MAX_ATTEMPTS=3

log() {
    local msg
    msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$msg" | tee -a "$LOGFILE"
}

die() {
    log "FATAL: $1"
    exit 1
}

# ---- Pre-flight checks -----------------------------------------------------

[[ $(id -u) -eq 0 ]] || die "This script must be run as root."

# ---- Explanation and confirmation -------------------------------------------

echo ""
echo "======================================================================"
echo "  Mount SMB Source             What this script will do:"
echo "======================================================================"
echo ""
echo "  1. Install required packages if missing:"
echo "       cifs-utils, samba-client"
echo "  2. Prompt for tenant number (determines mount at /mnt/<tenant>-recordings)"
echo "  3. Gather remote server connection details (IP, share, credentials)"
echo "  4. Test connectivity to the remote SMB share (up to ${MAX_ATTEMPTS} attempts)"
echo "  5. Create a credentials file at /root/.smb-<tenant>-recordings"
echo "       Permissions locked to 0600 (root only)"
echo "  6. Add a CIFS mount entry to /etc/fstab with:"
echo "       SMB version    : 3.0"
echo "       Mount options  : noperm, _netdev (waits for network at boot)"
echo "       UID/GID        : ${SAMBA_USER}"
echo "  7. Mount the remote share"
echo ""
echo "  Log file : ${LOGFILE}"
echo ""
echo "======================================================================"
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    log "User declined. Exiting."
    exit 0
fi
echo ""

# ---- Step 0: Ensure required packages are installed -------------------------

log "Step 0: Checking required packages"

PACKAGES=(cifs-utils samba-client)
INSTALL_NEEDED=()

for pkg in "${PACKAGES[@]}"; do
    if ! rpm -q "$pkg" &>/dev/null; then
        INSTALL_NEEDED+=("$pkg")
    fi
done

if [[ ${#INSTALL_NEEDED[@]} -gt 0 ]]; then
    log "Installing: ${INSTALL_NEEDED[*]}"
    dnf install -y "${INSTALL_NEEDED[@]}"
    log "Packages installed"
else
    log "All required packages already installed"
fi

# ---- Step 1: Select tenant --------------------------------------------------

echo ""
while true; do
    read -rp "Enter tenant number (e.g. 1 for t1, 2 for t2): " TENANT_NUM
    if [[ "$TENANT_NUM" =~ ^[0-9]+$ ]] && (( TENANT_NUM >= 1 )); then
        break
    fi
    echo "Invalid tenant number. Enter a positive integer."
done

TENANT_PREFIX="t${TENANT_NUM}"
MOUNT_POINT="/mnt/${TENANT_PREFIX}-recordings"

log "Tenant selected: $TENANT_PREFIX"
log "Mount point will be: $MOUNT_POINT"

if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    die "$MOUNT_POINT is already mounted. Unmount it first if you need to reconfigure."
fi

# ---- Step 2: Gather connection details --------------------------------------

echo ""
echo "Enter the connection details for the remote Windows server."
echo ""

ATTEMPT=0

while (( ATTEMPT < MAX_ATTEMPTS )); do
    ATTEMPT=$((ATTEMPT + 1))

    if (( ATTEMPT > 1 )); then
        echo ""
        echo "Attempt ${ATTEMPT} of ${MAX_ATTEMPTS}. Re-enter connection details."
        echo ""
    fi

    read -rp "Server IP address: " SERVER_IP
    read -rp "Share name [recordings]: " SHARE_NAME
    SHARE_NAME="${SHARE_NAME:-recordings}"
    read -rp "Domain (leave blank if not domain joined): " SMB_DOMAIN
    read -rp "Username: " SMB_USERNAME
    read -rsp "Password: " SMB_PASSWORD
    echo ""

    # Build the smbclient auth string
    if [[ -n "$SMB_DOMAIN" ]]; then
        SMB_AUTH_STRING="${SMB_DOMAIN}/${SMB_USERNAME}%${SMB_PASSWORD}"
    else
        SMB_AUTH_STRING="${SMB_USERNAME}%${SMB_PASSWORD}"
    fi

    # ---- Step 3: Test access ------------------------------------------------

    log "Step 3: Testing access to //${SERVER_IP}/${SHARE_NAME} (attempt ${ATTEMPT})"
    echo ""
    echo "Testing connection to //${SERVER_IP}/${SHARE_NAME} ..."

    if smbclient "//${SERVER_IP}/${SHARE_NAME}" \
        -U "${SMB_AUTH_STRING}" \
        -c "ls" \
        2>&1 | tee /tmp/smbtest_output.tmp | grep -qE "blocks of size|blocks available"; then
        echo ""
        echo "Connection successful."
        log "Connection test passed"
        rm -f /tmp/smbtest_output.tmp
        break
    else
        echo ""
        echo "Connection failed. Output from smbclient:"
        echo ""
        cat /tmp/smbtest_output.tmp
        rm -f /tmp/smbtest_output.tmp
        log "Connection test failed (attempt ${ATTEMPT})"

        if (( ATTEMPT >= MAX_ATTEMPTS )); then
            die "Failed after ${MAX_ATTEMPTS} attempts. Fix the issue and rerun the script."
        fi
    fi
done

# ---- Step 4: Create credentials file ----------------------------------------

CREDS_FILE="/root/.smb-${TENANT_PREFIX}-recordings"

log "Step 4: Creating credentials file at $CREDS_FILE"

if [[ -n "$SMB_DOMAIN" ]]; then
    cat > "$CREDS_FILE" <<EOF
username=${SMB_USERNAME}
password=${SMB_PASSWORD}
domain=${SMB_DOMAIN}
EOF
else
    cat > "$CREDS_FILE" <<EOF
username=${SMB_USERNAME}
password=${SMB_PASSWORD}
EOF
fi

chmod 0600 "$CREDS_FILE"
log "Credentials file created with 0600 permissions"

# ---- Step 5: Create mount point ---------------------------------------------

log "Step 5: Creating mount point"
mkdir -p "$MOUNT_POINT"
log "Mount point $MOUNT_POINT created"

# ---- Step 6: Add fstab entry ------------------------------------------------

log "Step 6: Configuring fstab"

FSTAB_LINE="//${SERVER_IP}/${SHARE_NAME}  ${MOUNT_POINT}  cifs  credentials=${CREDS_FILE},vers=3.0,uid=${SAMBA_USER},gid=${SAMBA_USER},file_mode=0664,dir_mode=0775,noperm,_netdev  0 0"

if grep -qF "${MOUNT_POINT}" /etc/fstab; then
    log "fstab entry for $MOUNT_POINT already exists, skipping"
    echo ""
    echo "WARNING: An fstab entry for $MOUNT_POINT already exists."
    echo "Review /etc/fstab manually if you need to update it."
else
    echo "$FSTAB_LINE" >> /etc/fstab
    log "fstab entry added"
fi

# ---- Step 7: Mount -----------------------------------------------------------

log "Step 7: Mounting $MOUNT_POINT"

if mountpoint -q "$MOUNT_POINT"; then
    log "$MOUNT_POINT is already mounted, skipping"
else
    mount "$MOUNT_POINT"
    log "$MOUNT_POINT mounted successfully"
fi

# ---- Verification ------------------------------------------------------------

log "Running post setup verification"

VERIFY_PASS=true

if ! mountpoint -q "$MOUNT_POINT"; then
    log "VERIFY FAIL: $MOUNT_POINT is not mounted"
    VERIFY_PASS=false
fi

if [[ ! -f "$CREDS_FILE" ]]; then
    log "VERIFY FAIL: credentials file $CREDS_FILE does not exist"
    VERIFY_PASS=false
fi

CREDS_PERMS=$(stat -c '%a' "$CREDS_FILE" 2>/dev/null || echo "missing")
if [[ "$CREDS_PERMS" != "600" ]]; then
    log "VERIFY FAIL: credentials file permissions are $CREDS_PERMS, expected 600"
    VERIFY_PASS=false
fi

if [[ "$VERIFY_PASS" == true ]]; then
    log "All verifications passed"
    echo ""
    echo "============================================="
    echo " SMB source mount configured successfully"
    echo "============================================="
    echo " Remote share : //${SERVER_IP}/${SHARE_NAME}"
    echo " Mount point  : $MOUNT_POINT"
    echo " Credentials  : $CREDS_FILE"
    echo " SMB user     : $SMB_USERNAME"
    echo " Log file     : $LOGFILE"
    echo "============================================="
else
    log "Some verifications failed. Review the log at $LOGFILE"
    exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-archive.sh
# Rocky Linux 9.x Recording Archive Server Setup
# Partitions /dev/sdb, formats XFS, mounts by UUID, creates Samba share
# Idempotent: safe to rerun
# =============================================================================

LOGFILE="/var/log/setup-archive.log"
DISK="/dev/sdb"
PART="${DISK}1"
MOUNT_POINT="/mnt/t1-archive01"
SHARE_PATH="${MOUNT_POINT}/recordings"
REC_PATH="${SHARE_PATH}/rec"
SAMBA_USER="recordings"
SAMBA_SHARE="t1-archive01"
SMB_CONF="/etc/samba/smb.conf"

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

if [[ ! -b "$DISK" ]]; then
    die "$DISK does not exist. Verify disk layout before proceeding."
fi

# Confirm the disk has no partitions (safety check)
EXISTING_PARTS=$(lsblk -rn -o NAME "$DISK" | grep -v "^$(basename "$DISK")$" || true)
if [[ -n "$EXISTING_PARTS" ]]; then
    die "$DISK already has partitions: $EXISTING_PARTS. Aborting to prevent data loss."
fi

# ---- Prompt for Samba password ----------------------------------------------

echo ""
echo "Enter the Samba password for the '${SAMBA_USER}' user."
echo "This password will be used by Windows clients to connect to the share."
echo ""

while true; do
    read -rsp "Password: " SAMBA_PASS
    echo ""
    read -rsp "Confirm password: " SAMBA_PASS_CONFIRM
    echo ""
    if [[ "$SAMBA_PASS" == "$SAMBA_PASS_CONFIRM" ]]; then
        if [[ -z "$SAMBA_PASS" ]]; then
            echo "Password cannot be empty. Try again."
            continue
        fi
        break
    else
        echo "Passwords do not match. Try again."
    fi
done

log "Starting archive server setup"

# ---- Step 1: Partition /dev/sdb ---------------------------------------------

log "Step 1: Partitioning $DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary xfs 0% 100%
udevadm settle
log "Partition $PART created"

# ---- Step 2: Format as XFS -------------------------------------------------

log "Step 2: Formatting $PART as XFS"
mkfs.xfs -f "$PART"
log "XFS filesystem created on $PART"

# ---- Step 3: Get UUID and configure fstab -----------------------------------

log "Step 3: Configuring fstab with UUID"
DISK_UUID=$(blkid -s UUID -o value "$PART")
if [[ -z "$DISK_UUID" ]]; then
    die "Could not determine UUID for $PART"
fi
log "UUID for $PART is $DISK_UUID"

mkdir -p "$MOUNT_POINT"

if grep -q "$DISK_UUID" /etc/fstab; then
    log "fstab entry for UUID=$DISK_UUID already exists, skipping"
else
    echo "UUID=${DISK_UUID}  ${MOUNT_POINT}  xfs  defaults,noatime  0 2" >> /etc/fstab
    log "fstab entry added"
fi

# ---- Step 4: Mount ----------------------------------------------------------

log "Step 4: Mounting $MOUNT_POINT"
if mountpoint -q "$MOUNT_POINT"; then
    log "$MOUNT_POINT is already mounted, skipping"
else
    mount "$MOUNT_POINT"
    log "$MOUNT_POINT mounted successfully"
fi

# ---- Step 5: Create directory structure -------------------------------------

log "Step 5: Creating directory structure"
mkdir -p "$REC_PATH"
log "Created $REC_PATH"

# ---- Step 6: Create recordings user ----------------------------------------

log "Step 6: Creating Samba user '${SAMBA_USER}'"
if id "$SAMBA_USER" &>/dev/null; then
    log "User $SAMBA_USER already exists, skipping creation"
else
    useradd \
        --system \
        --no-create-home \
        --shell /sbin/nologin \
        "$SAMBA_USER"
    log "User $SAMBA_USER created (no shell, no home)"
fi

# ---- Step 7: Set Samba password ---------------------------------------------

log "Step 7: Setting Samba password for ${SAMBA_USER}"
echo -e "${SAMBA_PASS}\n${SAMBA_PASS}" | smbpasswd -s -a "$SAMBA_USER"
log "Samba password set"

# ---- Step 8: Set directory ownership and permissions ------------------------

log "Step 8: Setting ownership and permissions"
chown -R "${SAMBA_USER}:${SAMBA_USER}" "$SHARE_PATH"
chmod -R 0775 "$SHARE_PATH"
log "Ownership set to ${SAMBA_USER}:${SAMBA_USER}, permissions set to 0775"

# ---- Step 9: Install and configure Samba ------------------------------------

log "Step 9: Installing and configuring Samba"
if ! rpm -q samba &>/dev/null; then
    dnf install -y samba samba-common samba-client
    log "Samba packages installed"
else
    log "Samba already installed, skipping"
fi

# Back up existing smb.conf if it exists and is not ours
if [[ -f "$SMB_CONF" ]] && ! grep -q "# MANAGED BY setup-archive.sh" "$SMB_CONF"; then
    cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    log "Backed up existing smb.conf"
fi

cat > "$SMB_CONF" <<EOF
# MANAGED BY setup-archive.sh
# Do not edit manually. Rerun the setup script to regenerate.

[global]
    workgroup = WORKGROUP
    server string = Recording Archive Server
    security = user
    map to guest = Never
    log file = /var/log/samba/log.%m
    max log size = 5000
    logging = file

    # Performance tuning for many small files
    socket options = TCP_NODELAY IPTOS_LOWDELAY
    read raw = yes
    write raw = yes
    use sendfile = yes
    aio read size = 16384
    aio write size = 16384

[${SAMBA_SHARE}]
    path = ${SHARE_PATH}
    comment = Tenant 1 Recording Archive
    browseable = yes
    read only = no
    writable = yes
    valid users = ${SAMBA_USER}
    force user = ${SAMBA_USER}
    force group = ${SAMBA_USER}
    create mask = 0664
    directory mask = 0775
    # Windows clients see "everyone" equivalent permissions
    force create mode = 0664
    force directory mode = 0775
EOF

log "smb.conf written"

# Validate smb.conf
testparm -s "$SMB_CONF" > /dev/null 2>&1 || die "smb.conf validation failed. Check $SMB_CONF"
log "smb.conf validated successfully"

# ---- Step 10: SELinux configuration -----------------------------------------

log "Step 10: Configuring SELinux for Samba"
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    setsebool -P samba_enable_home_dirs on 2>/dev/null || true
    setsebool -P samba_export_all_rw on 2>/dev/null || true
    semanage fcontext -a -t samba_share_t "${SHARE_PATH}(/.*)?" 2>/dev/null || \
        semanage fcontext -m -t samba_share_t "${SHARE_PATH}(/.*)?" 2>/dev/null || true
    restorecon -Rv "$SHARE_PATH"
    log "SELinux contexts applied"
else
    log "SELinux is disabled, skipping context configuration"
fi

# ---- Step 11: Firewall configuration ----------------------------------------

log "Step 11: Configuring firewall"
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=samba 2>/dev/null || true
    firewall-cmd --reload
    log "Firewall rules applied for Samba"
else
    log "firewalld is not running, skipping firewall configuration"
fi

# ---- Step 12: Enable and start Samba services -------------------------------

log "Step 12: Enabling and starting Samba services"
systemctl enable --now smb nmb
log "smb and nmb services enabled and started"

# ---- Verification -----------------------------------------------------------

log "Running post setup verification"

VERIFY_PASS=true

if ! mountpoint -q "$MOUNT_POINT"; then
    log "VERIFY FAIL: $MOUNT_POINT is not mounted"
    VERIFY_PASS=false
fi

if ! [[ -d "$REC_PATH" ]]; then
    log "VERIFY FAIL: $REC_PATH does not exist"
    VERIFY_PASS=false
fi

if ! id "$SAMBA_USER" &>/dev/null; then
    log "VERIFY FAIL: user $SAMBA_USER does not exist"
    VERIFY_PASS=false
fi

if ! pdbedit -L | grep -q "^${SAMBA_USER}:"; then
    log "VERIFY FAIL: $SAMBA_USER is not in Samba database"
    VERIFY_PASS=false
fi

if ! systemctl is-active --quiet smb; then
    log "VERIFY FAIL: smb service is not running"
    VERIFY_PASS=false
fi

if ! systemctl is-active --quiet nmb; then
    log "VERIFY FAIL: nmb service is not running"
    VERIFY_PASS=false
fi

if [[ "$VERIFY_PASS" == true ]]; then
    log "All verifications passed"
    echo ""
    echo "============================================="
    echo " Archive server setup complete"
    echo "============================================="
    echo " Mount point : $MOUNT_POINT"
    echo " Share name  : \\\\$(hostname)\\${SAMBA_SHARE}"
    echo " Share path  : $SHARE_PATH"
    echo " Samba user  : $SAMBA_USER"
    echo " Log file    : $LOGFILE"
    echo "============================================="
else
    log "Some verifications failed. Review the log at $LOGFILE"
    exit 1
fi

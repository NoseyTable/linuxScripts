#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# add-archive.sh
# Add a new recording archive disk to an existing Rocky Linux 9.x archive server
# Expects setup-archive.sh to have been run first (packages, global smb.conf, user)
# Idempotent: safe to rerun
# =============================================================================

LOGFILE="/var/log/add-archive.log"
SAMBA_USER="recordings"
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

if [[ ! -f "$SMB_CONF" ]]; then
    die "$SMB_CONF not found. Run setup-archive.sh first."
fi

if ! id "$SAMBA_USER" &>/dev/null; then
    die "User '$SAMBA_USER' does not exist. Run setup-archive.sh first."
fi

if ! pdbedit -L 2>/dev/null | grep -q "^${SAMBA_USER}:"; then
    die "User '$SAMBA_USER' is not in the Samba database. Run setup-archive.sh first."
fi

# ---- Explanation and confirmation -------------------------------------------

echo ""
echo "======================================================================"
echo "  Add Archive Disk            What this script will do:"
echo "======================================================================"
echo ""
echo "  1. Discover empty disks (excluding /dev/sda) and let you choose one"
echo "  2. Prompt for tenant number to determine naming (e.g. t1, t2)"
echo "  3. Auto detect the next archive number (e.g. t1-archive02)"
echo "  4. Partition the selected disk with a single GPT partition"
echo "  5. Format the partition as XFS"
echo "  6. Mount by UUID at /mnt/<tenant>-archive<NN> (added to /etc/fstab)"
echo "  7. Create directory structure: recordings/rec"
echo "  8. Set ownership to '${SAMBA_USER}' with 0775 permissions"
echo "  9. Apply SELinux contexts for Samba (if enforcing)"
echo " 10. Append a new [share] block to ${SMB_CONF}"
echo " 11. Restart smb + nmb services"
echo ""
echo "  Prerequisites : setup-archive.sh must have been run first"
echo "  Samba user    : ${SAMBA_USER} (already exists)"
echo "  Log file      : ${LOGFILE}"
echo ""
echo "======================================================================"
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    log "User declined. Exiting."
    exit 0
fi
echo ""

# ---- Step 1: Discover empty disks -------------------------------------------

log "Step 1: Discovering empty disks"

declare -a EMPTY_DISKS=()

for disk in /sys/block/sd*; do
    DEVNAME="/dev/$(basename "$disk")"

    # Skip sda (root drive)
    [[ "$DEVNAME" == "/dev/sda" ]] && continue

    # Check for existing partitions
    PARTS=$(lsblk -rn -o NAME "$DEVNAME" | grep -v "^$(basename "$DEVNAME")$" || true)
    if [[ -z "$PARTS" ]]; then
        SIZE=$(lsblk -rn -o SIZE "$DEVNAME" | head -1)
        EMPTY_DISKS+=("$DEVNAME|$SIZE")
    fi
done

if [[ ${#EMPTY_DISKS[@]} -eq 0 ]]; then
    die "No empty disks found (excluding /dev/sda). Nothing to do."
fi

echo ""
echo "Available empty disks:"
echo ""
for i in "${!EMPTY_DISKS[@]}"; do
    IFS='|' read -r DEV SIZE <<< "${EMPTY_DISKS[$i]}"
    echo "  $((i + 1)). $DEV  ($SIZE)"
done
echo ""

while true; do
    read -rp "Select a disk [1-${#EMPTY_DISKS[@]}]: " DISK_CHOICE
    if [[ "$DISK_CHOICE" =~ ^[0-9]+$ ]] && (( DISK_CHOICE >= 1 && DISK_CHOICE <= ${#EMPTY_DISKS[@]} )); then
        break
    fi
    echo "Invalid selection. Try again."
done

IFS='|' read -r DISK DISK_SIZE <<< "${EMPTY_DISKS[$((DISK_CHOICE - 1))]}"
PART="${DISK}1"
log "Selected disk: $DISK ($DISK_SIZE)"

# ---- Step 2: Select tenant --------------------------------------------------

echo ""
while true; do
    read -rp "Enter tenant number (e.g. 1 for t1, 2 for t2): " TENANT_NUM
    if [[ "$TENANT_NUM" =~ ^[0-9]+$ ]] && (( TENANT_NUM >= 1 )); then
        break
    fi
    echo "Invalid tenant number. Enter a positive integer."
done

TENANT_PREFIX="t${TENANT_NUM}"
log "Tenant selected: $TENANT_PREFIX"

# ---- Step 3: Determine next archive number ----------------------------------

log "Step 3: Determining next archive number for $TENANT_PREFIX"

HIGHEST=0
for mount_dir in /mnt/${TENANT_PREFIX}-archive*; do
    [[ -d "$mount_dir" ]] || continue
    BASENAME=$(basename "$mount_dir")
    # Extract the number after "archive"
    NUM_PART="${BASENAME##*archive}"
    # Remove leading zeros for arithmetic
    NUM_CLEAN=$((10#$NUM_PART))
    if (( NUM_CLEAN > HIGHEST )); then
        HIGHEST=$NUM_CLEAN
    fi
done

NEXT_NUM=$(printf "%02d" $(( HIGHEST + 1 )))
ARCHIVE_NAME="${TENANT_PREFIX}-archive${NEXT_NUM}"
MOUNT_POINT="/mnt/${ARCHIVE_NAME}"
SHARE_PATH="${MOUNT_POINT}/recordings"
REC_PATH="${SHARE_PATH}/rec"

echo ""
echo "Next available archive: $ARCHIVE_NAME"
echo "Mount point: $MOUNT_POINT"
echo "Share name: $ARCHIVE_NAME"
echo "Share path: $SHARE_PATH"
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted by user."

# ---- Step 4: Partition disk --------------------------------------------------

log "Step 4: Partitioning $DISK"

# Final safety check
EXISTING_PARTS=$(lsblk -rn -o NAME "$DISK" | grep -v "^$(basename "$DISK")$" || true)
if [[ -n "$EXISTING_PARTS" ]]; then
    die "$DISK now has partitions: $EXISTING_PARTS. Something changed since discovery. Aborting."
fi

parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary xfs 0% 100%
udevadm settle
log "Partition $PART created"

# ---- Step 5: Format as XFS --------------------------------------------------

log "Step 5: Formatting $PART as XFS"
mkfs.xfs -f "$PART"
log "XFS filesystem created on $PART"

# ---- Step 6: Get UUID and configure fstab -----------------------------------

log "Step 6: Configuring fstab with UUID"
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

# ---- Step 7: Mount -----------------------------------------------------------

log "Step 7: Mounting $MOUNT_POINT"
if mountpoint -q "$MOUNT_POINT"; then
    log "$MOUNT_POINT is already mounted, skipping"
else
    mount "$MOUNT_POINT"
    log "$MOUNT_POINT mounted successfully"
fi

# ---- Step 8: Create directory structure --------------------------------------

log "Step 8: Creating directory structure"
mkdir -p "$REC_PATH"
chown -R "${SAMBA_USER}:${SAMBA_USER}" "$SHARE_PATH"
chmod -R 0775 "$SHARE_PATH"
log "Created $REC_PATH with correct ownership and permissions"

# ---- Step 9: SELinux context -------------------------------------------------

log "Step 9: Applying SELinux context"
if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
    semanage fcontext -a -t samba_share_t "${SHARE_PATH}(/.*)?" 2>/dev/null || \
        semanage fcontext -m -t samba_share_t "${SHARE_PATH}(/.*)?" 2>/dev/null || true
    restorecon -Rv "$SHARE_PATH"
    log "SELinux contexts applied"
else
    log "SELinux is disabled, skipping"
fi

# ---- Step 10: Append Samba share to smb.conf ---------------------------------

log "Step 10: Adding Samba share for $ARCHIVE_NAME"

if grep -q "^\[${ARCHIVE_NAME}\]" "$SMB_CONF"; then
    log "Share [$ARCHIVE_NAME] already exists in smb.conf, skipping"
else
    cat >> "$SMB_CONF" <<EOF

[${ARCHIVE_NAME}]
    path = ${SHARE_PATH}
    comment = Tenant ${TENANT_NUM} Recording Archive ${NEXT_NUM}
    browseable = yes
    read only = no
    writable = yes
    valid users = ${SAMBA_USER}
    force user = ${SAMBA_USER}
    force group = ${SAMBA_USER}
    create mask = 0664
    directory mask = 0775
    force create mode = 0664
    force directory mode = 0775
EOF
    log "Share [$ARCHIVE_NAME] appended to smb.conf"
fi

# Validate smb.conf
testparm -s "$SMB_CONF" > /dev/null 2>&1 || die "smb.conf validation failed. Check $SMB_CONF"
log "smb.conf validated"

# ---- Step 11: Restart Samba --------------------------------------------------

log "Step 11: Restarting Samba services"
systemctl restart smb nmb
log "smb and nmb restarted"

# ---- Verification ------------------------------------------------------------

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

if ! grep -q "^\[${ARCHIVE_NAME}\]" "$SMB_CONF"; then
    log "VERIFY FAIL: [$ARCHIVE_NAME] not found in smb.conf"
    VERIFY_PASS=false
fi

if ! systemctl is-active --quiet smb; then
    log "VERIFY FAIL: smb service is not running"
    VERIFY_PASS=false
fi

if [[ "$VERIFY_PASS" == true ]]; then
    log "All verifications passed"
    echo ""
    echo "============================================="
    echo " Archive added successfully"
    echo "============================================="
    echo " Disk        : $DISK ($DISK_SIZE)"
    echo " Mount point : $MOUNT_POINT"
    echo " Share name  : \\$(hostname)\\${ARCHIVE_NAME}"
    echo " Share path  : $SHARE_PATH"
    echo " Samba user  : $SAMBA_USER"
    echo " Log file    : $LOGFILE"
    echo "============================================="
else
    log "Some verifications failed. Review the log at $LOGFILE"
    exit 1
fi

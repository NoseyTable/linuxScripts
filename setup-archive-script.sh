#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-sync-recordings.sh
# Creates a daily sync script and crontab entry to move recordings
# from a mounted source share to the local archive
# Idempotent: rerunning updates the destination in the existing script
# =============================================================================

LOGFILE="/var/log/setup-sync-recordings.log"

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
SOURCE_MOUNT="/mnt/${TENANT_PREFIX}-recordings"
SOURCE_PATH="${SOURCE_MOUNT}/rec"
SYNC_SCRIPT="/usr/local/bin/sync-recordings-${TENANT_PREFIX}.sh"
SYNC_LOG="/var/log/sync-recordings-${TENANT_PREFIX}.log"

log "Tenant selected: $TENANT_PREFIX"

# Verify source mount exists
if ! mountpoint -q "$SOURCE_MOUNT" 2>/dev/null; then
    die "$SOURCE_MOUNT is not mounted. Run mount-smb-source.sh first."
fi

if [[ ! -d "$SOURCE_PATH" ]]; then
    die "$SOURCE_PATH does not exist. Verify the source share structure."
fi

# ---- Step 2: Find and suggest archive destination ---------------------------

log "Step 2: Discovering archives for $TENANT_PREFIX"

declare -a ARCHIVES=()
HIGHEST=0

for mount_dir in /mnt/${TENANT_PREFIX}-archive*; do
    [[ -d "$mount_dir" ]] || continue
    if mountpoint -q "$mount_dir" 2>/dev/null; then
        BASENAME=$(basename "$mount_dir")
        NUM_PART="${BASENAME##*archive}"
        NUM_CLEAN=$((10#$NUM_PART))
        ARCHIVES+=("$mount_dir")
        if (( NUM_CLEAN > HIGHEST )); then
            HIGHEST=$NUM_CLEAN
        fi
    fi
done

if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
    die "No mounted archives found for $TENANT_PREFIX. Run setup-archive.sh or add-archive.sh first."
fi

SUGGESTED="/mnt/${TENANT_PREFIX}-archive$(printf '%02d' "$HIGHEST")"

echo ""
echo "Available archives for ${TENANT_PREFIX}:"
echo ""
for i in "${!ARCHIVES[@]}"; do
    LABEL="${ARCHIVES[$i]}"
    if [[ "$LABEL" == "$SUGGESTED" ]]; then
        echo "  $((i + 1)). $LABEL  (suggested)"
    else
        echo "  $((i + 1)). $LABEL"
    fi
done
echo ""

while true; do
    read -rp "Select archive [1-${#ARCHIVES[@]}] (press Enter for suggested): " ARCHIVE_CHOICE
    if [[ -z "$ARCHIVE_CHOICE" ]]; then
        DEST_MOUNT="$SUGGESTED"
        break
    fi
    if [[ "$ARCHIVE_CHOICE" =~ ^[0-9]+$ ]] && (( ARCHIVE_CHOICE >= 1 && ARCHIVE_CHOICE <= ${#ARCHIVES[@]} )); then
        DEST_MOUNT="${ARCHIVES[$((ARCHIVE_CHOICE - 1))]}"
        break
    fi
    echo "Invalid selection. Try again."
done

DEST_PATH="${DEST_MOUNT}/recordings/rec"

if [[ ! -d "$DEST_PATH" ]]; then
    die "$DEST_PATH does not exist. Verify the archive structure."
fi

log "Source: $SOURCE_PATH"
log "Destination: $DEST_PATH"

echo ""
echo "Source:      $SOURCE_PATH"
echo "Destination: $DEST_PATH"

# ---- Step 3: Ask for schedule time ------------------------------------------

echo ""
while true; do
    read -rp "What time should the sync run daily? (24h format, e.g. 22:00): " SYNC_TIME
    if [[ "$SYNC_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        break
    fi
    echo "Invalid time format. Use HH:MM in 24 hour format (e.g. 22:00)."
done

CRON_HOUR="${SYNC_TIME%%:*}"
CRON_MIN="${SYNC_TIME##*:}"

log "Sync scheduled for ${SYNC_TIME} daily"

echo ""
echo "Summary:"
echo "  Source:      $SOURCE_PATH"
echo "  Destination: $DEST_PATH"
echo "  Schedule:    Daily at ${SYNC_TIME}"
echo "  Script:      $SYNC_SCRIPT"
echo "  Log:         $SYNC_LOG"
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted by user."

# ---- Step 4: Create the sync script -----------------------------------------

log "Step 4: Creating sync script at $SYNC_SCRIPT"

cat > "$SYNC_SCRIPT" <<'OUTER'
#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# THIS SCRIPT IS MANAGED BY setup-sync-recordings.sh
# Do not edit manually. Rerun setup-sync-recordings.sh to update.
# =============================================================================

SOURCE_PATH="%%SOURCE_PATH%%"
DEST_PATH="%%DEST_PATH%%"
SYNC_LOG="%%SYNC_LOG%%"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$SYNC_LOG"
}

log "========== Sync started =========="

# Verify both paths are accessible
if [[ ! -d "$SOURCE_PATH" ]]; then
    log "FATAL: Source path $SOURCE_PATH is not accessible. Is the share mounted?"
    exit 1
fi

if [[ ! -d "$DEST_PATH" ]]; then
    log "FATAL: Destination path $DEST_PATH is not accessible. Is the archive mounted?"
    exit 1
fi

# Build list of date folders to skip (last 7 days)
declare -a SKIP_DATES=()
for i in $(seq 0 6); do
    SKIP_DATES+=("$(date -d "today - ${i} days" '+%Y-%m-%d')")
done

log "Skipping folders: ${SKIP_DATES[*]}"

MOVED=0
ERRORS=0

# Process only directories matching YYYY-MM-DD pattern
for folder in "$SOURCE_PATH"/????-??-??; do
    [[ -d "$folder" ]] || continue

    FOLDER_NAME=$(basename "$folder")

    # Validate it is actually a date format
    if ! [[ "$FOLDER_NAME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        continue
    fi

    # Check if this folder is in the skip list
    SKIP=false
    for skip_date in "${SKIP_DATES[@]}"; do
        if [[ "$FOLDER_NAME" == "$skip_date" ]]; then
            SKIP=true
            break
        fi
    done

    if [[ "$SKIP" == true ]]; then
        log "SKIP: $FOLDER_NAME (within last 7 days)"
        continue
    fi

    # Move the folder and fix ownership for Samba access
    log "MOVING: $FOLDER_NAME"
    if mv "$folder" "$DEST_PATH/"; then
        chown -R recordings:recordings "$DEST_PATH/$FOLDER_NAME"
        log "OK: $FOLDER_NAME moved and ownership set"
        MOVED=$((MOVED + 1))
    else
        log "ERROR: Failed to move $FOLDER_NAME"
        ERRORS=$((ERRORS + 1))
    fi
done

log "Sync complete. Moved: $MOVED, Errors: $ERRORS"
log "========== Sync finished =========="
OUTER

# Replace placeholders with actual values
sed -i "s|%%SOURCE_PATH%%|${SOURCE_PATH}|g" "$SYNC_SCRIPT"
sed -i "s|%%DEST_PATH%%|${DEST_PATH}|g" "$SYNC_SCRIPT"
sed -i "s|%%SYNC_LOG%%|${SYNC_LOG}|g" "$SYNC_SCRIPT"

chmod +x "$SYNC_SCRIPT"
log "Sync script created"

# ---- Step 5: Update crontab -------------------------------------------------

log "Step 5: Configuring crontab"

CRON_ENTRY="${CRON_MIN} ${CRON_HOUR} * * * ${SYNC_SCRIPT}"
CRON_MARKER="# sync-recordings-${TENANT_PREFIX}"

# Get current crontab (suppress error if empty)
CURRENT_CRONTAB=$(crontab -l 2>/dev/null || true)

if echo "$CURRENT_CRONTAB" | grep -qF "$CRON_MARKER"; then
    # Update existing entry
    UPDATED_CRONTAB=$(echo "$CURRENT_CRONTAB" | sed "/${CRON_MARKER}/d")
    echo "${UPDATED_CRONTAB}
${CRON_ENTRY} ${CRON_MARKER}" | crontab -
    log "Crontab entry updated"
else
    # Append new entry
    echo "${CURRENT_CRONTAB}
${CRON_ENTRY} ${CRON_MARKER}" | crontab -
    log "Crontab entry added"
fi

# ---- Verification ------------------------------------------------------------

log "Running post setup verification"

VERIFY_PASS=true

if [[ ! -x "$SYNC_SCRIPT" ]]; then
    log "VERIFY FAIL: $SYNC_SCRIPT does not exist or is not executable"
    VERIFY_PASS=false
fi

if ! crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
    log "VERIFY FAIL: crontab entry not found"
    VERIFY_PASS=false
fi

if [[ "$VERIFY_PASS" == true ]]; then
    log "All verifications passed"
    echo ""
    echo "============================================="
    echo " Recording sync configured successfully"
    echo "============================================="
    echo " Source       : $SOURCE_PATH"
    echo " Destination  : $DEST_PATH"
    echo " Schedule     : Daily at ${SYNC_TIME}"
    echo " Script       : $SYNC_SCRIPT"
    echo " Log          : $SYNC_LOG"
    echo " Crontab      : $CRON_ENTRY"
    echo "============================================="
else
    log "Some verifications failed. Review the log at $LOGFILE"
    exit 1
fi

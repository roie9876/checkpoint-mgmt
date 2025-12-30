#!/bin/bash
# Check Point GAiA (R82) bootstrap
# Goal: put /var/log on a dedicated Premium SSD v2 disk (4K logical sectors)
# and leave the OS disk untouched.
#
# IMPORTANT:
# - This is intended for a FRESH deployment (safe to reformat the data disk).
# - Assumes the *data disk* is attached as a new empty disk (no important data).
#
# Logging:
# - Writes to /var/log/cp-bootstrap-varlog.log (after /var/log is mounted it continues there)
# - Also logs to syslog via logger
# - Creates /var/log/cp-bootstrap-varlog.SUCCESS on success

set -euo pipefail

LOG="/var/log/cp-bootstrap-varlog.log"
exec > >(tee -a "$LOG" | logger -t cp-bootstrap) 2>&1

echo "BOOTSTRAP START: $(date -Is)"
echo "Kernel: $(uname -a)"
echo "Whoami: $(id || true)"
echo "PATH: $PATH"

# ----------------------------
# Helpers
# ----------------------------
log() {
  echo "$*" >&2
}

fail() {
  echo "BOOTSTRAP FAIL: $(date -Is) :: $*"
  exit 1
}

is_mounted() {
  mountpoint -q "$1"
}

get_mount_source() {
  local mnt="$1"
  if command -v findmnt >/dev/null 2>&1; then
    findmnt -n -o SOURCE "$mnt" 2>/dev/null || true
  else
    mount | awk -v m="$mnt" '$3==m {print $1; exit}'
  fi
}

wait_for_blockdev() {
  local dev="$1"
  local tries="${2:-60}"
  local sleep_s="${3:-2}"
  for i in $(seq 1 "$tries"); do
    if [ -b "$dev" ]; then
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

# Pick the first non-OS disk. We avoid /dev/sda intentionally.
# We also avoid any disk that already backs / or /var/log.
pick_data_disk() {
  log "Detecting OS disk(s) from mounts..."
  local os_src log_src
  os_src="$(get_mount_source /)"
  log_src="$(get_mount_source /var/log)"
  log "Root mounted from: ${os_src:-<unknown>}"
  log "/var/log mounted from: ${log_src:-<unknown>}"

  log "Enumerating candidate disks..."
  # Use /sys/block to avoid needing lsblk (not always present)
  for b in /sys/block/sd*; do
    local d="/dev/$(basename "$b")"

    # Skip if not a block device
    [ -b "$d" ] || continue

    # Skip OS disk by name
    if [[ "$d" == "/dev/sda" ]]; then
      log "Skipping OS disk: $d"
      continue
    fi

    # Skip if this disk is already used by root or /var/log source
    # (covers cases where SOURCE is /dev/mapper/...; we do a best-effort check)
    if echo "$os_src $log_src" | grep -q "$(basename "$d")"; then
      log "Skipping in-use disk: $d"
      continue
    fi

    # If it already has partitions/filesystems, we still can use it,
    # but for safety we prefer disks with no partitions.
    # We'll print what we see and let the script proceed (fresh env expected).
    log "Candidate disk found: $d"
    echo "$d"
    return 0
  done

  return 1
}

# ----------------------------
# Main
# ----------------------------

# If /var/log is already mounted on a non-root disk and has 4K sectsz, we can treat it as done.
if is_mounted /var/log; then
  cur_src="$(get_mount_source /var/log)"
  echo "/var/log already mounted from: ${cur_src:-<unknown>}"
fi

DATA_DISK="$(pick_data_disk || true)"
if [ -z "${DATA_DISK:-}" ]; then
  fail "Could not detect a non-OS data disk. Ensure a second disk is attached (LUN 1)."
fi

echo "Selected data disk: $DATA_DISK"

# Wait for disk to be present
wait_for_blockdev "$DATA_DISK" 60 2 || fail "Disk $DATA_DISK did not appear."

# Sanity: show sector sizes
echo "Sector sizes:"
echo "/dev/sda: $(blockdev --getss /dev/sda 2>/dev/null || echo n/a)"
echo "$DATA_DISK: $(blockdev --getss "$DATA_DISK" 2>/dev/null || echo n/a)"

# Partition: create GPT + single partition (100%) if needed.
PART="${DATA_DISK}1"

echo "Checking if partition exists: $PART"
if [ ! -b "$PART" ]; then
  echo "Partition not found. Creating GPT and a single primary partition on $DATA_DISK"
  # Gaia usually has parted. If not, fail with clear message.
  command -v parted >/dev/null 2>&1 || fail "parted not found. Cannot partition disk."
  parted -s "$DATA_DISK" mklabel gpt
  parted -s "$DATA_DISK" mkpart primary 1MiB 100%
fi

# Wait for partition node
wait_for_blockdev "$PART" 20 1 || fail "Partition $PART did not appear."

echo "Partition ready: $PART"

# If already has filesystem and is mounted on /var/log, finish.
if is_mounted /var/log; then
  echo "/var/log is already mounted. Verifying sectsz..."
  if xfs_info /var/log >/dev/null 2>&1; then
    sect="$(xfs_info /var/log | awk -F= '/sectsz=/{print $2; exit}' | awk '{print $1}')"
    echo "Current /var/log XFS sectsz=$sect"
    if [ "$sect" = "4096" ]; then
      echo "Already correct (4K). Marking success."
      touch /var/log/cp-bootstrap-varlog.SUCCESS
      echo "BOOTSTRAP SUCCESS: $(date -Is)"
      exit 0
    else
      echo "Mounted but sectsz is not 4096. Continuing with migration steps."
    fi
  else
    echo "/var/log is mounted but not XFS? Continuing with migration steps."
  fi
fi

# Detect existing filesystem on partition
if blkid "$PART" >/dev/null 2>&1; then
  echo "WARNING: $PART already has a filesystem signature:"
  blkid "$PART" || true
  echo "Because this is intended for a fresh deployment, we will REFORMAT $PART."
else
  echo "$PART appears empty (no blkid signature)."
fi

# Prepare a safe staging mount under /mnt/newlog
NEW_MNT="/mnt/newlog"
mkdir -p "$NEW_MNT"

# Format as XFS with 4K sector size (required for Premium SSD v2 4K logical sectors)
echo "Formatting $PART as XFS with 4K sectors..."
command -v mkfs.xfs >/dev/null 2>&1 || fail "mkfs.xfs not found."
mkfs.xfs -f -s size=4096 "$PART"

echo "Mounting new filesystem at $NEW_MNT"
mount -t xfs "$PART" "$NEW_MNT"

# Copy current /var/log contents (if any) to preserve anything already written
echo "Copying existing /var/log contents into new filesystem..."
mkdir -p "$NEW_MNT"
# Use rsync if available, else fallback to cp -a
if command -v rsync >/dev/null 2>&1; then
  rsync -aHAX --numeric-ids /var/log/ "$NEW_MNT/" || true
else
  cp -a /var/log/. "$NEW_MNT/" || true
fi

# Swap mount: move old /var/log aside, mount new at /var/log
echo "Switching /var/log to the new disk..."
OLD_LOG="/var/log.old"
mkdir -p "$OLD_LOG"

# Try to stop key logging-related services if present (best-effort)
echo "Best-effort: stopping syslog to avoid file churn during switch..."
( service syslog stop || service rsyslog stop || true ) 2>/dev/null || true

# Bind-move: unmount stage then mount at /var/log
umount "$NEW_MNT"

# If /var/log is currently a mountpoint, unmount it
if is_mounted /var/log; then
  echo "/var/log is a mountpoint; unmounting it first..."
  umount /var/log || fail "Failed to unmount existing /var/log"
fi

# Move current directory content aside (only if /var/log is not a mount now)
# We keep a backup just in case.
if [ -d /var/log ] && [ ! -L /var/log ]; then
  echo "Backing up current /var/log to $OLD_LOG (best-effort)..."
  # Ensure /var/log exists
  mkdir -p "$OLD_LOG"
  # Copy rather than move to avoid breaking expected path structure if something fails
  if command -v rsync >/dev/null 2>&1; then
    rsync -aHAX --numeric-ids /var/log/ "$OLD_LOG/" || true
  else
    cp -a /var/log/. "$OLD_LOG/" || true
  fi
fi

# Ensure mountpoint exists
mkdir -p /var/log

echo "Mounting $PART on /var/log"
mount -t xfs "$PART" /var/log

# Persist in /etc/fstab (idempotent)
UUID="$(blkid -s UUID -o value "$PART" || true)"
if [ -z "$UUID" ]; then
  fail "Could not read UUID for $PART"
fi

echo "Persisting mount in /etc/fstab (UUID=$UUID)"
if grep -qE '^[^#].*\s/var/log\s' /etc/fstab; then
  echo "An existing /var/log entry exists in /etc/fstab. Updating it."
  # Replace the existing /var/log line
  cp -a /etc/fstab /etc/fstab.bak.$(date +%s)
  # Use sed to replace the whole line that mounts /var/log
  sed -i "s|^[^#].*[[:space:]]/var/log[[:space:]].*$|UUID=$UUID /var/log xfs defaults,noatime 0 0|" /etc/fstab
else
  echo "Adding new /var/log entry to /etc/fstab"
  echo "UUID=$UUID /var/log xfs defaults,noatime 0 0" >> /etc/fstab
fi

# Restart syslog best-effort
echo "Best-effort: starting syslog again..."
( service syslog start || service rsyslog start || true ) 2>/dev/null || true

# Final verification
echo "Final verification:"
mount | grep " /var/log " || fail "/var/log not mounted"
df -h /var/log || true
if xfs_info /var/log >/dev/null 2>&1; then
  echo "xfs_info:"
  xfs_info /var/log | egrep "sectsz|bsize" || true
else
  fail "/var/log is not XFS after mount"
fi

sect="$(xfs_info /var/log | awk -F= '/sectsz=/{print $2; exit}' | awk '{print $1}')"
if [ "$sect" != "4096" ]; then
  fail "Expected /var/log XFS sectsz=4096, got sectsz=$sect"
fi

touch /var/log/cp-bootstrap-varlog.SUCCESS
echo "BOOTSTRAP SUCCESS: $(date -Is)"
exit 0

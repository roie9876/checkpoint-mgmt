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
# Log to file and syslog so early boot output is not lost.
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

get_xfs_sectsz() {
  xfs_info /var/log 2>/dev/null | tr ' ' '\n' | awk -F= '$1=="sectsz"{print $2; exit}'
}

get_logical_sector_size() {
  blockdev --getss "$1" 2>/dev/null || echo ""
}

disk_has_mounted_partitions() {
  local dev="$1"
  local base
  base="$(basename "$dev")"
  # Skip disks with any mounted partition (avoid resource/OS disks).
  awk -v b="$base" '$1 ~ ("/" b "[0-9]+$") { found=1 } END { exit found?0:1 }' /proc/mounts 2>/dev/null
}

is_aligned_4k() {
  local bytes="$1"
  [ -n "$bytes" ] || return 1
  awk -v b="$bytes" 'BEGIN { exit (b % 4096 == 0) ? 0 : 1 }'
}

wait_for_partitions() {
  local dev="$1"
  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$dev" || true
  fi
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle || true
  fi
}

# Update /etc/fstab to mount /var/log from a given UUID.
update_fstab_var_log() {
  local uuid="$1"
  [ -n "$uuid" ] || return 1
  if grep -qE '^[^#].*[[:space:]]/var/log[[:space:]]' /etc/fstab; then
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
    sed -i "s|^[^#].*[[:space:]]/var/log[[:space:]].*$|UUID=$uuid /var/log xfs defaults,inode32 0 0|" /etc/fstab
  else
    echo "UUID=$uuid /var/log xfs defaults,inode32 0 0" >> /etc/fstab
  fi
}

# Stage a new 4K XFS filesystem and switch /var/log on next reboot.
# Rationale: pvmove between 512B and 4K logical sector disks can trigger misaligned I/O.
stage_var_log_to_4k_disk() {
  local data_disk="$1"
  local part vg_name lv_name lv_path uuid

  vg_name="${LOG_VG_NAME:-vg_varlog}"
  lv_name="${LOG_LV_NAME:-lv_varlog}"
  part="$(get_part_path "$data_disk")"

  # Create GPT + partition if missing.
  if [ ! -b "$part" ]; then
    command -v parted >/dev/null 2>&1 || fail "parted not found. Cannot partition disk."
    parted -s "$data_disk" mklabel gpt
    parted -s "$data_disk" mkpart primary 1MiB 100%
    parted -s "$data_disk" set 1 lvm on || true
    wait_for_partitions "$data_disk"
  fi

  wait_for_blockdev "$part" 20 1 || fail "Partition $part did not appear."
  swapoff_if_active "$part" || fail "Failed to disable swap on $part"

  if blkid "$part" >/dev/null 2>&1; then
    log "Wiping existing signatures on $part for fresh 4K PV..."
    if command -v wipefs >/dev/null 2>&1; then
      wipefs -a "$part"
    else
      dd if=/dev/zero of="$part" bs=1M count=10
    fi
  fi

  log "Creating 4K-aligned PV on $part"
  pvcreate --dataalignment 4K -ff -y "$part"

  # Use a dedicated VG/LV so /var/log is fully isolated on the 4K disk.
  log "Creating VG/LV for /var/log on $part"
  if ! vgs "$vg_name" >/dev/null 2>&1; then
    vgcreate "$vg_name" "$part"
  else
    vgextend "$vg_name" "$part"
  fi
  lvcreate -n "$lv_name" -l 100%FREE "$vg_name" "$part"
  lv_path="/dev/$vg_name/$lv_name"

  log "Formatting $lv_path as XFS (4K sectors)"
  mkfs.xfs -f -s size=4096 "$lv_path"

  # Copy existing logs while /var/log is live; final switch happens after reboot.
  log "Staging data copy to /mnt/newlog"
  mkdir -p /mnt/newlog
  mount -t xfs "$lv_path" /mnt/newlog
  if command -v rsync >/dev/null 2>&1; then
    rsync -aHAX --numeric-ids /var/log/ /mnt/newlog/ || true
  else
    cp -a /var/log/. /mnt/newlog/ || true
  fi
  umount /mnt/newlog

  uuid="$(blkid -s UUID -o value "$lv_path" || true)"
  [ -n "$uuid" ] || fail "Could not read UUID for $lv_path"
  log "Updating /etc/fstab to mount /var/log from UUID=$uuid on next boot"
  update_fstab_var_log "$uuid"

  log "Staging complete. /var/log will switch to $lv_path after reboot."
  touch /var/log/cp-bootstrap-varlog.REBOOT
  if [ "${REBOOT_AFTER_STAGE:-1}" -eq 1 ]; then
    log "Rebooting to activate new /var/log..."
    if command -v shutdown >/dev/null 2>&1; then
      shutdown -r +1 "Rebooting to mount new /var/log"
    else
      reboot
    fi
  fi
  return 0
}

report_final_layout() {
  log "Final layout summary:"
  if command -v lvs >/dev/null 2>&1; then
    lvs -o lv_name,devices || true
  fi
  if command -v df >/dev/null 2>&1; then
    df -h /var/log || true
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

resolve_symlink() {
  local path="$1"
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$path"
  else
    echo "$path"
  fi
}

get_part_path() {
  local dev="$1"
  # Azure LUN symlinks expose partitions as lunX-partY.
  if [[ "$dev" == /dev/disk/azure/scsi1/lun* ]]; then
    echo "${dev}-part1"
  else
    echo "${dev}1"
  fi
}

swapoff_if_active() {
  local dev="$1"
  if [ -z "$dev" ]; then
    return 0
  fi
  if grep -q "^$dev[[:space:]]" /proc/swaps 2>/dev/null; then
    if command -v swapoff >/dev/null 2>&1; then
      log "Swap is active on $dev; disabling it."
      swapoff "$dev" || return 1
    else
      log "Swap is active on $dev but swapoff is not available."
      return 1
    fi
  fi
  return 0
}

extend_var_log_lvm() {
  local data_disk="$1"
  local log_src vg_name lv_name lv_path part
  local lv_size_mb pv_free_mb cur_pvs moved_ok

  # Only handle cases where /var/log is an LVM LV already.
  log_src="$(get_mount_source /var/log)"
  case "$log_src" in
    /dev/mapper/*) ;;
    *) return 1 ;;
  esac

  command -v lvs >/dev/null 2>&1 || return 1
  command -v vgs >/dev/null 2>&1 || return 1
  command -v pvs >/dev/null 2>&1 || return 1
  command -v pvcreate >/dev/null 2>&1 || return 1
  command -v vgextend >/dev/null 2>&1 || return 1
  command -v lvextend >/dev/null 2>&1 || return 1
  command -v xfs_growfs >/dev/null 2>&1 || return 1

  vg_name="$(lvs --noheadings -o vg_name "$log_src" | awk '{print $1}')"
  lv_name="$(lvs --noheadings -o lv_name "$log_src" | awk '{print $1}')"
  [ -n "$vg_name" ] || return 1
  [ -n "$lv_name" ] || return 1

  part="$(get_part_path "$data_disk")"
  wait_for_blockdev "$part" 20 1 || return 1

  swapoff_if_active "$part" || return 1
  local data_ss pe_start_bytes
  data_ss="$(get_logical_sector_size "$(resolve_symlink "$data_disk")")"

  # Create PV if missing; wipe signatures to avoid stale metadata conflicts.
  if ! pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' | grep -qx "$part"; then
    if blkid "$part" >/dev/null 2>&1; then
      log "Wiping existing signatures on $part for LVM use..."
      if command -v wipefs >/dev/null 2>&1; then
        wipefs -a "$part"
      else
        dd if=/dev/zero of="$part" bs=1M count=10
      fi
    fi
    log "Creating LVM PV on $part"
    if [ -n "$data_ss" ] && [ "$data_ss" -ge 4096 ]; then
      # Premium SSD v2 uses 4K logical sectors; enforce 4K PV alignment.
      pvcreate --dataalignment 4K -ff -y "$part"
    else
      pvcreate -ff -y "$part"
    fi
  fi

  if [ -n "$data_ss" ] && [ "$data_ss" -ge 4096 ]; then
    pe_start_bytes="$(pvs --noheadings --units b -o pe_start "$part" 2>/dev/null | tr -d ' B')"
    if ! is_aligned_4k "$pe_start_bytes"; then
      # Fail early instead of letting pvmove hang with misaligned I/O.
      fail "PV on $part is not 4K aligned (pe_start=${pe_start_bytes}B). Recreate PV with --dataalignment 4K."
    fi
  fi

  if ! pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk '{print $1":"$2}' | grep -qx "$part:$vg_name"; then
    log "Extending VG $vg_name with $part"
    vgextend "$vg_name" "$part"
  fi

  lv_path="/dev/$vg_name/$lv_name"

  lv_size_mb="$(lvs --noheadings --units m --nosuffix -o lv_size "$lv_path" | awk '{print $1}')"
  pv_free_mb="$(pvs --noheadings --units m --nosuffix -o pv_free "$part" | awk '{print $1}')"

  # Only attempt a full move when the new PV can hold the entire LV.
  if command -v pvmove >/dev/null 2>&1 && \
     awk -v free="$pv_free_mb" -v need="$lv_size_mb" 'BEGIN { exit (free+0 >= need+0) ? 0 : 1 }'; then
    # If the new disk can fully hold lv_log, move all extents to it.
    log "Attempting to move $lv_path to $part"
    cur_pvs="$(lvs --noheadings -o devices "$lv_path" | tr ',' '\n' | awk '{print $1}' | sed 's/(.*)//' | sort -u)"
    moved_ok=1
    for pv in $cur_pvs; do
      if [ "$pv" != "$part" ]; then
        if ! pvmove -n "$lv_name" "$pv" "$part"; then
          moved_ok=0
          break
        fi
      fi
    done
    if [ "$moved_ok" -eq 1 ]; then
      log "Setting LV allocation policy to cling"
      lvchange --alloc cling "$lv_path" || true
      log "Extending $lv_path to use all free space on $part"
      lvextend -l +100%FREE "$lv_path" "$part"
      xfs_growfs /var/log
      log "LVM move+extend complete for /var/log"
      return 0
    fi
  fi

  log "Extending $lv_path to use all free space"
  lvextend -l +100%FREE "$lv_path"
  xfs_growfs /var/log
  log "LVM extend complete for /var/log"
  return 0
}

# Pick the Azure data disk via LUN when possible (stable), then fallback.
# You can override by exporting DATA_DISK_LUN (e.g., 0,1,2).
pick_data_disk() {
  # Prefer the Azure LUN symlink for stable disk selection across boots.
  local lun_dir="/dev/disk/azure/scsi1"
  local lun_path=""
  local lun="${DATA_DISK_LUN:-}"

  if [ -d "$lun_dir" ]; then
    if [ -n "$lun" ] && [ -e "$lun_dir/lun$lun" ]; then
      lun_path="$lun_dir/lun$lun"
    else
      lun_path="$(ls "$lun_dir"/lun* 2>/dev/null | sort -V | head -n1 || true)"
    fi

    if [ -n "$lun_path" ] && [ -e "$lun_path" ]; then
      local dev
      dev="$(resolve_symlink "$lun_path")"
      log "Using Azure data disk: $lun_path -> $dev"
      echo "$lun_path"
      return 0
    fi
  fi

  # Fallback mode: avoid OS disk and any mounted partitions.
  log "Detecting OS disk(s) from mounts..."
  local os_src log_src
  os_src="$(get_mount_source /)"
  log_src="$(get_mount_source /var/log)"
  log "Root mounted from: ${os_src:-<unknown>}"
  log "/var/log mounted from: ${log_src:-<unknown>}"

  log "Enumerating candidate disks..."
  # Use /sys/block to avoid needing lsblk (not always present)
  local fallback=""
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

    # Skip disks that are actively used as swap
    if grep -q "^$d[[:space:]]" /proc/swaps 2>/dev/null; then
      log "Skipping swap disk: $d"
      continue
    fi

    if disk_has_mounted_partitions "$d"; then
      log "Skipping disk with mounted partitions: $d"
      continue
    fi

    local ss
    ss="$(get_logical_sector_size "$d")"
    log "Candidate disk found: $d (logical sector size ${ss:-unknown})"

    # Prefer 4K logical sector disks (Premium SSD v2).
    if [ -n "$ss" ] && [ "$ss" -ge 4096 ]; then
      echo "$d"
      return 0
    fi

    # Keep first non-4K candidate as a fallback.
    if [ -z "$fallback" ]; then
      fallback="$d"
    fi
  done

  if [ -n "$fallback" ]; then
    echo "$fallback"
    return 0
  fi

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

# Enforce 4K logical sector size to prevent misaligned I/O on Premium SSD v2.
# If REQUIRE_4K=1, we refuse to touch 512B logical sector disks.
REQUIRE_4K="${REQUIRE_4K:-1}"
data_disk_ss="$(get_logical_sector_size "$(resolve_symlink "$DATA_DISK")")"
if [ "$REQUIRE_4K" -eq 1 ]; then
  if [ -z "$data_disk_ss" ]; then
    fail "Could not detect logical sector size for $DATA_DISK; refusing to proceed."
  fi
  if [ "$data_disk_ss" -lt 4096 ]; then
    fail "Selected data disk $DATA_DISK has logical sector size ${data_disk_ss}B; Premium SSD v2 requires 4K."
  fi
fi

# If the disk is used as swap, disable it before we modify partitioning.
swapoff_if_active "$DATA_DISK" || fail "Failed to disable swap on $DATA_DISK"

# If target is 4K, stage a clean switch and reboot (avoid pvmove misalignment).
if [ -n "$data_disk_ss" ] && [ "$data_disk_ss" -ge 4096 ]; then
  stage_var_log_to_4k_disk "$DATA_DISK"
  touch /var/log/cp-bootstrap-varlog.SUCCESS
  echo "BOOTSTRAP SUCCESS: $(date -Is)"
  exit 0
fi

# Non-4K disks: extend in-place.
if extend_var_log_lvm "$DATA_DISK"; then
  report_final_layout
  touch /var/log/cp-bootstrap-varlog.SUCCESS
  echo "BOOTSTRAP SUCCESS: $(date -Is)"
  exit 0
fi

# Sanity: show sector sizes
echo "Sector sizes:"
echo "/dev/sda: $(blockdev --getss /dev/sda 2>/dev/null || echo n/a)"
echo "$DATA_DISK: $(blockdev --getss "$(resolve_symlink "$DATA_DISK")" 2>/dev/null || echo n/a)"

# Partition: create GPT + single partition (100%) if needed.
PART="$(get_part_path "$DATA_DISK")"

echo "Checking if partition exists: $PART"
if [ ! -b "$PART" ]; then
  echo "Partition not found. Creating GPT and a single primary partition on $DATA_DISK"
  # Gaia usually has parted. If not, fail with clear message.
  command -v parted >/dev/null 2>&1 || fail "parted not found. Cannot partition disk."
  parted -s "$DATA_DISK" mklabel gpt
  parted -s "$DATA_DISK" mkpart primary 1MiB 100%
  parted -s "$DATA_DISK" set 1 lvm on || true
  wait_for_partitions "$DATA_DISK"
fi

# Wait for partition node
wait_for_blockdev "$PART" 20 1 || fail "Partition $PART did not appear."

echo "Partition ready: $PART"

swapoff_if_active "$PART" || fail "Failed to disable swap on $PART"

# If already has filesystem and is mounted on /var/log, finish.
if is_mounted /var/log; then
  echo "/var/log is already mounted. Verifying sectsz..."
  if xfs_info /var/log >/dev/null 2>&1; then
    sect="$(get_xfs_sectsz)"
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

# For 512B disks, the script should have exited above.
fail "Reached end of script without completing /var/log migration."

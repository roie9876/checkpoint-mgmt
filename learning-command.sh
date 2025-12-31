# GAiA learning guide: from fresh VM (single disk) to /var/log on a second disk.
# Run in Expert mode. Commands are safe read-only unless noted.

## 0) Fresh VM baseline (single disk)
# Verify OS disk sector size (typically 512 on GAiA OS disk).
blockdev --getss /dev/sda

# Show current LVM layout (before adding second disk).
pvs
vgs
lvs

# Confirm /var/log is on the default LV.
df -h /var/log
mount | grep '/var/log'

## 1) Attach second data disk (Premium SSD v2, 4K logical sectors)
# Check sector size for the new disk (expect 4096).
blockdev --getss /dev/sdb

# If Azure LUN path is available, note it (stable across reboot).
ls -l /dev/disk/azure/scsi1

## 2) Prepare the data disk (what the bootstrap script does)
# Create GPT and a single partition.
parted -s /dev/sdb mklabel gpt
parted -s /dev/sdb mkpart primary 1MiB 100%
parted -s /dev/sdb set 1 lvm on || true

# Create an LVM PV with 4K alignment for Premium SSD v2.
pvcreate --dataalignment 4K -ff -y /dev/sdb1

# Create a dedicated VG/LV for /var/log.
vgcreate vg_varlog /dev/sdb1
lvcreate -n lv_varlog -l 100%FREE vg_varlog /dev/sdb1

# Format XFS with 4K sectors.
mkfs.xfs -f -s size=4096 /dev/vg_varlog/lv_varlog

# Stage a copy of current /var/log to the new filesystem.
mkdir -p /mnt/newlog
mount -t xfs /dev/vg_varlog/lv_varlog /mnt/newlog
rsync -aHAX --numeric-ids /var/log/ /mnt/newlog/
umount /mnt/newlog

# Update /etc/fstab to mount /var/log from the new LV on reboot.
UUID=$(blkid -s UUID -o value /dev/vg_varlog/lv_varlog)
cp -a /etc/fstab /etc/fstab.bak.$(date +%s)
sed -i "s|^[^#].*[[:space:]]/var/log[[:space:]].*$|UUID=$UUID /var/log xfs defaults,inode32 0 0|" /etc/fstab

# Reboot to activate the new /var/log mount.
# shutdown -r +1 "Rebooting to mount new /var/log"

## 3) Verify storage layout (after reboot)
# /var/log should now be on vg_varlog/lv_varlog.
lvs -o lv_name,lv_path,devices
pvs -o pv_name,pv_size,pv_free,vg_name
vgs -o vg_name,vg_attr,vg_size,vg_free

df -h /var/log
mount | grep '/var/log'

# Check XFS sector size (should reflect 4K).
xfs_info /var/log | egrep "sectsz|bsize"

## 4) GAiA management checks (SmartConsole readiness)
# Core processes.
cpwd_admin list

# Ports: 18190 (SmartConsole), 18210 (CPCA), 443 (WebUI), 18191/18192 (CPD).
netstat -lntp | grep -E '18190|18191|18192|18210|443'

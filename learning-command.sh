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

# Add the new PV to the existing VG.
vgextend vg_splat /dev/sdb1

# Move lv_log onto the new disk if there is enough free space.
pvmove -n lv_log /dev/sda4 /dev/sdb1

# Extend lv_log to consume remaining space on the new PV.
lvextend -l +100%FREE /dev/vg_splat/lv_log /dev/sdb1

# Grow the filesystem online (XFS).
xfs_growfs /var/log

## 3) Verify storage layout
# Check LV placement (lv_log should be on /dev/sdb1).
lvs -o lv_name,lv_path,devices
pvs -o pv_name,pv_size,pv_free,vg_name
vgs -o vg_name,vg_attr,vg_size,vg_free

# Confirm /var/log is mounted and sized as expected.
df -h /var/log
mount | grep '/var/log'

# Check XFS sector size (should reflect 4K).
xfs_info /var/log | egrep "sectsz|bsize"

## 4) Live move monitoring (optional)
watch -n 5 'lvs -a -o+devices'
watch -n 5 'pvs -o+pv_used,vg_name'

## 5) GAiA management checks (SmartConsole readiness)
# Core processes.
cpwd_admin list
cpstat mg

# Ports: 18190 (SmartConsole), 18210 (CPCA), 443 (WebUI), 18191/18192 (CPD).
netstat -lntp | grep -E '18190|18191|18192|18210|443'

# If SmartConsole fails, restart CPM/FWM.
# cpwd_admin stop -name CPM -path "$CPDIR/bin/cpm"
# cpwd_admin start -name CPM -path "$CPDIR/bin/cpm"
# cpwd_admin stop -name FWM -path "$CPDIR/bin/fwm"
# cpwd_admin start -name FWM -path "$CPDIR/bin/fwm"






[Expert@fw-mgmt-vr3u47ftqjp4w:0]# blockdev --getss /dev/sda
512
[Expert@fw-mgmt-vr3u47ftqjp4w:0]# blockdev --getss /dev/sdb
512
[Expert@fw-mgmt-vr3u47ftqjp4w:0]# blockdev --getss /dev/sdc
4096
[Expert@fw-mgmt-vr3u47ftqjp4w:0]# 

before migration start
Expert@fw-mgmt-who6drys4cyhe:0]# pvs
  PV         VG       Fmt  Attr PSize   PFree 
  /dev/sda4  vg_splat lvm2 a--   96.70g 33.70g
  /dev/sdc1  vg_splat lvm2 a--  128.00g 85.00g
[Expert@fw-mgmt-who6drys4cyhe:0]# vgs
  VG       #PV #LV #SN Attr   VSize   VFree  
  vg_splat   2   2   0 wz--n- 224.70g 118.70g
[Expert@fw-mgmt-who6drys4cyhe:0]# lvs
  LV         VG       Attr       LSize  Pool Origin Data%  Meta%  Move Log Cpy%Sync Convert
  lv_current vg_splat -wi-ao---- 20.00g                                                    
  lv_log     vg_splat -wI-ao---- 43.00g                                                    
[Expert@fw-mgmt-who6drys4cyhe:0]# 
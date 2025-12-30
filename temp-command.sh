blockdev --getss /dev/sda
blockdev --getss /dev/sdb
blockdev --getss /dev/mapper/vg_splat-lv_log

xfs_info /var/log | egrep "sectsz|bsize"
dmesg | tail -n 50 | grep -i xfs

pvs
vgs
lvs
df -h /var/log


[Expert@cp-mgmt-gnnm3k2ly234e:0]# blockdev --getss /dev/sda
512
[Expert@cp-mgmt-gnnm3k2ly234e:0]# blockdev --getss /dev/sdb
512
[Expert@cp-mgmt-gnnm3k2ly234e:0]# blockdev --getss /dev/sdc
4096
[Expert@cp-mgmt-gnnm3k2ly234e:0]# 


watch -n 5 'lvs -a -o+devices'
watch -n 5 'pvs -o+pv_used,vg_name'

lvs -o lv_name,devices

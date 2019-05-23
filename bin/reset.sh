systemctl stop docker
umount /var/lib/docker
umount /opt
lvremove -y vg01 docker
lvremove -y vg02 opt
vgremove -y vg01 vg02
pvremove -y /dev/sdb1 /dev/sdc1
parted -s /dev/sdb rm 1
parted -s /dev/sdc rm 1
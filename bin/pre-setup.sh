yum -y update
yum -y install open-vm-tools unzip epel-release
systemctl start vmtoolsd
curl -sLo vtmon.zip https://github.com/G-regL/vtmon/archive/master.zip
unzip vtmon.zip
cd vtmon-master/
chmod +x vtmon_setup.sh

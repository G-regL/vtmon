#!/bin/bash

CHECK="$(tput cuu1) [$(tput setaf 2; tput bold)✓$(tput setaf 7; tput sgr0)]"
SPACE="    "

function pull_docker_images () {
  for i in $*; do
    echo -n "${SPACE} $i [  "
    docker pull $i >> /dev/null &
    PID=$!
    c=1
    sp="/-\|"
    while [ -d /proc/$PID ]; do
      printf "\b\b${sp:c++%${#sp}:1}]"
      sleep 0.5
    done
    echo
    echo "${CHECK} $i     "
  done
}
 
function make_persistent_storage () {
  dir=$1
  perms=$2
  echo "${SPACE} $dir"
  mkdir -p $dir >> /dev/null
  if [ "$perms" != "" ]; then
    chown -R $perms $dir
  fi
  echo "${CHECK} $dir"
  
}


function make_filesystem () {
  device=$1
  mountpoint=$2
  echo " Set up $device as $mountpoint"
  echo "${SPACE} Partition disk"
  parted -s $device mktable gpt > /dev/null
  parted -s $device mkpart primary 0% 100% > /dev/null
  echo "${CHECK} Partition disk"

  partition="${device}1"
  sleep 2

  echo -n "${SPACE} Format filesystem [  "
  mkfs.ext4 -q $partition > /dev/null &
  PID=$!
  c=1
  sp="/-\|"
  while [ -d /proc/$PID ]; do
    printf "\b\b${sp:c++%${#sp}:1}]"
    sleep 0.5
  done
  echo
  echo "${CHECK} Format filesystem    "

  echo "${SPACE} Add fstab entry"
  echo "$partition    $mountpoint                    ext4     defaults        1 1" >> /etc/fstab
  echo "${CHECK} Add fstab entry"

  if [ ! -d $mountpoint ]; then
    mkdir -p $mountpoint > /dev/null
  fi
  echo "${SPACE} Mount filesystem"
  mount $mountpoint >> /dev/null
  echo "${CHECK} Mount filesystem"
}

function copy_service_config () {
  f=`basename $1`

  echo "${SPACE} $f"
  cp $1 $2
  echo "${CHECK} $f"
}


echo " Install/remove packages"
# -------- Packages
# Install some dependencies
echo "${SPACE} Install required packages"
tdnf install -qy parted jq
echo "${CHECK} Install required packages"

echo

echo "System setup"
# --------- Disks/Mounts
# Create the /var/lib/docker mountpoint
make_filesystem /dev/sdb /var/lib/docker
echo

# Create the /opt mountpoint
make_filesystem /dev/sdc /opt
echo

# Enable, and Start Docker
echo "${SPACE} Enable and start the Docker service"
systemctl enable docker 2&> /dev/null
systemctl start docker 2&> /dev/null
echo "${CHECK} Enable and start the Docker service"
echo


echo " Make persistent storage"
# Portainer
echo " Portainer"
make_persistent_storage /opt/docker/Portainer/portainer/data/
# GraphHouse
echo " GraphHouse"
make_persistent_storage /opt/docker/GraphHouse/api/config/
make_persistent_storage /opt/docker/GraphHouse/carbon/data/
make_persistent_storage /opt/docker/GraphHouse/carbon/config/
make_persistent_storage /opt/docker/GraphHouse/clickhouse/data/
make_persistent_storage /opt/docker/GraphHouse/clickhouse/metadata/
make_persistent_storage /opt/docker/GraphHouse/clickhouse/config/
make_persistent_storage /opt/docker/GraphHouse/graphite/config/
make_persistent_storage /opt/docker/GraphHouse/relay/config/
# Grafana
echo " Grafana"
make_persistent_storage /opt/docker/Grafana/grafana/data/ 472:472

# Telegraf
echo " Telegraf"
make_persistent_storage /opt/docker/Telegraf/cluster/
make_persistent_storage /opt/docker/Telegraf/datacenter/
make_persistent_storage /opt/docker/Telegraf/datastore/
make_persistent_storage /opt/docker/Telegraf/host/
make_persistent_storage /opt/docker/Telegraf/vm/


echo

echo " Copy configs"
# GrapHouse
echo " GraphHouse"
copy_service_config res/swarm/config/Graphhouse/api/api.yaml /opt/docker/GraphHouse/api/config/
copy_service_config res/swarm/config/Graphhouse/carbon/carbon-clickhouse.conf /opt/docker/GraphHouse/carbon/config/
copy_service_config res/swarm/config/Graphhouse/clickhouse/rollup.xml /opt/docker/GraphHouse/clickhouse/config/
copy_service_config res/swarm/config/Graphhouse/clickhouse/init.sql /opt/docker/GraphHouse/clickhouse/config/
copy_service_config res/swarm/config/Graphhouse/graphite/graphite-clickhouse.conf /opt/docker/GraphHouse/graphite/config/
copy_service_config res/swarm/config/Graphhouse/relay/relay.yaml /opt/docker/GraphHouse/relay/config/
# Telegraf
echo " Telegraf"
copy_service_config res/swarm/config/Telegraf/cluster/telegraf.conf /opt/docker/Telegraf/cluster/
copy_service_config res/swarm/config/Telegraf/datacenter/telegraf.conf /opt/docker/Telegraf/datacenter/
copy_service_config res/swarm/config/Telegraf/datastore/telegraf.conf /opt/docker/Telegraf/datastore/
copy_service_config res/swarm/config/Telegraf/host/telegraf.conf /opt/docker/Telegraf/host/
copy_service_config res/swarm/config/Telegraf/vm/telegraf.conf /opt/docker/Telegraf/vm/

 
echo " Pull Docker images"
# Portainer
echo " Portainer"
pull_docker_images $(cat res/swarm/stacks/portainer.yml | grep image | awk -F\  '{print $2}' | uniq)
# GraphHouse
echo " GraphHouse"
pull_docker_images $(cat res/swarm/stacks/graphhouse.yml | grep image | awk -F\  '{print $2}' | uniq)
# Grafana
echo " Grafana"
pull_docker_images $(cat res/swarm/stacks/grafana.yml |grep image |awk -F\  '{print $2}' |uniq)
# Telegraf
echo " Telegraf"
pull_docker_images $(cat res/swarm/stacks/telegraf.yml |grep image |awk -F\  '{print $2}' |uniq)
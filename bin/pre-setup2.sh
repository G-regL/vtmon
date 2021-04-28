#!/bin/bash

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


echo " Make persistent storage"
#Portainer
make_persistent_storage /opt/docker/stack.Portainer/service.portainer
# GraphHouse
make_persistent_storage /opt/docker/stack.GraphHouse/service.clickhouse/data/
make_persistent_storage /opt/docker/stack.GraphHouse/service.clickhouse/metadata
make_persistent_storage /opt/docker/stack.GraphHouse/service.carbon
#Grafana
make_persistent_storage /opt/docker/stack.grafana/service.grafana/data/ 472:472

echo " Pull Docker images"
#Portainer
pull_docker_images $(cat res/swarm/stacks/portainer.yml | grep image | awk -F\  '{print $2}' | uniq)
# GraphHouse
pull_docker_images $(cat res/swarm/stacks/graphhouse.yml | grep image | awk -F\  '{print $2}' | uniq)
# Grafana
pull_docker_images $(cat res/swarm/stacks/grafana.yml |grep image |awk -F\  '{print $2}' |uniq)
# Telegraf
pull_docker_images $(cat res/swarm/stacks/telegraf.yml |grep image |awk -F\  '{print $2}' |uniq)
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

function create_swarm_configs () {
  for config in $*; do
    f=`basename $config`
    echo "${SPACE} $f"
    docker config create $f $config >> /dev/null
    echo "${CHECK} $f"
  done
}

function make_persistant_storage () {
  for dir in $*; do
    echo "${SPACE} $dir"
    mkdir -p $dir >> /dev/null
    echo "${CHECK} $dir"
  done
}

function wait_for_service () {
  echo -n "${SPACE} Start services [  "
  i=1
  sp="/-\|"
  until eval $*; do
    printf "\b\b${sp:i++%${#sp}:1}]"
    sleep 0.5
  done
  echo
  echo "${CHECK} Start services       "
}

function make_filesystem () {
  device=$1
  volgroup=$2
  volname=$3
  mountpoint=$4
  echo " Set up $device as $mountpoint ($volgroup-$volname)"
  echo "${SPACE} Partition disk"
  parted -s $device mktable gpt > /dev/null
  parted -s $device mkpart primary 0% 100% > /dev/null
  echo "${CHECK} Create partition"

  partition="${device}1"

  echo "${SPACE} Create LVM physical volume"
  pvcreate ${partition} > /dev/null
  echo "${CHECK} Create LVM physical volume"

  echo "${SPACE} Create LVM volume group"
  vgcreate $volgroup ${partition} > /dev/null
  echo "${CHECK} Create LVM volume group"

  echo "${SPACE} Create LVM logical volume"
  lvcreate $volgroup -l 100%FREE -n $volname ${partition} > /dev/null
  echo "${CHECK} Create LVM logical volume"

  echo -n "${SPACE} Make filesystem [  "
  mkfs.xfs -fq /dev/$volgroup/$volname > /dev/null &
  PID=$!
  c=1
  sp="/-\|"
  while [ -d /proc/$PID ]; do
    printf "\b\b${sp:c++%${#sp}:1}]"
    sleep 0.5
  done
  echo
  echo "${CHECK} Make filesystem    "

  echo "${SPACE} Add fstab entry"
  echo "/dev/$volgroup/$volname    $mountpoint                    xfs     defaults        1 1" >> /etc/fstab
  echo "${CHECK} Add fstab entry"

  if [ ! -d $mountpoint ]; then
    mkdir -p $mountpoint > /dev/null
  fi
  echo "${SPACE} Mount filesystem"
  mount $mountpoint >> /dev/null
  echo "${CHECK} Mount filesystem"
}

echo "+------------------------------------------------------------------------------+"
echo "+                 Setup Virtualization Technologies Monitoring                 +"
echo "+------------------------------------------------------------------------------+"
echo
echo "We need to gather some details for the depoyment before proceeding"
echo 
echo "Portainer and Grafana both need to have an admin user account created and we'll"
echo "need to know what password you want to use."
# Gather some details for the deployment
while true; do
    read -p " Admin user password: " adminPass
#    echo
    read -p " Confirm password: " adminPass2
#    echo
    [ "$adminPass" = "$adminPass2" ] && break
    echo "ERROR: Passwords didn't match, please try again"
done
unset adminPass2
echo

echo "We need to know the IP or FQDN of this system, so that we can properly setup"
echo "some components."
disc_ipfqdn=`if [ $(hostname -s) != "localhost" ]; then hostname; else ip route | grep -v default | grep -v docker | cut -d\   -f9; fi`
read -p " IP or FQDN of this machine [$disc_ipfqdn]: " ipfqdn
ipfqdn=${ipfqdn:-$disc_ipfqdn}
unset disc_ipfqdn
echo

echo "We need to know the FQDNs of the vCenters you want to monitor."
echo "Enter them as a comma-separated list, eg: 'vc01.example.com,vc.int.example.org'"
read -p " vCenter addresses: "
vcenters=$(echo 'https://'$REPLY'/sdk' | sed 's~,~/sdk\\\", \\\"https://~g')
echo

echo "Please enter a username, and password, which we'll use to connect to each"
echo "vCenter above in order to gather the metrics. It should have the 'Read-only'"
echo "role granted to it at the root of the vCenter."
echo "It's recommended to use an SSO account, for ease of management"
read -p " vCenter user: " vcuser
while true; do
    read -p " vCenter user password: " vcpassword
#    echo
    read -p " Confirm password: " vcpassword2
#    echo
    [ "$vcpassword" = "$vcpassword2" ] && break
    echo "ERROR: Passwords didn't match, please try again"
done
unset vcpassword2
echo
echo

echo "We've got everything we need to setup, so sit back and watch things happen!"
read -p " Hit ENTER to continue"
echo

# --------- Disks/Mounts
# Create the /var/lib/docker mountpoint
make_filesystem /dev/sdb vg01 docker /var/lib/docker

# Create the /opt mountpoint
make_filesystem /dev/sdc vg02 opt /opt




echo " Install/remove packages"
# -------- Packages
# Remove any version of Docker if it's there
echo "${SPACE} Remove old Docker packages"
yum remove -qy docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2&> /dev/null
echo "${CHECK} Remove old Docker packages"
# Install some dependencies
echo "${SPACE} Install required needed packages"
yum install -qy yum-utils device-mapper-persistent-data lvm2 jq htop 2&> /dev/null
echo "${CHECK} Install some needed packages"
# Add the official Docker repo
echo "${SPACE} Add the official Docker repo"
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2&> /dev/null
echo "${CHECK} Add the official Docker repo"
# Install Docker
echo "${SPACE} Install Docker"
yum install -qy docker-ce docker-ce-cli containerd.io 2&> /dev/null
echo "${CHECK} Install Docker"
echo

echo " Setup Docker"
# -------- Docker
# Copy the Docker configs
echo "${SPACE} Copy the Docker daemon config files"
cp -fr res/docker/ /etc/ >> /dev/null
echo "${CHECK} Copy the Docker config files"

# Enable, and Start Docker
echo "${SPACE} Enable and start the Docker service"
systemctl enable docker 2&> /dev/null
systemctl start docker 2&> /dev/null
echo "${CHECK} Enable and start the Docker service"

# Initialize the swarm
echo "${SPACE} Initialize the Docker Swarm"
docker swarm init >> /dev/null
echo "${CHECK} Initialize the Docker Swarm"
echo

# Setup some networks
echo " Create networks"
for net in traefik-net graphite-net elastic-net; do
  echo "${SPACE} $net"
  docker network create --driver overlay --attachable $net >> /dev/null
  echo "${CHECK} $net"
done
read -p "Hit ENTER to continue"
echo

# Deploy Portainer, using the command-line
echo "Deploy Portainer"
echo "${SPACE} Make persistent storage"
make_persistant_storage /opt/docker/stack.Portainer/service.portainer

echo "${SPACE} Pull Docker images"
pull_docker_images $(cat res/swarm/stacks/portainer.yml |grep image |awk -F\  '{print $2}' |uniq)

echo " Deploy the stack"
docker stack deploy --compose-file=res/swarm/stacks/portainer.yml Portainer >> /dev/null
wait_for_service "curl -s -o /dev/null http://${ipfqdn}:9000/api/status"


echo " Set up Portainer"
# Change admin password
echo "${SPACE} Set admin password"
curl -s -o /dev/null http://${ipfqdn}:9000/api/users/admin/init -H "Content-Type: application/json" -X POST -d '{"username":"admin", "password":"'$adminPass'"}'
echo "${CHECK} Set admin password"

# Generate new admin auth token
echo "${SPACE} Generate admin auth token"
portAuthToken=`curl -s http://${ipfqdn}:9000/api/auth -H "Content-Type: application/json" -X POST -d '{"username":"admin", "password":"'$adminPass'"}' | jq '.jwt' -r`
echo "${CHECK} Generate admin auth token"

# Gather some endpoint details
echo "${SPACE} Gather endpoint details"
portEndpointID=`curl -s http://${ipfqdn}:9000/api/endpoints -H "Authorization: Bearer $portAuthToken" |jq '.[0].Id'`
portSwarmID=`curl -s http://${ipfqdn}:9000/api/endpoints/1/docker/swarm -H "Authorization: Bearer $portAuthToken" |jq -r '.ID'`
echo "${CHECK} Gather endpoint details"

# Set the endpoint name
echo "${SPACE} Set Endpoint name"
curl -s -o /dev/null http://${ipfqdn}:9000/api/endpoints/${portEndpointID} -X PUT \
    -H "Authorization: Bearer $portAuthToken" \
    -d '{"Name": "VTMon", "PublicURL": "'${ipfqdn}'"}'
echo "${CHECK} Set Endpoint name"
echo "DONE"
read -p "Hit ENTER to continue"
echo


# Deploy Traefik, using the Portainer API
echo "Deploy Traefik"
echo " Make persistent storage"
make_persistant_storage /opt/docker/stack.Traefik/service.traefik/logs

echo " Create Docker Swarm config files"
create_swarm_configs $(ls res/swarm/configs/Traefik_*)

echo " Pull Docker images"
pull_docker_images $(cat res/swarm/stacks/traefik.yml |grep image |awk -F\  '{print $2}' |uniq)

echo " Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Traefik \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F Env="[{ \"name\": \"HOSTIPFQDN\", \"value\": \"${ipfqdn}\"}]" \
    -F file=@res/swarm/stacks/traefik.yml

wait_for_service "curl -s -o /dev/null http://${ipfqdn}:8080/api"
echo "DONE"
read -p "Hit ENTER to continue"
echo


# Deploy Graphite, using the Portainer API
echo "Deploy Graphite"
echo " Make persistent storage"
make_persistant_storage /opt/docker/stack.graphite/service.relay/ /opt/docker/stack.graphite/service.carbon/whisper/ /opt/docker/stack.graphite/service.api/

chown -R 990:990 /opt/docker/stack.graphite/service.carbon/whisper/
### Set some system options to optimize it for Graphite
echo " Tuning host system"
### Percentage of your RAM which can be left unwritten to disk. MUST be much more than your write rate, which is usually one FS
### block size (4KB) per metric.
echo "${SPACE} Set vm.dirty_ratio"
echo "vm.dirty_ratio=50" >> /etc/sysctl.d/10-graphite.conf
echo "${CHECK} Set vm.dirty_ratio"

### percentage of yout RAM when background writer have to kick in and start writes to disk. Make it way above the value
### you see in `/proc/meminfo|grep Dirty` so that it doesn't interefere with dirty_expire_centisecs explained below
echo "${SPACE} Set vm.dirty_background_ratio"
echo "vm.dirty_background_ratio=50" >> /etc/sysctl.d/10-graphite.conf
echo "${CHECK} Set vm.dirty_background_ratio"

### allow page to be left dirty no longer than 10 mins if unwritten page stays longer than time set here, kernel starts writing it out
echo "${SPACE} Set vm.dirty_expire_centisecs"
echo "vm.dirty_expire_centisecs=6000" >> /etc/sysctl.d/10-graphite.conf
echo "${CHECK} Set vm.dirty_expire_centisecs"

echo "${SPACE} Apply settings"
sysctl --system >> /dev/null
echo "${CHECK} Apply settings"

echo " Create Docker Swarm config files"
create_swarm_configs $(ls res/swarm/configs/Graphite_*)

echo " Pull Docker images"
pull_docker_images $(cat res/swarm/stacks/graphite.yml |grep image |awk -F\  '{print $2}' |uniq)

echo " Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Graphite \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F file=@res/swarm/stacks/graphite.yml 2&> /dev/null
#stack_services=`cat res/swarm/stacks/graphite.yml |grep replicas |grep -v 0 |wc -l`
wait_for_service "[ \`docker service ls | grep Graphite |awk -F\  '{print $4}' |grep '1/1' |wc -l\` -eq '3' ]"
echo "DONE"
read -p "Hit ENTER to continue"
echo


# Deploy Grafana, using the Portainer API
echo "Deploy Grafana"
echo " Make persistent storage"
make_persistant_storage /opt/docker/stack.grafana/service.grafana/data/
chown -R 472:472 /opt/docker/stack.grafana/service.grafana/data/

echo " Pull Docker images"
pull_docker_images $(cat res/swarm/stacks/grafana.yml |grep image |awk -F\  '{print $2}' |uniq)

echo " Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "Accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Grafana \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F Env="[{ \"name\": \"HOSTIPFQDN\", \"value\": \"${ipfqdn}\"}]" \
    -F file=@res/swarm/stacks/grafana.yml 2&> /dev/null
wait_for_service "curl -s http://${ipfqdn}:8080/api | jq '.docker.backends.\"backend-Grafana-grafana\"' -e > /dev/null"
###until curl http://${ipfqdn}:8080/api  -s| jq '.docker.backends."backend-Grafana-grafana"' -e > /dev/null ; do


# Set Grafana admin password
echo " Set up Grafana"
echo "${SPACE} Set admin password"
curl -s -o /dev/null http://${ipfqdn}/grafana/api/admin/users/1/password -X PUT \
    -u admin:admin -H "Content-Type: application/json" -d '{"password":"'$adminPass'"}'
echo "${CHECK} Set admin password"

# Create the default datasource
echo "${SPACE} Create default datasource"
curl -s -o /dev/null http://${ipfqdn}/grafana/api/datasources -X POST \
    -u admin:$adminPass -H "Accept: application/json" -H "Content-Type: application/json" \
    -d '{ "name":"Graphite", "type":"graphite", "url":"http://Graphite_api:8080/", "access":"proxy","basicAuth": false, "isDefault": true}'
echo "${CHECK} Create default datasource"

# Create Grafana dashboards from the files inside res/grafana/*/*
echo "${SPACE} Create dashboard folders"
for f in `ls res/grafana`; do
  f_name=${f%-*}
  f_uid=${f#*-}
  echo "${SPACE} ${f_name}"
  curl -s -o /dev/null http://${ipfqdn}/grafana/api/folders -X POST \
      -u admin:$adminPass -H "Accept: application/json" -H "Content-Type: application/json" \
      -d '{ "uid": "'${f_uid}'", "title":"'${f_name}'"}'
  echo "${CHECK} ${f_name}"
done
echo " Import dashboards"
find res/grafana/ -iname *.json | while read file; do
  dashboard_name="`echo $file | cut -d/ -f4 | awk -F--- '{print $1}'`"
  folder_name=`echo $file | cut -d/ -f3 | cut -d- -f1`
  echo "${SPACE} $folder_name/$dashboard_name"
  folder_uid=`echo $file | cut -d/ -f3 | cut -d- -f2`
  folder_id=`curl -s -u admin:$adminPass "http://${ipfqdn}/grafana/api/folders/${folder_uid}" |jq '.id'`
#  dashboard_uid=`echo $file | cut -d/ -f4 | awk -F--- '{print $2}' | cut -d. -f1`
  jq "del(.dashboard.id) | .folderId = ${folder_id}" "$file" > "$file.tmp" && mv -f "$file.tmp" "$file"
  curl -s -o /dev/null  http://${ipfqdn}/grafana/api/dashboards/db -X POST \
      -u admin:$adminPass -H "Accept: application/json" -H "Content-Type: application/json" \
      -d @"$file"
  echo "${CHECK} $folder_name/$dashboard_name"
done
echo "DONE"
read -p "Hit ENTER to continue"
echo

# Deploy Telegraf, using the Portainer API
echo "Deploy Telegraf"
echo " Create Docker Swarm config files"
create_swarm_configs $(ls res/swarm/configs/Telegraf_*)

echo " Pull Docker images"
pull_docker_images $(cat res/swarm/stacks/telegraf.yml |grep image |awk -F\  '{print $2}' |uniq)

echo " Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "Accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Telegraf \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F Env="[{\"name\": \"VCENTERS\", \"value\": \"${vcenters}\"},
             {\"name\": \"VCUSERNAME\", \"value\": \"${vcuser}\"},
             {\"name\": \"VCPASSWORD\", \"value\": \"${vcpassword}\"}
            ]" \
    -F file=@res/swarm/stacks/telegraf.yml 2&> /dev/null
stack_services=`cat res/swarm/stacks/telegraf.yml |grep replicas |grep -v 0 |wc -l`
wait_for_service "[ \`docker service ls | grep Telegraf |awk -F\  '{print $4}' |grep '1/1' |wc -l\` -eq '${stack_services}' ]"

echo "DONE"

echo
echo "VTMon is now deployed and ready to go!"
echo
echo "You can visit Grafana at http://${ipfqdn}/grafana/, and login with admin:${adminPass}."
echo "Should you want/need to check on the status of the system, you can use the following URLs"
echo "  Portainer (Container manager) - http://${ipfqdn}/poratiner/"
echo "  Traefik (Load balancer)       - http://${ipfqdn}:8080/dashboard/"
echo
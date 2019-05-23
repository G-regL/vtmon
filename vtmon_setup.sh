#!/bin/bash

# --------- Disks/Mounts
# Create the /var/lib/docker mountpoint
echo "Setting up /dev/sdb as /var/lib/docker (vg01-docker)"
parted -s /dev/sdb mktable gpt >> /dev/null
parted -s /dev/sdb mkpart primary 0% 100% >> /dev/null
pvcreate /dev/sdb1 >> /dev/null
vgcreate vg01 /dev/sdb1 >> /dev/null
lvcreate vg01 -l 100%FREE -n docker /dev/sdb1 >> /dev/null
mkfs.xfs -fq /dev/mapper/vg01-docker >> /dev/null
mkdir /var/lib/docker >> /dev/null
echo '/dev/mapper/vg01-docker /var/lib/docker         xfs     defaults        1 1' >> /etc/fstab
# Create the /opt mountpoint
echo "Setting up /dev/sdc as /opt (vg02-opt)"
parted -s /dev/sdc mktable gpt >> /dev/null
parted -s /dev/sdc mkpart primary 0% 100% >> /dev/null
pvcreate /dev/sdc1 >> /dev/null
vgcreate vg02 /dev/sdc1 >> /dev/null
lvcreate vg02 -l 100%FREE -n opt /dev/sdc1 >> /dev/null
mkfs.xfs -fq /dev/mapper/vg02-opt >> /dev/null
echo '/dev/mapper/vg02-opt    /opt                    xfs     defaults        1 1' >> /etc/fstab
# Mount everything
echo "Mounting all disks"
mount -a >> /dev/null

# -------- Packages
# Remove any version of Docker if it's there
echo "Removing any old Docker packages"
yum remove -qy docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2&> /dev/null
# Install some dependencies
echo "Installing some needed packages"
yum install -qy yum-utils device-mapper-persistent-data lvm2 jq htop 2&> /dev/null
# Add the official Docker repo
echo "Adding the official Docker repo"
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2&> /dev/null
# Install Docker
echo "Installing Docker"
yum install -qy docker-ce docker-ce-cli containerd.io 2&> /dev/null

# -------- Docker
# Copy the Docker configs
echo "Copy the Docker config files"
cp -fr res/docker/ /etc/ >> /dev/null
# Enable, and Start Docker
echo "Enable and start the Docker service"
systemctl enable docker 2&> /dev/null
systemctl start docker 2&> /dev/null
# Initialize the swarm
echo "Initialize the Docker Swarm"
docker swarm init >> /dev/null
# Setup some networks
echo "Creating some required networks"
for net in traefik-net graphite-net elastic-net; do
  echo "  $net"
  docker network create --driver overlay --attachable $net >> /dev/null
done

while true; do
    read -s "Enter new admin password: " adminPass
    echo
    read -s "Confirm new admin password: " adminPass
    echo
    [ "$password" = "$password2" ] && break
    echo "Passwords didn't match, please try again"
done
#read -sp "Set admin password: " adminPass
read -p "IP or FQDN of this machine: " ipfqdn
read -p "vCenter addresses, comma-separated: " vcenters
read -p "vCenter user: " vcuser
while true; do
    read -s "Enter vCenter password: " vcpassword
    echo
    read -s "Confirm vCenter password: " vcpassword2
    echo
    [ "$vcpassword" = "$vcpassword2" ] && break
    echo "Passwords didn't match, please try again"
done

# Deploy Portainer, using the command-line
echo "Deploying Portainer"
echo "  Make persistent storage"
for dir in "/opt/docker/stack.Portainer/service.portainer"; do
  echo "    $dir"
  mkdir -p $dir >> /dev/null
done
echo "  Pull Docker images"
for image in `cat res/swarm/stacks/portainer.yml |grep image |awk -F\  '{print $2}' |uniq`; do
  echo "    $image"
  docker pull $image >> /dev/null
done
echo " Deploy the stack"
docker stack deploy --compose-file=res/swarm/stacks/portainer.yml Portainer >> /dev/null
echo -n "   Waiting for services to come up."
until curl -s -o /dev/null http://${ipfqdn}:9000/api/status ; do
  echo -n "."
  sleep 2
done
echo "done"
curl -s -o /dev/null http://${ipfqdn}:9000/api/users/admin/init -H "Content-Type: application/json" -X POST -d '{"username":"admin", "password":"'$adminPass'"}'
portAuthToken=`curl -s http://${ipfqdn}:9000/api/auth -H "Content-Type: application/json" -X POST -d '{"username":"admin", "password":"'$adminPass'"}' | jq '.jwt' -r`
portEndpointID=`curl -s http://${ipfqdn}:9000/api/endpoints -H "Authorization: Bearer $portAuthToken" |jq '.[0].Id'`
portSwarmID=`curl -s http://${ipfqdn}:9000/api/endpoints/1/docker/swarm -H "Authorization: Bearer $portAuthToken" |jq -r '.ID'`
curl -s -o /dev/null http://${ipfqdn}:9000/api/endpoints/${portEndpointID} -X PUT \
    -H "Authorization: Bearer $portAuthToken" \
    -d '{"Name": "VTMon", "PublicURL": "'${ipfqdn}'"}'


# Deploy Traefik, using the Portainer API
echo "Deploying Traefik"
echo "  Make persistent storage"
for dir in "/opt/docker/stack.Traefik/service.traefik/logs"; do
  echo "    $dir"
  mkdir -p $dir >> /dev/null
done
configs=`ls res/swarm/configs/Traefik_*`
#echo "  Update config file with host info"
#sed -i "s/<<HOSTIPFQDN>>/$ipfqdn/g" res/swarm/configs/Traefik_traefik-traefik.toml-*
echo "  Create Docker Swarm config files"
for config in $configs; do
  f=`basename $config`
  echo "    $f"
  docker config create $f $config >> /dev/null
done
echo "  Pull Docker images"
for image in `cat res/swarm/stacks/traefik.yml |grep image |awk -F\  '{print $2}' |uniq`; do
  echo "    $image"
  docker pull $image >> /dev/null
done
echo " Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Traefik \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F Env="{ \"name\": \"HOSTIPFQDN\", \"value\": \"${ipfqdn}\"}" \
    -F file=@res/swarm/stacks/traefik.yml 2&> /dev/null

echo -n "   Waiting for services to come up."
until curl -s -o /dev/null http://${ipfqdn}:8080/api ; do 
  echo -n "."
  sleep 2
done
echo "done"

# Deploy Graphite, using the Portainer API
echo "Deploying Graphite"
echo "  Make persistent storage"
for dir in /opt/docker/stack.graphite/service.relay/ /opt/docker/stack.graphite/service.carbon/whisper/ /opt/docker/stack.graphite/service.api/; do
  echo "    $dir"
  mkdir -p $dir >> /dev/null
done
chown -R 990:990 /opt/docker/stack.graphite/service.carbon/whisper/
### Set some system options to optimize it for Graphite
##echo "  Tuning host system"
### Percentage of your RAM which can be left unwritten to disk. MUST be much more than your write rate, which is usually one FS 
### block size (4KB) per metric.
##sysctl -w vm.dirty_ratio=80
### percentage of yout RAM when background writer have to kick in and start writes to disk. Make it way above the value 
### you see in `/proc/meminfo|grep Dirty` so that it doesn't interefere with dirty_expire_centisecs explained below
##sysctl -w vm.dirty_background_ratio=50
### allow page to be left dirty no longer than 10 mins if unwritten page stays longer than time set here, kernel starts writing it out
##sysctl -w vm.dirty_expire_centisecs=$(( 10*60*100 ))
echo "  Create Docker Swarm config files"
for config in `ls res/swarm/configs/Graphite_*`; do
  f=`basename $config`
  echo "    $f"
  docker config create $f $config >> /dev/null
done
echo "  Pull Docker images"
for image in `cat res/swarm/stacks/graphite.yml |grep image |awk -F\  '{print $2}' |uniq`; do
  echo "    $image"
  docker pull $image >> /dev/null
done
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Graphite \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F file=@res/swarm/stacks/graphite.yml 2&> /dev/null




# Deploy Grafana, using the Portainer API
echo "Deploying Grafana"
echo "  Make persistent storage"
for dir in /opt/docker/stack.grafana/service.grafana/data/; do # /opt/docker/stack.grafana/service.grafana/provisioning
  echo "    $dir"
  mkdir -p $dir >> /dev/null
done
chown -R 472:472 /opt/docker/stack.grafana/service.grafana/data/
#echo "  Update stack file with host info"
#sed -i "s/<<HOSTIPFQDN>>/$ipfqdn/g" res/swarm/stacks/grafana.yml
echo "  Pull Docker images"
for image in `cat res/swarm/stacks/grafana.yml |grep image |awk -F\  '{print $2}' |uniq`; do
  echo "    $image"
  docker pull $image >> /dev/null
done
echo " Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "Accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Grafana \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F Env="{ \"name\": \"HOSTIPFQDN\", \"value\": \"${ipfqdn}\"}" \
    -F file=@res/swarm/stacks/grafana.yml 2&> /dev/null
echo -n "  Waiting for services to come up."
until curl -s -o /dev/null http://${ipfqdn}/grafana/login ; do 
  echo -n "."
  sleep 2
done
echo "done"
# Set Grafana admin password
echo "  Setting up Grafana"
echo "    Change admin password"
curl -s -o /dev/null http://${ipfqdn}/grafana/api/admin/users/1/password -X PUT \
    -u admin:admin -H "Content-Type: application/json" -d '{"password":"'$adminPass'"}' 2&> /dev/null
echo "    Create default datasource 'graphite'"
curl -s -o /dev/null http://${ipfqdn}/grafana/api/datasources -X POST \
    -u admin:$adminPass -H "Accept: application/json" -H "Content-Type: application/json" \
    -d '{ "name":"Graphite", "type":"graphite", "url":"http://Graphite_api:8080/", "access":"proxy","basicAuth": false, "isDefault": true}'  2&> /dev/null
echo "    Create folders"
unset grafana_folders
declare -A grafana_folders
for f in `ls res/grafana`; do
  echo "      ${f%-*}"
  grafana_folders[${f%-*}]=`curl -s http://${ipfqdn}/grafana/api/folders -X POST \
      -u admin:$adminPass -H "Accept: application/json" -H "Content-Type: application/json" \
      -d '{ "uid": "'${f#*-}'", "title":"'${f%-*}'"}' | jq -r '.id'`
done
echo "    Create dashboards"
find res/grafana/ -iname *.json | while read file; do
  folder=`echo $file | cut -d/ -f3 | cut -d- -f1`
  dash_name="`echo $file | cut -d/ -f4 | awk -F--- '{print $1}'`"
  #dash_uid=`echo $file | cut -d/ -f4 | awk -F--- '{print $2}' | cut -d. -f1`
  jq "del(.dashboard.id) | .folderId = ${grafana_folders[$folder]}" "$file" > "$file.tmp" && mv -f "$file.tmp" "$file"
  echo "      $folder/$dash_name"
  curl -s -o /dev/null  http://${ipfqdn}/grafana/api/dashboards/db -X POST \
      -u admin:$adminPass -H "Accept: application/json" -H "Content-Type: application/json" \
      -d @"$file"
done


# Deploy Telegraf, using the Portainer API
echo "Deploying Telegraf"
echo "  Create Docker Swarm config files"
configs=`ls res/swarm/configs/Telegraf_*`
for config in $configs; do
  f=`basename $config`
  echo "    $f"
  docker config create $f $config >> /dev/null
done
echo "  Pull Docker images"
for image in `cat res/swarm/stacks/telegraf.yml |grep image |awk -F\  '{print $2}' |uniq`; do
  echo "    $image"
  docker pull $image >> /dev/null
done
echo " Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "Accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Telegraf \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F Env="[{\"name\": \"VCENTERS\", \"value\": \"https://$vcenters/sdk\"},
             {\"name\": \"VCUSERNAME\", \"value\": \"${vcuser}\"},
             {\"name\": \"VCPASSWORD\", \"value\": \"${vcpassword}\"}
            ]" \
    -F file=@res/swarm/stacks/telegraf.yml 2&> /dev/null
#-F Env="[{\"name\": \"VCENTERS\", \"value\": \"$(echo '\"https://'$vcenters'/sdk\"' | sed 's~,~/sdk\\\", \\\"https://~g')\"},
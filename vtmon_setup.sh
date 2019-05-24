#!/bin/bash


CHECK="[$(tput setaf 2; tput bold)✓$(tput setaf 7; tput sgr0)]"

# --------- Disks/Mounts
# Create the /var/lib/docker mountpoint
echo "     Set up /dev/sdb as /var/lib/docker (vg01-docker)"
parted -s /dev/sdb mktable gpt >> /dev/null
parted -s /dev/sdb mkpart primary 0% 100% >> /dev/null
pvcreate /dev/sdb1 >> /dev/null
vgcreate vg01 /dev/sdb1 >> /dev/null
lvcreate vg01 -l 100%FREE -n docker /dev/sdb1 >> /dev/null
mkfs.xfs -fq /dev/mapper/vg01-docker >> /dev/null
mkdir /var/lib/docker >> /dev/null
echo '/dev/mapper/vg01-docker /var/lib/docker         xfs     defaults        1 1' >> /etc/fstab
tput cuu1; echo " {CHECK} Set up /dev/sdb as /var/lib/docker (vg01-docker)"

# Create the /opt mountpoint
echo "     Set up /dev/sdc as /opt (vg02-opt)"
parted -s /dev/sdc mktable gpt >> /dev/null
parted -s /dev/sdc mkpart primary 0% 100% >> /dev/null
pvcreate /dev/sdc1 >> /dev/null
vgcreate vg02 /dev/sdc1 >> /dev/null
lvcreate vg02 -l 100%FREE -n opt /dev/sdc1 >> /dev/null
mkfs.xfs -fq /dev/mapper/vg02-opt >> /dev/null
echo '/dev/mapper/vg02-opt    /opt                    xfs     defaults        1 1' >> /etc/fstab
echo " "${CHECK}

# Mount everything
echo "     Mount all disks"
mount -a >> /dev/null

# -------- Packages
# Remove any version of Docker if it's there
echo "     Remove old Docker packages"
yum remove -qy docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2&> /dev/null
echo " "${CHECK}
# Install some dependencies
echo "     Install some needed packages"
yum install -qy yum-utils device-mapper-persistent-data lvm2 jq htop 2&> /dev/null
echo " "${CHECK}
# Add the official Docker repo
echo "     Add the official Docker repo"
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2&> /dev/null
echo " "${CHECK}
# Install Docker
echo "     Install Docker"
yum install -qy docker-ce docker-ce-cli containerd.io 2&> /dev/null
echo " "${CHECK}

# -------- Docker
# Copy the Docker configs
echo "     Copy the Docker config files"
cp -fr res/docker/ /etc/ >> /dev/null
echo " "${CHECK}

# Enable, and Start Docker
echo "     Enable and start the Docker service"
systemctl enable docker 2&> /dev/null
systemctl start docker 2&> /dev/null
echo " "${CHECK}

# Initialize the swarm
echo "     Initialize the Docker Swarm"
docker swarm init >> /dev/null
echo " "${CHECK}

# Setup some networks
echo "     Create networks"
for net in traefik-net graphite-net elastic-net; do
  echo -n "  $net"
  docker network create --driver overlay --attachable $net >> /dev/null
  echo " "${CHECK}
done

while true; do
    read -p "     Enter new admin password: " adminPass
#    echo
    read -p "     Confirm new admin password: " adminPass2
#    echo
    [ "$adminPass" = "$adminPass2" ] && break
    echo "     Passwords didn't match, please try again"
done
#read -sp "Set admin password: " adminPass
read -p "     IP or FQDN of this machine: " ipfqdn
read -p "     vCenter addresses, comma-separated: " vcenters
read -p "     vCenter user: " vcuser
while true; do
    read -p "     Enter vCenter password: " vcpassword
#    echo
    read -p "     Confirm vCenter password: " vcpassword2
#    echo
    [ "$vcpassword" = "$vcpassword2" ] && break
    echo "     Passwords didn't match, please try again"
done

# Deploy Portainer, using the command-line
echo "     Deploy Portainer"
echo "       Make persistent storage"
for dir in "/opt/docker/stack.Portainer/service.portainer"; do
  echo "         $dir"
  mkdir -p $dir >> /dev/null
  tput cuu1; echo " ${CHECK}     $dir"
done
echo "       Pull Docker images"
images=`cat res/swarm/stacks/portainer.yml |grep image |awk -F\  '{print $2}' |uniq`
for i in $images; do
  echo "         $i"
  docker pull $i >> /dev/null
  tput cuu1; echo " ${CHECK}     $i"
done
echo "       Deploy the stack"
docker stack deploy --compose-file=res/swarm/stacks/portainer.yml Portainer >> /dev/null
tput cuu1; echo " ${CHECK}   Deploy the stack"
echo -n "       Waiting for services to come up [  "
i=1
sp="/-\|"
until curl -s -o /dev/null http://${ipfqdn}:9000/api/status ; do
  printf "\b\b${sp:i++%${#sp}:1}]"
  sleep 0.5
done
echo
tput cuu1; echo " ${CHECK}   Waiting for services to come up    "

echo "       Set up Portainer"
# Change admin password
echo "         Change admin password"
curl -s -o /dev/null http://${ipfqdn}:9000/api/users/admin/init -H "Content-Type: application/json" -X POST -d '{"username":"admin", "password":"'$adminPass'"}'
echo " ${CHECK}   Change admin password"

# Generate new admin auth token
echo "         Generate admin auth token"
portAuthToken=`curl -s http://${ipfqdn}:9000/api/auth -H "Content-Type: application/json" -X POST -d '{"username":"admin", "password":"'$adminPass'"}' | jq '.jwt' -r`
echo " ${CHECK}   Generate admin auth token"

# Gather some endpoint details
echo "         Gather endpoint details"
portEndpointID=`curl -s http://${ipfqdn}:9000/api/endpoints -H "Authorization: Bearer $portAuthToken" |jq '.[0].Id'`
portSwarmID=`curl -s http://${ipfqdn}:9000/api/endpoints/1/docker/swarm -H "Authorization: Bearer $portAuthToken" |jq -r '.ID'`
echo " ${CHECK}   Gather endpoint details"

# Set the endpoint name
echo "         Set Endpoint name"
curl -s -o /dev/null http://${ipfqdn}:9000/api/endpoints/${portEndpointID} -X PUT \
    -H "Authorization: Bearer $portAuthToken" \
    -d '{"Name": "VTMon", "PublicURL": "'${ipfqdn}'"}'
echo " ${CHECK}   Set Endpoint name"
echo "     DONE"
read -p "     Hit ENTER to continue"



# Deploy Traefik, using the Portainer API
echo "     Deploy Traefik"
echo "       Make persistent storage"
for dir in "/opt/docker/stack.Traefik/service.traefik/logs"; do
  echo "         $dir"
  mkdir -p $dir >> /dev/null
  tput cuu1; echo " ${CHECK}     $dir"
done
echo "       Create Docker Swarm config files"
configs=`ls res/swarm/configs/Traefik_*`
for c in $configs; do
  f=`basename $c`
  echo "         $f"
  docker config create $f $c >> /dev/null
  tput cuu1; echo " ${CHECK}     $f"
done
echo "       Pull Docker images"
images=`cat res/swarm/stacks/traefik.yml |grep image |awk -F\  '{print $2}' |uniq`
for i in $images; do
  echo "         $i"
  docker pull $i >> /dev/null
  tput cuu1; echo " ${CHECK}     $i"
done
echo "       Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Traefik \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F Env="[{ \"name\": \"HOSTIPFQDN\", \"value\": \"${ipfqdn}\"}]" \
    -F file=@res/swarm/stacks/traefik.yml
tput cuu1; echo " ${CHECK}   Deploy the stack"

echo -n "       Waiting for services to come up [  "
i=1
sp="/-\|"
until curl -s -o /dev/null http://${ipfqdn}:8080/api ; do
  printf "\b\b${sp:i++%${#sp}:1}]"
  sleep 0.5
done
echo
tput cuu1; echo " ${CHECK}   Waiting for services to come up    "

echo "     DONE"
read -p "     Hit ENTER to continue"



# Deploy Graphite, using the Portainer API
echo "     Deploy Graphite"
echo "       Make persistent storage"
for dir in /opt/docker/stack.graphite/service.relay/ /opt/docker/stack.graphite/service.carbon/whisper/ /opt/docker/stack.graphite/service.api/; do
  echo "         $dir"
  mkdir -p $dir >> /dev/null
  tput cuu1; echo " ${CHECK}     $dir"
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
echo "       Create Docker Swarm config files"
echo "       Create Docker Swarm config files"
for config in `ls res/swarm/configs/Graphite_*`; do
  f=`basename $config`
  echo "         $f"
  docker config create $f $config >> /dev/null
  tput cuu1; echo " ${CHECK}     $f"
done

echo "       Pull Docker images"
for image in `cat res/swarm/stacks/graphite.yml |grep image |awk -F\  '{print $2}' |uniq`; do
  echo "         $image"
  docker pull $image >> /dev/null
  tput cuu1; echo " ${CHECK}     $image"
done
echo "       Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Graphite \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F file=@res/swarm/stacks/graphite.yml 2&> /dev/null
tput cuu1; echo " ${CHECK}   Deploy the stack"
echo "     DONE"
read -p "     Hit ENTER to continue"



# Deploy Grafana, using the Portainer API
echo "     Deploy Grafana"
echo "       Make persistent storage"
for dir in /opt/docker/stack.grafana/service.grafana/data/; do # /opt/docker/stack.grafana/service.grafana/provisioning
  echo "         $dir"
  mkdir -p $dir >> /dev/null
  tput cuu1; echo " ${CHECK}     $dir"
done
chown -R 472:472 /opt/docker/stack.grafana/service.grafana/data/

echo "       Pull Docker images"
images=`cat res/swarm/stacks/grafana.yml |grep image |awk -F\  '{print $2}' |uniq`
for i in $images; do
  echo "         $i"
  docker pull $i >> /dev/null
  tput cuu1; echo " ${CHECK}     $i"
done
echo "       Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "Accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Grafana \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F Env="[{ \"name\": \"HOSTIPFQDN\", \"value\": \"${ipfqdn}\"}]" \
    -F file=@res/swarm/stacks/grafana.yml 2&> /dev/null
tput cuu1; echo " ${CHECK}   Deploy the stack"
echo -n "       Waiting for services to come up [  "
i=1
sp="/-\|"
until curl http://${ipfqdn}:8080/api  -s| jq '.docker.backends."backend-Grafana-grafana"' -e > /dev/null ; do
  printf "\b\b${sp:i++%${#sp}:1}]"
  sleep 0.5
done
echo
tput cuu1; echo " ${CHECK}   Waiting for services to come up    "

# Set Grafana admin password
echo "       Set up Grafana"
echo "         Change admin password"
curl -s -o /dev/null http://${ipfqdn}/grafana/api/admin/users/1/password -X PUT \
    -u admin:admin -H "Content-Type: application/json" -d '{"password":"'$adminPass'"}'
tput cuu1; echo " ${CHECK}     Change admin password"

# Create the default datasource
echo "         Create default datasource 'graphite'"
curl -s -o /dev/null http://${ipfqdn}/grafana/api/datasources -X POST \
    -u admin:$adminPass -H "Accept: application/json" -H "Content-Type: application/json" \
    -d '{ "name":"Graphite", "type":"graphite", "url":"http://Graphite_api:8080/", "access":"proxy","basicAuth": false, "isDefault": true}'
tput cuu1; echo " ${CHECK}     Create default datasource 'graphite'"

# Create Grafana dashboards from the files inside res/grafana/*/*
echo "         Create folders"
for f in `ls res/grafana`; do
  f_name=${f%-*}
  f_uid=${f#*-}
  echo "           ${f_name}"
  curl -s -o /dev/null http://${ipfqdn}/grafana/api/folders -X POST \
      -u admin:$adminPass -H "Accept: application/json" -H "Content-Type: application/json" \
      -d '{ "uid": "'${f_uid}'", "title":"'${f_name}'"}'
  tput cuu1; echo " ${CHECK}       ${f_name}"
done
echo "         Import dashboards"
find res/grafana/ -iname *.json | while read file; do
  dashboard_name="`echo $file | cut -d/ -f4 | awk -F--- '{print $1}'`"
  folder_name=`echo $file | cut -d/ -f3 | cut -d- -f1`
  echo "           $folder_name/$dashboard_name"
  folder_uid=`echo $file | cut -d/ -f3 | cut -d- -f2`
  folder_id=`curl -s "http://${ipfqdn}/grafana/api/folders/${folder_uid}" |jq '.id'`
#  dashboard_uid=`echo $file | cut -d/ -f4 | awk -F--- '{print $2}' | cut -d. -f1`
  jq "del(.dashboard.id) | .folderId = ${folder_id}" "$file" > "$file.tmp" && mv -f "$file.tmp" "$file"
  curl -s -o /dev/null  http://${ipfqdn}/grafana/api/dashboards/db -X POST \
      -u admin:$adminPass -H "Accept: application/json" -H "Content-Type: application/json" \
      -d @"$file"
  tput cuu1; echo " ${CHECK}       $folder_name/$dashboard_name"
done
echo "     DONE"
read -p "     Hit ENTER to continue"


# Deploy Telegraf, using the Portainer API
echo "     Deploy Telegraf"
echo "       Create Docker Swarm config files"
configs=`ls res/swarm/configs/Telegraf_*`
for c in $configs; do
  f=`basename $c`
  echo "         $f"
  docker config create $f $c >> /dev/null
  tput cuu1; echo " ${CHECK}     $f"
done
echo "       Pull Docker images"
images=`cat res/swarm/stacks/telegraf.yml |grep image |awk -F\  '{print $2}' |uniq`
for i in $images; do
  echo "         $i"
  docker pull $i >> /dev/null
  tput cuu1; echo " ${CHECK}     $i"
done
echo "       Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "Accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Telegraf \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F Env="[{\"name\": \"VCENTERS\", \"value\": \"$(echo 'https://'$vcenters'/sdk' | sed 's~,~/sdk\\\", \\\"https://~g')\"},
             {\"name\": \"VCUSERNAME\", \"value\": \"${vcuser}\"},
             {\"name\": \"VCPASSWORD\", \"value\": \"${vcpassword}\"}
            ]" \
    -F file=@res/swarm/stacks/telegraf.yml 2&> /dev/null
tput cuu1; echo " ${CHECK}   Deploy the stack"
echo "     DONE"
#    -F Env="[{\"name\": \"VCENTERS\", \"value\": \"https://$vcenters/sdk\"},

#    -F Env="[{\"name\": \"VCENTERS\", \"value\": \"$(echo 'https://'$vcenters'/sdk' | sed 's~,~/sdk\\\", \\\"https://~g')\"},

echo
echo "VTMon is now deployed and ready to go."
echo "You can visit Grafana at http://${ipfqdn}/grafana/, and login with admin:${adminPass}."
echo ""
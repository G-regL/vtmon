#!/bin/bash

# --------- Disks/Mounts
# Create the /var/lib/docker mountpoint
echo "Setting up /dev/sdb as /var/lib/docker (vg01-docker)"
parted -s /dev/sdb mkpart primary 0% 100%
pvcreate /dev/sdb1
vgcreate vg01 /dev/sdb1
lvcreate vg01 -l 100%FREE -n docker /dev/sdb1
mkfs.xfs /dev/mapper/vg01-docker
mkdir /var/lib/docker
echo '/dev/mapper/vg01-docker /var/lib/docker         xfs     defaults        1 1' >> /etc/fstab
# Create the /opt mountpoint
echo "Setting up /dev/sdc as /opt (vg02-opt)"
parted -s /dev/sdc mkpart primary 0% 100%
pvcreate /dev/sdc1
vgcreate vg02 /dev/sdc1
lvcreate vg02 -l 100%FREE -n opt /dev/sdc1
mkfs.xfs /dev/mapper/vg02-opt
echo '/dev/mapper/vg02-opt    /opt                    xfs     defaults        1 1' >> /etc/fstab
# Mount everything
echo "Mounting all disks"
mount -a

# -------- Packages
# Remove any version of Docker if it's there
echo "Removing any old Docker packages"
sudo yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine
# Install some dependencies
echo "Installing some needed packages"
sudo yum install -y yum-utils device-mapper-persistent-data lvm2 jq
# Add the official Docker repo
echo "Adding the official Docker repo"
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
# Install Docker
echo "Installing Docker"
sudo yum install -y docker-ce docker-ce-cli containerd.io

# -------- Docker
# Copy the Docker configs
echo "Copy the Docker config files"
cp -fr res/docker/ /etc/
# Enable, and Start Docker
echo "Enable and start the Docker service"
sudo systemctl enable docker
sudo systemctl start docker
# Initialize the swarm
echo "Initialize the Docker Swarm"
docker swarm init
# Setup some networks
echo "Creating some required networks"
for net in traefik-net graphite-net elastic-net; do
  echo "  $net"
  docker network create --driver overlay --attachable $net >> /dev/null
done

while true; do
    read -s -p "Enter new admin password: " password
    echo
    read -s -p "Confirm new admin password: " password2
    echo
    [ "$password" = "$password2" ] && break
    echo "Please try again"
done
#read -sp "Set admin password: " adminPass
read -p "IP or FQDN of this machine: " ipfqdn
read -p "vCenter addresses, comma-separated: " vcenters
read -p "vCenter user: " vcuser
while true; do
    read -s -p "Enter vCenter password: " vcpassword
    echo
    read -s -p "Confirm vCenter password: " vcpassword2
    echo
    [ "$vcpassword" = "$vcpassword2" ] && break
    echo "Please try again"
done

# Deploy Portainer, using the command-line
echo "Deploying Portainer"
echo "  Make persistent storage"
for dir in "/opt/docker/stack.Portainer/service.portainer"; do
  echo "    $dir"
  mkdir -p $dir >> /dev/null
done
echo "  Pull Docker images"
for image in portainer/agent:latest portainer/portainer:latest; do
  echo "    $image"
  docker pull $image >> /dev/null
done
echo " Deploy the stack"
docker stack deploy --compose-file=res/swarm/stacks/portainer.yml Portainer >> /dev/null
echo -n "  Waiting for services to come up."
until curl -s -o /dev/null http://${ipfqdn}:9000/api/status 2&> /dev/null
 do
  echo -n "."
  sleep 1
done
echo "done"
curl -s -o /dev/null http://${ipfqdn}:9000/api/users/admin/init -H "Content-Type: application/json" -X POST -d '{"username":"admin", "password":"'$adminPass'"}' 2&> /dev/null
portAuthToken=`curl -s http://${ipfqdn}:9000/api/auth -H "Content-Type: application/json" -X POST -d '{"username":"admin", "password":"'$adminPass'"}'`
portEndpointID=`curl -s http://${ipfqdn}:9000/api/endpoints -H "Authorization: Bearer $portAuthToken" |jq '.[0].Id'`
portSwarmID=`curl -s http://${ipfqdn}:9000/api/endpoints/1/docker/swarm -H "Authorization: Bearer $portAuthToken" |jq -r '.ID'`




# Deploy Traefik, using the Portainer API
echo "Deploying Traefik"
echo "  Make persistent storage"
for dir in "/opt/docker/stack.Traefik/service.traefik/logs"; do
  echo "    $dir"
  mkdir -p $dir >> /dev/null
done
configs=`ls res/swarm/configs/Traefik_*`
echo "  Update config file with host info"
sed -i "s/<<HOSTIPFQDN>>/$ipfqdn/g" res/swarm/configs/Traefik_traefik-traefik.toml-*
echo "  Create Docker Swarm config files"
for config in $configs; do
  echo "    $config"
  docker config create $config res/swarm/configs/$config >> /dev/null
done
echo "  Pull Docker images"
for image in "traefik:1.7.10-alpine"; do
  echo "    $image"
  docker pull $image >> /dev/null
done
echo " Deploy the stack"
curl -s "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Traefik \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F file=@res/swarm/stacks/traefik.yml 2&> /dev/null

echo -n "  Waiting for services to come up."
until curl -s -o /dev/null http://${ipfqdn}:8080/api 2&> /dev/null
 do 
  echo -n "."
  sleep 1
done
echo "done"

# Deploy Graphite, using the Portainer API
echo "Deploying Graphite"
echo "  Make persistent storage"
for dir in "/opt/docker/stack.graphite/service.relay/ /opt/docker/stack.graphite/service.carbon/whisper/ /opt/docker/stack.graphite/service.api/"; do
  echo "    $dir"
  mkdir -p $dir >> /dev/null
done
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
  echo "    $config"
  docker config create $config res/swarm/configs/$config >> /dev/null
done
echo "  Pull Docker images"
for image in "openmetric/carbon-c-relay:latest openmetric/go-carbon:latest openmetric/carbonapi:latest"; do
  echo "    $image"
  docker pull $image >> /dev/null
done
curl -v "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
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
for dir in "/opt/docker/stack.grafana/service.grafana/data/"; do # /opt/docker/stack.grafana/service.grafana/provisioning
  echo "    $dir"
  mkdir -p $dir >> /dev/null
done
echo "  Update stack file with host info"
sed -i "s/<<HOSTIPFQDN>>/$ipfqdn/g" res/swarm/stacks/grafana.yml
echo "  Pull Docker images"
for image in "grafana/grafana:latest"; do
  echo "    $image"
  docker pull $image >> /dev/null
done
echo " Deploy the stack"
curl -s "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Grafana \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F file=@res/swarm/stacks/grafana.yml 2&> /dev/null





#### Deploy Telegraf, using the Portainer API
###echo "Deploying Telegraf"
###sed -i "s/<<HOSTIPFQDN>>/$ipfqdn/g" res/swarm/configs/Traefik_traefik-traefik.toml-20190516.0747
###docker config create Traefik_traefik-traefik.toml-20190516.0747 res/swarm/configs/Traefik_traefik-traefik.toml-20190516.0747 >> /dev/null
###docker pull telegraf:1.10.0-alpine >> /dev/null
###curl -v "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
###    -H "Authorization: Bearer $portAuthToken" \
###    -H "accept: application/json" \
###    -H "Content-Type: multipart/form-data" \
###    -F Name=Traefik \
###    -F EndpointID=${portEndpointID} \
###    -F SwarmID=${portSwarmID} \
###    -F file=@res/swarm/stacks/traefik.yml


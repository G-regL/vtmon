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

echo "+------------------------------------------------------------------------------+"
echo "+        Setup Tool for Virtualization Technologies Logging (VTLog)         +"
echo "+------------------------------------------------------------------------------+"
echo
echo "We need to gather some details for the depoyment before proceeding"
echo
echo "If you mis-type something, please press Ctrl-C to quit, and restart the setup"
echo 
echo "The systems need to have an admin user account created and we'll need to know"
echo "what password you want to use."
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
echo "vCenter in order to gather the metrics. It should have the 'Read-only' role"
echo "granted to it at the root of the vCenter."
echo "It's recommended to use an SSO account, for ease of management."
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

echo "We've got everything we need to setup, so let's get started!"
read -p "Hit ENTER to continue"
echo


#    GOVC_URL=https://${vcuser}:${vcpassowrd}@



# Setup some networks
echo " Create Swarm networks"
for net in elastic-net; do
  echo "${SPACE} $net"
  docker network create --driver overlay --attachable $net >> /dev/null
  echo "${CHECK} $net"
done
echo "DONE"
read -p "Hit ENTER to continue"
echo


# Deploy Elastic Stack, using the Portainer API
echo "Deploy Elastic"
echo " Make persistent storage"
make_persistent_storage /opt/docker/stack.elastic/service.elasticsearch01/data 1000:1000

### Set some system options to optimize it for Graphite
echo " Tuning host system"
echo "${SPACE} Set vm.max_map_count"
echo "vm.max_map_count=262144" >> /etc/sysctl.d/10-elastic.conf
echo "${CHECK} Set vm.max_map_count"

echo "${SPACE} Apply settings"
sysctl --system >> /dev/null
echo "${CHECK} Apply settings"

echo " Pull Docker images"
pull_docker_images $(cat res/swarm/stacks/elastic.yml |grep image |awk -F\  '{print $2}' |uniq)

echo " Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "Accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Elastic \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F Env="[{ \"name\": \"ELASTIC_PASSWORD\", \"value\": \"${adminiPass}\"}]" \
    -F file=@res/swarm/stacks/elastic.yml 2&> /dev/null
wait_for_service "curl -s http://${ipfqdn}:8080/api | jq '.docker.backends.\"backend-Elastic-elasticsearch01\"' -e > /dev/null"
###until curl http://${ipfqdn}:8080/api  -s| jq '.docker.backends."backend-Grafana-grafana"' -e > /dev/null ; do



#!/bin/bash

  CHECK="$(tput cuu1) [$(tput setaf 2; tput bold)✓$(tput setaf 7; tput sgr0)]"
  SPACE="    "

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

function create_swarm_configs () {
  for config in $*; do
    f=`basename $config`
    echo "${SPACE} $f"
    docker config create $f $config >> /dev/null
    echo "${CHECK} $f"
  done
}

echo "+------------------------------------------------------------------------------+"
echo "+        Setup Tool for Virtualization Technologies Monitoring (VTMon)         +"
echo "+------------------------------------------------------------------------------+"
echo
echo "We need to gather some details for the depoyment before proceeding"
echo
echo "If you mis-type something, please press Ctrl-C to quit, and restart the setup"
echo 
echo "Portainer and Grafana both need to have an admin user account created and we'll"
echo "need to know what password you want to use."
# Gather some details for the deployment
while true; do
    read -sp " Admin user password: " adminPass
    echo
    read -sp " Confirm password: " adminPass2
    echo
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
echo "vCenter in order to gather the metrics. "
echo "It should have the 'Read-only' role granted to it at the root of the vCenter."
echo "It's recommended to use an SSO account, for ease of management."
read -p " vCenter user: " vcuser
while true; do
    read -sp " vCenter user password: " vcpassword
    echo
    read -sp " Confirm password: " vcpassword2
    echo
    [ "$vcpassword" = "$vcpassword2" ] && break
    echo "ERROR: Passwords didn't match, please try again"
done
unset vcpassword2
echo

echo "We've got everything we need to setup, so let's get started!"
read -p "Hit ENTER to continue"
echo

# Initialize the swarm
echo "${SPACE} Initialize the Docker Swarm"
docker swarm init >> /dev/null
echo "${CHECK} Initialize the Docker Swarm"
echo

# Setup some networks
echo " Create Swarm networks"
for net in graphhouse-net; do
  echo "${SPACE} $net"
  docker network create --driver overlay --attachable $net >> /dev/null
  echo "${CHECK} $net"
done
echo "DONE"
read -p "Hit ENTER to continue"
echo

# Deploy Portainer, using the command-line
echo "Deploy Portainer"

echo " Deploy the stack"
docker stack deploy --compose-file=res/swarm/stacks/portainer.yml Portainer >> /dev/null &
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
portSwarmID=`curl -s http://${ipfqdn}:9000/api/endpoints/${portEndpointID}/docker/swarm -H "Authorization: Bearer $portAuthToken" |jq -r '.ID'`
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


# Deploy GraphHouse (Clickhouse + Graphite), using the Portainer API
echo "Deploy GraphHouse"

echo " Create Docker Swarm config files"
create_swarm_configs $(ls res/swarm/configs/graphhouse/*)

echo " Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=GraphHouse \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F Env="[{ \"name\": \"HOSTIPFQDN\", \"value\": \"${ipfqdn}\"}]" \
    -F file=@res/swarm/stacks/graphhouse.yml 2&> /dev/null &
#stack_services=`cat res/swarm/stacks/graphite.yml |grep replicas |grep -v 0 |wc -l`
wait_for_service "[ \`docker service ls | grep GraphHouse | awk '{print \$4}' | grep '1/1' | wc -l\` -eq '5' ]"
echo "DONE"
read -p "Hit ENTER to continue"
echo



# Deploy Grafana, using the Portainer API
echo "Deploy Grafana"
echo " Deploy the stack"
curl -s -o /dev/null "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
    -H "Authorization: Bearer $portAuthToken" \
    -H "Accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F Name=Grafana \
    -F EndpointID=${portEndpointID} \
    -F SwarmID=${portSwarmID} \
    -F Env="[{ \"name\": \"HOSTIPFQDN\", \"value\": \"${ipfqdn}\"}]" \
    -F file=@res/swarm/stacks/grafana.yml 2&> /dev/null &
wait_for_service "curl -s -o /dev/null http://${ipfqdn}/api"
#wait_for_service "curl -s http://${ipfqdn}/api | jq '.docker.backends.\"backend-Grafana-grafana\"' -e > /dev/null"
###until curl http://${ipfqdn}:8080/api  -s| jq '.docker.backends."backend-Grafana-grafana"' -e > /dev/null ; do


# Set Grafana admin password
echo " Configure Grafana"
echo "${SPACE} Set admin password"
curl -s -o /dev/null http://${ipfqdn}/api/admin/users/1/password -X PUT \
    -u admin:admin -H "Content-Type: application/json" -d '{"password":"'$adminPass'"}'
echo "${CHECK} Set admin password"

# Create the default datasource
echo " Create datasources"
echo "${SPACE} Graphite"
curl -s -o /dev/null http://${ipfqdn}/api/datasources -X POST \
    -u admin:$adminPass -H "Accept: application/json" -H "Content-Type: application/json" \
    -d '{ "name":"Graphite", "type":"graphite", "url":"http://carbonapi:8080/", "access":"proxy","basicAuth": false, "isDefault": true}'
echo "${CHECK} Graphite"

# Create Grafana dashboards from the files inside res/grafana/*/*
echo " Create dashboard folders"
for f in `ls res/grafana`; do
  f_name=${f%-*}
  f_uid=${f#*-}
  echo "${SPACE} ${f_name}"
  curl -s -o /dev/null http://${ipfqdn}/api/folders -X POST \
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
  folder_id=`curl -s -u admin:$adminPass "http://${ipfqdn}/api/folders/${folder_uid}" |jq '.id'`
#  dashboard_uid=`echo $file | cut -d/ -f4 | awk -F--- '{print $2}' | cut -d. -f1`
  jq "del(.dashboard.id) | .folderId = ${folder_id}" "$file" > "$file.tmp" && mv -f "$file.tmp" "$file"
  curl -s -o /dev/null  http://${ipfqdn}/api/dashboards/db -X POST \
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
create_swarm_configs $(ls res/swarm/configs/telegraf/*)

echo " Deploy the stack"
curl -s "http://${ipfqdn}:9000/api/stacks?type=1&method=file&endpointId=${portEndpointID}" -X POST \
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
    -F file=@res/swarm/stacks/telegraf.yml 2&> /dev/null &
stack_services=`cat res/swarm/stacks/telegraf.yml |grep replicas |grep -v 0 |wc -l`
wait_for_service "[ \`docker service ls | grep Telegraf |awk '{print \$4}' |grep '1/1' |wc -l\` -eq '${stack_services}' ]"

echo "DONE"
read -p "Hit ENTER to continue"
echo

echo
echo "VTMon is now deployed and ready to go!"
echo
echo "Please visit Grafana at http://${ipfqdn}, and login with admin:${adminPass}."
#echo 
#echo "You can also visit Moira at http://${ipfqdn}:8083 to setup alerts."
#echo "Extra steps will be required to enable email/Slack notifications."
echo
echo "Should you want/need to check on the status of the system, you can use the following URLs"
echo "  Portainer (Container manager)     - http://${ipfqdn}:9000"
#echo "  Traefik (Load balancer)           - http://${ipfqdn}:8080/dashboard/"
#echo "  Tabix (Metrics management GUI)    - http://${ipfqdn}:8081/"
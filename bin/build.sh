#!/bin/bash

echo "Build Docker Images"

relayVers="3.7.2"
echo " carbon-c-relay"
curl -sLo /tmp/carbon-c-relay-${relayVers}.zip https://github.com/grobian/carbon-c-relay/archive/refs/tags/v${relayVers}.zip
unzip -q /tmp/carbon-c-relay-${relayVers}.zip -d  /tmp/
#cd carbon-c-relay-${relayVers}
docker build -t sscvssu/carbon-c-relay:v${relayVers} -t sscvssu/carbon-c-relay /tmp/carbon-c-relay-${relayVers}
docker stack rm `docker stack ls --format "{{ .Name }}"`
docker rm -f `docker ps -qa`
docker network rm graphhouse-net
docker swarm leave --force
rm /opt/docker/stack.* -fR
systemctl stop docker
umount /var/lib/docker
umount /opt
wipefs -qfa /dev/sdb1 /dev/sdc1
wipefs -qfa /dev/sdb /dev/sdc




    
docker stack rm `docker stack ls --format "{{ .Name }}"`
docker rm -f `docker ps -qa`
docker network rm graphhouse-net
docker swarm leave --force

rm -fR /opt/docker/GraphHouse/carbon/data/*
rm -fR /opt/docker/GraphHouse/clickhouse/data/*
rm -fR /opt/docker/GraphHouse/clickhouse/metadata/* 
rm -fR /opt/docker/Grafana/grafana/data/*
rm -fR /opt/docker/Portainer/portainer/data/*
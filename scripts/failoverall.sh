#!/bin/bash

region=rxt-dfw-admin

flbs=`openstack --os-cloud=$region  loadbalancer list --provider=amphora -c id -f value`
for flb in $flbs
do
  echo "Attempting to failover LB:  $flb"
  openstack --os-cloud=rxt-dfw-admin loadbalancer failover $flb
  sleep 15
done

#!/bin/bash

while true; do

  errlbs=`openstack --os-cloud=rxt-dprod-admin  loadbalancer list --provisioning-status=ERROR --provider=amphora -c id -f value`
  line_count=$(wc -l <<< "$errlbs")
  echo "There are $line_count LBs in ERROR...."
  if [[ $line_count > 1 ]]; then
     notify-send -u critical "$line_count LBs in ERROR....."
     date +"%Y-%m-%d %H:%M:%S"
  fi
  sleep 90
done

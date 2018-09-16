#!/bin/bash
source ./sokkyou/sokkyou.sh

for REMOTE in ${NGINX[@]}; do
  SLACK "deploy nginx ($REMOTE $USER)"

  RSYNC conf/nginx.cnf /etc/nginx/nginx.cnf

  SLACK ":ok_hand:"
done

#!/bin/bash
source ./sokkyou/sokkyou.sh

for REMOTE in ${NGINX[@]}; do
  SLACK "deploy nginx ($REMOTE $USER)"

  RSYNC conf/nginx.conf /etc/nginx/nginx.conf
  ssh isucon@$REMOTE "sudo systemctl restart nginx"

  SLACK ":ok_hand:"
done

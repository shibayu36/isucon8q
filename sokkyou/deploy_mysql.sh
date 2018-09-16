#!/bin/bash
source ./sokkyou/sokkyou.sh

REMOTE=$DB

SLACK "deploy mysql ($REMOTE $USER)"
RSYNC conf/my.cnf /etc/my.cnf
ssh "isucon@$REMOTE" "sudo systemctl restart mariadb"

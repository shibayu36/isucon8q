#!/bin/bash
source ./sokkyou/sokkyou.sh

REMOTE=$DB

RSYNC conf/my.cnf /etc/my.cnf
ssh "isucon@$REMOTE" "sudo systemctl restart mariadb"

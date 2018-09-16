#!/bin/bash
set -eux

source ./sokkyou/sokkyou.sh

DATE=$(date '+%Y%m%d_%H%M%S')

SLACK "prebench ($USER)"

ssh 'isucon01' "sudo mv /var/log/nginx/access.log.tsv /var/log/nginx/access.log.tsv.$DATE"
ssh 'isucon02' "sudo mv /var/log/nginx/access.log.tsv /var/log/nginx/access.log.tsv.$DATE"
# ssh 'isucon01' "sudo mv /var/log/mysql/mysql-slow.log /var/log/mysql/mysql-slow.log.$DATE"

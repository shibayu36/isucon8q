#!/bin/bash
set -eux

source ./sokkyou/sokkyou.sh

DATE=$(date '+%Y%m%d_%H%M%S')

SLACK "prebench ($USER)"

for REMOTE in ${NGINX[@]}; do
  ssh "isucon@$REMOTE" "if [ -f /var/log/nginx/access.log.tsv ]; then sudo mv /var/log/nginx/access.log.tsv /var/log/nginx/access.log.tsv.$DATE; fi"
done

ssh "isucon@$DB" "if [ -f /var/log/mariadb/mysql-slow.log ]; then sudo mv /var/log/mariadb/mysql-slow.log /var/log/mariadb/mysql-slow.log.$DATE; fi"

./sokkyou/deploy_nginx.sh
./sokkyou/deploy_mysql.sh # この中でアプリケーションデプロイしてます

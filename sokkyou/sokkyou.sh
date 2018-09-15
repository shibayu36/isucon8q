#!/bin/bash
set -eux

source ./sokkyou/sokkyou-settings.sh

SLACK_WEBHOOK_URL=$SLACK_WEBHOOK_URL
REMOTE="isucon@$ISUCON01"
REMOTE_LIST="$ISUCON01 $ISUCON02 $ISUCON03"
BACKEND="$ISUCON01 $ISUCON02 $ISUCON03"
BACKEND_APP="$ISUCON01 $ISUCON02"

function SLACK() {
  curl -X POST --data-urlencode "payload={\"channel\": \"#ディメンジョナルハイソサイエティぬれねずみ\", \"username\": \"ぬれねずみ\", \"text\": \"$*\", \"icon_emoji\": \":mouse:\"}" $SLACK_WEBHOOK_URL
}

# /etc/sudoersに追加する
# Defaults!/usr/bin/rsync    !requiretty
# function RSYNC() {
#   rsync -avz --exclude-from=.gitignore --exclude='.git' -e 'ssh' . isucon@$IPADDR:/home/isucon/isubata/
# }

# function RSYNC_GIT() {
#     rsync -avz -e ssh --rsync-path='sudo rsync' --exclude=.git --exclude=`git -C $1 ls-files --exclude-standard -oi --directory` "$1" "$REMOTE:$2"
# }

# function BACKUP() {
#     rsync -avz -e ssh --rsync-path='sudo rsync' --exclude='.*' "$REMOTE:$1" "$2"
# }

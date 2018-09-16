#!/bin/bash
set -eux

source ./sokkyou/sokkyou-settings.sh

SLACK_WEBHOOK_URL=$SLACK_WEBHOOK_URL
REMOTE="isucon@isucon01"
REMOTE_LIST="isucon01 isucon02 isucon03"
BACKEND="isucon01 isucon02 isucon03"
BACKEND_APP="isucon01 isucon02 isucon03"
DB="isucon01"
NGINX="isucon03"

function SLACK() {
  curl -X POST --data-urlencode "payload={\"channel\": \"#ディメンジョナルハイソサイエティぬれねずみ\", \"username\": \"ぬれねずみ\", \"text\": \"$*\", \"icon_emoji\": \":mouse:\"}" $SLACK_WEBHOOK_URL
}

# /etc/sudoersに追加する
# Defaults!/usr/bin/rsync    !requiretty
function RSYNC() {
  rsync --rsync-path='sudo rsync' -avz --exclude-from=.gitignore --exclude='.git' -e 'ssh' "$1" "isucon@$REMOTE:$2"
}

# function RSYNC_GIT() {
#     rsync -avz -e ssh --rsync-path='sudo rsync' --exclude=.git --exclude=`git -C $1 ls-files --exclude-standard -oi --directory` "$1" "$REMOTE:$2"
# }

# function BACKUP() {
#     rsync -avz -e ssh --rsync-path='sudo rsync' --exclude='.*' "$REMOTE:$1" "$2"
# }

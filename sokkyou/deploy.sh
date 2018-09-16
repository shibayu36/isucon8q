#!/bin/bash
source ./sokkyou/sokkyou.sh

for REMOTE in ${BACKEND[@]}; do
  SLACK "deploy ($REMOTE $USER)"

  rsync -avz --exclude-from=.gitignore --exclude='.git' -e 'ssh' . isucon@$REMOTE:/home/isucon/torb/

  ssh isucon@$REMOTE "cd /home/isucon/torb/webapp/perl && ~/local/perl/bin/carton install && sudo systemctl restart torb.perl.service && sudo sysctl -p"

  SLACK ":ok_hand:"
done

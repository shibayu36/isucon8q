#!/bin/bash
source ./sokkyou/sokkyou.sh

for REMOTE in ${BACKEND[@]}; do
  SLACK "deploy ($REMOTE $USER)"

  rsync -avz --exclude-from=.gitignore --exclude='.git' -e 'ssh' . isucon@$REMOTE:/home/isucon/isubata/

  ssh isucon@$REMOTE "source ~/.profile && source ~/.bashrc && cd /home/isucon/isubata/webapp/perl && ~/local/perl/bin/carton install && sudo systemctl restart mysql && sudo systemctl restart nginx && sudo sudo systemctl restart isubata.perl.service && sudo sysctl -p"

  SLACK ":ok_hand:"
done

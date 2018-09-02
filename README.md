# isucon8
## オンライン予選概要
http://isucon.net/archives/52193980.html

* ConoHa を利用
* 出題者側でお題アプリが乗ったマシンを用意
* 各チームは用意されたマシンに ssh でログイン
* 各チームは出題者側で用意したベンチマーク用 Web ページからベンチマークを実行
* 予選問題に使われる OS は CentOS を予定

## 全員の公開鍵とSSH設定
rootユーザーでログインできるようにする
```
ssh -l root <IP>
vim .ssh/authorized_keys
# SSH公開鍵をコピペ
# セッション維持したままみんなでSSH出来るか確認
ssh -l root <IP>
```

isuconユーザーでログイン出来るようにする

```
ssh -l root <IP>
mkdir /home/isucon/.ssh
vim /home/isucon/.ssh/authorized_keys
chmod 700 /home/isucon/.ssh
chmod 600 /home/isucon/.ssh/authorized_keys
chown -R isucon:isucon /home/isucon/.ssh/
# 別ターミナルで ssh isucon@<IP>できて、sudo lsできたら完了
```

SSH公開鍵コピペ用
```
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7C2s+kOm3eiUzIFIFuSD/SslYoE0sIUYx6tyiObc/orZvNBJGXdLWNxB7XVNuPl950aMw1qRi5uiylz25yS3YJLswMZJx85PqF0TqCcbgKFBs/qZBLM1X8VpifFfRP6V1OI9agdeMLA9fYKEp2YxWYWenQlm20jXNgoPtG0aPRfabxpZW3YDeSM9UuijVSGHqc7RNr9MtbvwHuvxMffBEOfLEli37LiqOdjpDXLQb4vAVKnlQsVBP6/nm8Sg5waQvxSAS75+XZKmaOaqGp3X/D+Kuqwpu0Y9eGwF/3ON+Us0o0avP8eJrOEkdZ1GNioeL+MVkkgkyEm3cM1BTSQID shibayu36@YukiShibasaki-no-MacBook-Pro.local
```

## 初期状態のdump
まず予選のrepositoryをforkして、自分のrepositoryに。コミット権にメンバーを追加。

```
cd /home/isucon/isubata/
vim .git/config # 自分のoriginに変更
git pull
```

ミドルウェア設定のdump
```
scp -r root@<IP>:/etc/nginx .
scp -r root@<IP>:/etc/mysql .
scp -r root@<IP>:/etc/systemd .
# 他使っているミドルウェアあれば
```

## systemd設定確認と再起動
```
tree /etc/systemd
cat /etc/systemd/system/isubata.golang.service
```

```
$ sudo systemctl stop    isubata.python.service
$ sudo systemctl disable isubata.python.service
$ sudo systemctl start  isubata.golang.service
$ sudo systemctl enable isubata.golang.service
```

## サーバ状況確認
どういうミドルウェアが使われているか。プロセスツリー確認とLISTENの状況。
```
ps auxwf
netstat -tnlp
```

CPU負荷確認
```
top -c
# 1とタイプでCPUコアごとの利用率

# または
apt install htop
htop
```

全体のリソース状況
```
apt install dstat
dstat -t -a
# CPUが
```

I/O状況
```
apt install sysstat
iostat -dx 1
```

ファイルシステム確認
```
df -Th
```

## MySQLのテーブルサイズ
```
mysql> use database;
mysql> SELECT table_name, engine, table_rows, avg_row_length, floor((data_length+index_length)/1024/1024) as allMB, floor((data_length)/1024/1024) as dMB, floor((index_length)/1024/1024) as iMB FROM information_schema.tables WHERE table_schema=database() ORDER BY (data_length+index_length) DESC;
```

## デプロイできるようにする
deploy.sh例
```
#!/bin/bash
set -ex
IPADDR=$1
BRANCH=`git symbolic-ref --short HEAD`
USERNAME=$USER

echo $BRANCH

ssh isucon@$IPADDR "source ~/.profile && source ~/.bashrc && cd /home/isucon/isubata && git pull && cd webapp/go && make && sudo systemctl restart mysql && sudo systemctl restart nginx && sudo sudo systemctl restart isubata.golang.service && sudo sysctl -p"

# perlならこういう感じ？
# ssh isucon@$IPADDR "source ~/.profile && source ~/.bashrc && cd /home/isucon/isubata && git pull && ~/.local/perl/bin/carton install && sudo systemctl restart mysql && sudo systemctl restart nginx && sudo sudo systemctl restart isubata.golang.service && sudo sysctl -p"
```

デプロイ
```
./deploy.sh <IP>
```

## nginxログ解析
先にnginx.confの初期状態はgit管理しておくと良さそう。

```
scp isucon@<IP>:/etc/nginx/nginx.conf .
git add nginx.conf
git commit
```

変更をサーバに置きたいときは
```
scp nginx.conf root@<IP>:/etc/nginx/nginx.conf
```

nginx.confに以下を追加し、ログ出力。
```
    log_format ltsv "time:$time_local"
                "\thost:$remote_addr"
                "\tforwardedfor:$http_x_forwarded_for"
                "\treq:$request"
                "\tstatus:$status"
                "\tmethod:$request_method"
                "\turi:$request_uri"
                "\tsize:$body_bytes_sent"
                "\treferer:$http_referer"
                "\tua:$http_user_agent"
                "\treqtime:$request_time"
                "\tcache:$upstream_http_x_cache"
                "\truntime:$upstream_http_x_runtime"
                "\tapptime:$upstream_response_time"
                "\tvhost:$host";
    access_log /var/log/nginx/access.log.tsv ltsv;
```

ログのクリア
```
sudo rm -f /var/log/nginx/access.log.tsv /var/log/nginx/error.log /var/log/nginx/access.log.tsv && sudo touch /var/log/nginx/access.log.tsv && sudo touch /var/log/nginx/error.log && sudo touch /var/log/nginx/access.log.tsv
```

ログ解析ツールのインストール
```
go get github.com/tkuchiki/alp
```

ログ解析実行
```
alp -r --sum -f /var/log/nginx/access.log.tsv
```

nginxのsyntax check
```
sudo nginx -t
```

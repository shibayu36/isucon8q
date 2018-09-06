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
deploy.sh例: https://github.com/shibayu36/isucon7-qualify/blob/master/deploy.sh

デプロイ
```
./deploy.sh <IP>
```

## ベンチマークを手元からできるように
- https://github.com/shibayu36/isucon7-qualify/blob/master/bench.sh
- https://github.com/shibayu36/isucon7-qualify/blob/master/bench-from-remote.sh

```
./bench-from-remote.sh <IP>
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
alp -r --sum -f /var/log/nginx/access.log.tsv --aggregates='/channel/.*,/profile/.*,/history/.*'
```

nginxのsyntax check
```
sudo nginx -t
```

## netdataでリソースモニタリング
```
bash <(curl -Ss https://my-netdata.io/kickstart.sh)
```

http://<IP>:19999/ でアクセス可能。

完全に止めるには
```
sudo systemctl stop netdata.service
sudo systemctl disable netdata.service
```

## systemlogを見る
```
sudo journalctl -f
```

## MySQLのクエリ解析
my.cnfに以下を追記

```
[mysqld]
slow_query_log = 1
slow_query_log_file = /var/log/mysql/mysql-slow.log
long_query_time = 0
```

pt-query-logで解析。https://www.percona.com/downloads/percona-toolkit/LATEST/
```
wget https://www.percona.com/downloads/percona-toolkit/3.0.11/binary/debian/stretch/x86_64/percona-toolkit_3.0.11-1.stretch_amd64.deb
sudo apt install libio-socket-ssl-perl libdbd-mysql-perl libdbi-perl libnet-ssleay-perl
sudo dpkg -i percona-toolkit_3.0.11-1.stretch_amd64.deb
sudo pt-query-digest --limit 10 /var/log/mysql/mysql-slow.log
```

CentOSでインストールするなら
```
wget https://www.percona.com/downloads/percona-toolkit/3.0.11/binary/redhat/7/x86_64/percona-toolkit-3.0.11-1.el7.x86_64.rpm
rpm -qpR percona-toolkit-3.0.11-1.el7.x86_64.rpm # 依存を見る
# 依存をyumでインストール
sudo rpm -ivh percona-toolkit-3.0.11-1.el7.x86_64.rpm
```


ログのパーミッション変だったら
```
sudo chmod 755 /var/log/mysql/
```

## pprofでgoのベンチマーク
```
sudo apt install graphviz
go get -u github.com/google/pprof
```

https://golang.org/pkg/net/http/pprof/ のようにimportとmain関数でのListenAndServe。

ベンチ実行中に、`go tool pprof http://localhost:6060/debug/pprof/profile?seconds=30`

その後 `top50 -cum` でどの関数が遅いか、`list main.`でコードのどこが遅いかがわかる。

## ベンチマークをリモートから実行するくん
https://github.com/shibayu36/isucon7-qualify/blob/master/bench-from-remote.sh

## nginxの設定参考
- https://kazeburo.hatenablog.com/entry/2014/10/14/170129
- http://blog.nomadscafe.jp/2013/09/benchmark-g-wan-and-nginx.html

## MySQLの設定変更参考
```
innodb_buffer_pool_size = 1GB
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
```

https://www.slideshare.net/kazeburo/mysql-casual7isucon p36

## 最後にやること
nginxのログ出ないように

```
access_log  off;
```

MySQLのスロークエリログ出ないように
```
slow_query_log = 0
```

netdataを落とす

```
sudo systemctl stop netdata.service
sudo systemctl disable netdata.service
```

pprof使わないように

```
# import _ "net/http/pprof"を消す
# 以下を消す
go func() {
		log.Println(http.ListenAndServe("localhost:6060", nil))
	}()
```

再起動してベンチマークチェック

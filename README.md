# isucon8
## オンライン予選概要
http://isucon.net/archives/52193980.html

* ConoHa を利用
* 出題者側でお題アプリが乗ったマシンを用意
* 各チームは用意されたマシンに ssh でログイン
* 各チームは出題者側で用意したベンチマーク用 Web ページからベンチマークを実行
* 予選問題に使われる OS は CentOS を予定

## 全員の公開鍵とSSH設定
```
ssh -l root <IP>
vim .ssh/authorized_keys
# SSH公開鍵をコピペ
```

```
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7C2s+kOm3eiUzIFIFuSD/SslYoE0sIUYx6tyiObc/orZvNBJGXdLWNxB7XVNuPl950aMw1qRi5uiylz25yS3YJLswMZJx85PqF0TqCcbgKFBs/qZBLM1X8VpifFfRP6V1OI9agdeMLA9fYKEp2YxWYWenQlm20jXNgoPtG0aPRfabxpZW3YDeSM9UuijVSGHqc7RNr9MtbvwHuvxMffBEOfLEli37LiqOdjpDXLQb4vAVKnlQsVBP6/nm8Sg5waQvxSAS75+XZKmaOaqGp3X/D+Kuqwpu0Y9eGwF/3ON+Us0o0avP8eJrOEkdZ1GNioeL+MVkkgkyEm3cM1BTSQID shibayu36@YukiShibasaki-no-MacBook-Pro.local
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


# isucon8
## オンライン予選概要
http://isucon.net/archives/52193980.html

* ConoHa を利用
* 出題者側でお題アプリが乗ったマシンを用意
* 各チームは用意されたマシンに ssh でログイン
* 各チームは出題者側で用意したベンチマーク用 Web ページからベンチマークを実行
* 予選問題に使われる OS は CentOS を予定

## ベンチ前
エラーログとかを退避してくれます
```
./sokkyou/prebench.sh
```

## デプロイ

sokkyou/sokkyou.shあたりのサーバリストを設定すると、デプロイ先変えられます

- アプリケーション: `./sokkyou/deploy.sh`
- DB: `./sokkyou/deploy_mysql.sh`
- nginx: `./sokkyou/deploy_nginx.sh`

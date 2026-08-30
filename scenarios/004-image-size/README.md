# 004-image-size

## 何を測るか

**同じ Spring Boot アプリを「作り方 3 通り × 土台 3 種 = 9 イメージ」で作り、サイズ・転送量・起動を比べる。**

| 記号 | 作り方 |
|---|---|
| w1 | 素の jar をそのまま入れる |
| w2 | レイヤ抽出（`java -Djarmode=tools -jar application.jar extract --layers`） |
| w3 | w2 + AOT キャッシュの訓練実行をビルド中に行う |

| 記号 | 土台 |
|---|---|
| b1 | `eclipse-temurin:25-jre` |
| b2 | `bellsoft/liberica-openjre-debian:25-cds`（Spring 公式の Dockerfile 例が使う土台）|
| b3 | `eclipse-temurin:25-jre-alpine` |

## なぜ測るか

「コンテナイメージは小さいほど良い」という通説を、**どの条件で効くのか**まで下ろすためです。

海外のコミュニティでは「文脈しだい」という結論が既に出ています。ただし、そこで語られるのは
言語に依存しない一般論で、**JVM アプリ固有の事情**——土台が大きいこと、レイヤの分け方が
公式に決まっていること、AOT キャッシュが層に載ること——は数で埋められていません。

## 測定設計（意図的な選択）

1. **主指標は転送バイト数であって時間ではない。**ローカルレジストリは帯域が実質無限で、
   実測でも **94 MB と 161 MB が 2.32 秒でほぼ同じ**になりました。時間だけを見ると
   「サイズは効かない」という結論が測り方の産物になります。バイト数なら読者が自分の帯域で割れます。
2. **「サイズ」を 3 通りに分けて出す。**`registry_bytes`（転送量）/ `inspect_bytes` /
   `expanded_bytes`（展開後）。🔴 **この環境（containerd image store）では `inspect_bytes` は
   転送量にほぼ一致し、展開後はその 2.8 倍**でした。1 つの数で語れません。
3. **2 回目を測るときは対照を作る。**1 層も持たない状態にしてから測ります。持ったまま測ると
   0 秒になり、それが速さなのか命中なのか判別できません。
4. **単一アーキで揃える。**AOT キャッシュはビルド機のアーキに依存するため、クロスビルドを
   混ぜると起動の比較が壊れます。
5. **効く条件も測れる形にする。**土台を 3 種振り、アプリだけ変えた再取得も測ります。
6. **消すのは本スクリプトが導入したイメージだけ。**実行前から手元にあった土台には触れません
   （`--allow-base-removal` を付けたときだけ、操作者の確認済みとして消します）。

## 実行

```bash
bash scenarios/004-image-size/run.sh                       # 既定（起動 3 回）
bash scenarios/004-image-size/run.sh --starts 1            # 短く
bash scenarios/004-image-size/run.sh --skip-pull           # pull 計測を飛ばす
bash scenarios/004-image-size/run.sh --allow-base-removal  # 対照を作るため土台も消す
```

- モード: **M2**（JDK 25 + Maven + Docker）
- ローカルレジストリは `registry:3` をポート 5001 で起動します（`registry:2` は 2025-02-15 が最終更新のため使いません）
- 出力: `results/004-image-size/run.log`（生ログ）と `summary.json`（実効値）

## 落とし穴（実測で踏んだもの）

| # | 症状 | 原因と対処 |
|:--:|---|---|
| 1 | コンテナが終わらず測定が止まる | `--spring.context.exit=onRefresh` を**プログラム引数**で渡しても終了しません。`JAVA_TOOL_OPTIONS=-Dspring.context.exit=onRefresh` で**システムプロパティ**として渡します |
| 2 | 層が 0 件・0 バイトに見える | `docker push` が押すのは OCI の **index**。tag を引くと index が返り層は入っていません。実行アーキの image manifest まで降ります（`manifest.py`）。index には provenance の添付も並ぶので除きます |
| 3 | 圧縮後と展開後がほぼ同じ値になる | containerd image store では `docker image inspect` の `.Size` が**圧縮側**を返します。展開後は `docker export | wc -c` で別に測ります |

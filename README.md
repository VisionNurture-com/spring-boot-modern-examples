# spring-boot-modern-examples

「測って決める Spring Boot 4」シリーズの伴走サンプルです。
**記事に載せる値は、すべてこのリポジトリの実測ログに紐づきます。**

## 何のためのリポジトリか

シリーズの各記事は「仮説 → 実機で測る → 条件ごとの決定表」の形を取ります。
その **「実機で測る」を誰でも再現できる形にしたもの**が本リポジトリです。

記事の数値を手で書き写す経路を残さないため、次の一本道だけを使います。

```
run.sh 実行
   ↓
results/<id>/run.log        生ログ（人が読む）
   ↓ 抽出
results/<id>/summary.json   実効値（機械が読む）
   ↓ 突合（tools/check-provenance.py）
scenarios/<id>/expected.md  ★ 記事に載せる値の正本
   ↓ 引用
記事
```

`expected.md` と `summary.json` が食い違えば **CI が落ちます**。

## 実行モード

| モード | 必要なもの | 測れるもの | CI |
|---|---|---|:--:|
| **M0** | Python 3 のみ（**Docker 不要 / ネットワーク不要**） | 構成の整合・provenance 突合 | ✅ |
| **M1** | JDK 25 + Maven（+ 対照に JDK 21） | 起動時間 / AOT キャッシュ / JFR / スループット | ✅ |
| **M2** | M1 + Docker | **コネクションプール** / イメージサイズ / pull 時間 / 計装コスト | ✅ |
| **M3** | GraalVM | Native Image のビルドと起動 | ✅ |

## 使い方

```bash
# M0: 構造と provenance を検査する（最初にこれ）
python3 tools/check-structure.py
python3 tools/check-provenance.py

# M1: GraalVM なしで回せるシナリオ
bash scenarios/002-cache-pitfalls/run.sh       # キャッシュが効かなくなる 2 経路
bash scenarios/002-steady-design/run.sh        # 定常計測の条件（同時実行・負荷・ウォームアップ）
bash scenarios/003-pinning-remaining/run.sh    # 仮想スレッドが手放せなくなる経路（閾値 2 段 × JDK 2 版）

# M2: Docker が要るシナリオ
bash scenarios/003-pool-sizing/run.sh          # コネクションプールのサイズを振る

# M3: シナリオを実行する
bash scenarios/002-startup-3ways/run.sh        # 起動（5 アーム）
bash scenarios/002-steady-throughput/run.sh    # 定常状態（3 方式 × 負荷 2 種）
```

## シナリオ一覧

| シナリオ | モード | 測るもの |
|---|:--:|---|
| `001-migration-3x-to-4x` | M1 | **3.5.16 → 4.1.1 の移行**で、直しては再ビルドする**波ごと**にビルドを止めた箇所（N1）と非推奨警告どまりの箇所（N2）が何件出るか（アーム 2 本: 素直に上げる / 公式の classic starters）|
| `002-startup-3ways` | M3 | 素の JVM / AOT キャッシュ / Native Image の**起動**（5 アーム。AOT キャッシュは**展開の有無**で 2 アームに分けている）|
| `002-steady-throughput` | M3 | 同 3 方式の**定常状態**のスループットと p99 |
| `002-cache-pitfalls` | M1 | AOT キャッシュが効かなくなる 2 経路（**jar の食い違い** / `clean` を挟まない汚染）の出力と時間 |
| `002-steady-design` | M1 | 定常計測の条件の妥当性（同時実行 / 計算量 / ウォームアップの 3 スイープ・素の JVM のみ）|
| `003-pinning-remaining` | M1 | 仮想スレッドがキャリアスレッドを手放せなくなる経路の**件数と理由**（**閾値 20 ms / 0 ms の 2 段** × **JDK 25 / 21** の対照）|
| `003-pool-sizing` | M2 | **コネクションプールのサイズ別**のスループット・待ち時間・pinning 件数（負荷 2 種: 待つ問い合わせ / CPU を使う問い合わせ）|

## ディレクトリ

| パス | 役割 |
|---|---|
| `app/` | 計測対象の Spring Boot アプリケーション |
| `scenarios/<id>/` | 何を測るか（README.md）/ 実行手順（run.sh）/ **記事に載せる値（expected.md）** |
| `results/<id>/` | 実測ログ（`run.log`）と実効値（`summary.json`） |
| `tools/` | M0 の検査スクリプト |

## 前提

| 項目 | 値 |
|---|---|
| Spring Boot | 4.1.1 |
| Java | 25 LTS |
| Maven | 3.9 以上 |
| Python | 3.9 以上（検査スクリプト用） |

## 値を読むときの注意

各 `expected.md` には **「記事が主張してよい範囲 / よくない範囲」** の欄があります。
測っていないことを測ったように書かないための欄です。値だけを抜き出さず、この欄も併せて読んでください。

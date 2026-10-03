# expected: 004-image-size

**記事に載せる値の正本です。**ここに無い数を記事へ書きません。
値は `results/004-image-size/summary.json` と機械的に突き合わせます（`tools/check-provenance.py`）。
本文の表は `summary.json` から生成しています（手で書き写していません）。

- 測定日: 2026-10-03（Darwin 27.0.0 / arm64 / Docker 29.8.1 / Apache Maven 3.9.16 (2bdd9fddda4b155ebf8000e807eb73fd829a51d5)）
- 🔴 **2026-10-03 に測り直しました。**前回（2026-08-29〜30・Docker 29.7.2）からの変化は「前回からの変化」の節にまとめています。

## 何を測ったか

同じ Spring Boot アプリ（jar 21,983,846 bytes）を **作り方 3 通り × 土台 3 種 = 9 イメージ**で作り、
サイズ・層の数・pull の転送バイト数・起動時間を測りました。

| 記号 | 作り方 |
|---|---|
| w1 | 素の jar をそのまま入れる |
| w2 | レイヤ抽出（`java -Djarmode=tools -jar application.jar extract --layers`・公式の手順）|
| w3 | w2 + AOT キャッシュの訓練実行をビルド中に行う（公式の手順）|

| 記号 | 土台 | digest（測定時）|
|---|---|---|
| b1 | `eclipse-temurin:25-jre` | `sha256:fcd7fd7b387f94bb2ac461478a7436ad8e349924c374ea8313919624dceae636` |
| b2 | `bellsoft/liberica-openjre-debian:25-cds` | `sha256:20c7cbd6e25c9b9687682b11674769843f845b6435b5ddc7d11440d1b71ea8ed` |
| b3 | `eclipse-temurin:25-jre-alpine` | `sha256:3c0a9084927a221ccd1d007fcaf614465672c0af37aaa834c5184483afe56d61` |

🔴 **土台はタグで引くと中身が変わります。**b1 は前回から中身が `25.0.4.1+1` に進み、転送量が約 3.5 MB 増えました（下記）。比べるときは土台をダイジェストで固定してください。

## 🔴 「サイズ」は 1 つの数ではありません

同じイメージ（w1-b1）に **3 つの数**が出ます。

| 数の種類 | 値 | 何を指すか |
|---|---:|---|
| `registry_bytes` | 138,072,109 | レジストリの層（gzip 済み）+ config の合計 = **pull で転送されるバイト数** |
| `inspect_bytes` | 544,626,498 | `docker image inspect` の `.Size` |
| `expanded_bytes` | 383,174,144 | `docker export` した rootfs の tar のバイト数 = **実際に展開される中身** |

🔴 **展開後は転送量の 2.78 倍**です。
🔴 **`inspect_bytes` は転送量の 3.94 倍で、展開後よりも大きい**値です。
Docker 29.8.0 で containerd image store の `.Size` が「unpacked snapshot usage」を含むように直されたためです
（[moby/moby#53426](https://github.com/moby/moby/pull/53426)・リリースノート 29.8.0「Fix `docker image inspect` reporting a smaller image size than `docker image ls`」）。
前回（Docker 29.7.2）は `inspect_bytes` が転送量にほぼ一致していました（下記）。**`.Size` の意味は Docker の版でも変わります。**
⚠️ 旧来の graph driver（overlay2）での挙動は本測定では**測っていません**。

## 9 イメージの実測

| 作り方 | 土台 | 転送量 | 展開後 | 層 | 起動（中央値）|
|---|---|---:|---:|---:|---:|
| w1 | b1 | 138,072,109 | 383,174,144 | 8 | 1.029 s |
| w1 | b2 | 147,043,569 | 405,886,464 | 5 | 1.030 s |
| w1 | b3 | 94,574,257 | 247,717,888 | 7 | 1.087 s |
| w2 | b1 | 137,893,152 | 382,998,528 | 11 | 0.918 s |
| w2 | b2 | 146,864,607 | 405,710,848 | 8 | 0.929 s |
| w2 | b3 | 94,395,294 | 247,542,272 | 10 | 0.982 s |
| w3 | b1 | 151,993,329 | 440,248,320 | 12 | 0.553 s |
| w3 | b2 | 160,965,689 | 462,895,616 | 9 | 0.552 s |
| w3 | b3 | 108,467,804 | 304,660,992 | 11 | 0.559 s |

**最小は `w2_b3` の 94,395,294 bytes、最大は `w3_b2` の 160,965,689 bytes**で、
**その比は 1.71 倍**です。

## 土台だけで決まる差

アプリの層が同じ w1 どうしで比べます（前回は `inspect_bytes` を土台の転送量として使いましたが、29.8.0 以降はその読み方が成り立ちません）。

| 土台 | w1 の転送量 | 土台の展開後 |
|---|---:|---:|
| b3 `eclipse-temurin:25-jre-alpine` | 94,574,257 | 225,732,608 |
| b1 `eclipse-temurin:25-jre` | 138,072,109 | 361,188,864 |
| b2 `bellsoft/liberica-openjre-debian:25-cds` | 147,043,569 | 383,901,184 |

b1 → b3 の差は **43,497,852 bytes**で、**アプリの層 19,823,037 bytes の 2.19 倍**です。

## 🔴 レイヤ抽出が効くのは 2 回目です

土台を b1 に固定し、**アプリの層だけを変えた v2** を押し直して、v1 を持っている人が取り直すバイト数を測りました。

| 作り方 | 取り直すバイト数 | v2 の全体 | 全体 / 差分 |
|---|---:|---:|---:|
| w1 素の jar | 19,823,037 | 138,062,326 | 7.0 倍 |
| w2 レイヤ抽出 | 2,932 | 137,882,907 | 47,026.9 倍 |
| w3 抽出 + AOT | 14,074,155 | 151,954,130 | 10.8 倍 |

- **初回は w1 と w2 でほとんど変わりません**（138,072,109 → 137,893,152 bytes・-0.13%）。
- **2 回目で 6,761 分の 1** になります（19,823,037 → 2,932 bytes）。
- 🔴 **AOT キャッシュを載せると、この利得の大半が消えます**（2,932 → 14,074,155 bytes・**4,800 倍**）。キャッシュはアプリと一緒に作り直されるためです。

## 🔴 AOT キャッシュは「大きくして速くする」

土台 b1 で比べます。

| | 転送量 | 起動（中央値）| 取り直すバイト数 |
|---|---:|---:|---:|
| w2 抽出のみ | 137,893,152 | 0.918 s | 2,932 |
| w3 抽出 + AOT | 151,993,329 | **0.553 s** | 14,074,155 |
| 差 | **+10.2%** | **-39.8%** | **×4,800** |

## 🔴 土台による起動の差は、AOT キャッシュを載せるとほぼ消えます

| 作り方 | b1 Temurin | b2 Liberica-cds | b3 Alpine | 最速と最遅の差 |
|---|---:|---:|---:|---:|
| w1 | 1.029 s | 1.030 s | 1.087 s | 58 ms |
| w2 | 0.918 s | 0.929 s | 0.982 s | 64 ms |
| w3 | 0.553 s | 0.552 s | 0.559 s | 7 ms |

- **w1 / w2 では、いちばん小さい土台（Alpine）がいちばん遅く起動します。**
- 🔴 **9 通り全体の最小（w2-b3）が最も遅いわけではありません。**成り立つのは「同じ作り方の中では」までです。
- ⚠️ **w3 の土台どうしの差は数 ms で、測り直すたびに順位が入れ替わります**（起動は 3 回の中央値で、揺れる量です）。w3 について言えるのは「土台による差がほぼ消える」までで、どの土台が速いとは言いません。

## ⚠️ pull の秒数は根拠に使いません

ローカルレジストリから何も持っていない状態で取り直した秒数です。

| 土台（w2）| 転送量 | 所要 |
|---|---:|---:|
| b3 | 94,395,294 | 1.339 s |
| b1 | 137,893,152 | 1.331 s |
| b2 | 146,864,607 | 1.321 s |

🔴 **転送量が 1.56 倍違っても、秒数はほぼ同じ**です。
`localhost` は帯域が実質無限で、サイズ差が時間差に化けません。**時間で測ると「サイズは効かない」という結論が測り方の産物になります。**
だから本シナリオの主指標は**転送バイト数**です。読者は自分の帯域で割り算できます。

## 前回からの変化（2026-08-29〜30 → 2026-10-03）

| 項目 | 前回 | 今回 | 由来 |
|---|---:|---:|---|
| w1-b1 の転送量 | 134,556,430 | 138,072,109 | 土台 b1 のタグが新しい中身（`25.0.4.1+1`）を指すようになった |
| w1-b1 の `inspect_bytes` | 134,559,099 | 544,626,498 | Docker 29.7.2 → 29.8.1（29.8.0 の moby/moby#53426）|
| 土台の差（b1 → b3）| 39,998,145 | 43,497,852 | b1 の中身の更新 |
| 取り直すバイト数（w2）| 2,933 | 2,932 | 構造で決まる値。ほぼ不変 |
| w3 の土台による起動の差 | 57 ms（b2 最速）| 7 ms | 揺れる量。前回の「最大の土台が最速」は測り直しで再現しない |

## 測っていないもの

| 項目 | 理由 |
|---|---|
| 実ネットワーク越しの pull 時間 | ローカル完結の方針のため。転送バイト数から読者が換算する |
| 脆弱性・攻撃面 | 測定手段を持たない |
| Native Image のイメージ | 005 の主題 |
| Buildpacks のイメージ | 既定ビルダーが `:latest` で再現性が落ちる |
| 旧来の graph driver（overlay2）での `.Size` | 本測定は containerd image store のみ |
| ビルド時間 | `build_s_cached` はキャッシュが効いた値で測定対象ではない（005 の主題）|

## 実効値（`summary.json` と機械照合）

```json
{
  "jar_bytes": 21983846,
  "jar_v2_bytes": 21981995,
  "starts": 3,
  "base_b1_inspect_bytes": 502799229,
  "base_b1_expanded_bytes": 361188864,
  "base_b2_inspect_bytes": 527745056,
  "base_b2_expanded_bytes": 383901184,
  "base_b3_inspect_bytes": 303436115,
  "base_b3_expanded_bytes": 225732608,
  "w1_b1_registry_bytes": 138072109,
  "w1_b1_inspect_bytes": 544626498,
  "w1_b1_expanded_bytes": 383174144,
  "w1_b1_layers": 8,
  "w1_b1_build_s_cached": 0.4,
  "w1_b1_status": "OK",
  "w1_b2_registry_bytes": 147043569,
  "w1_b2_inspect_bytes": 569571794,
  "w1_b2_expanded_bytes": 405886464,
  "w1_b2_layers": 5,
  "w1_b2_build_s_cached": 0.3,
  "w1_b2_status": "OK",
  "w1_b3_registry_bytes": 94574257,
  "w1_b3_inspect_bytes": 345263369,
  "w1_b3_expanded_bytes": 247717888,
  "w1_b3_layers": 7,
  "w1_b3_build_s_cached": 0.3,
  "w1_b3_status": "OK",
  "w2_b1_registry_bytes": 137893152,
  "w2_b1_inspect_bytes": 544353897,
  "w2_b1_expanded_bytes": 382998528,
  "w2_b1_layers": 11,
  "w2_b1_build_s_cached": 0.2,
  "w2_b1_status": "OK",
  "w2_b2_registry_bytes": 146864607,
  "w2_b2_inspect_bytes": 569299187,
  "w2_b2_expanded_bytes": 405710848,
  "w2_b2_layers": 8,
  "w2_b2_build_s_cached": 0.2,
  "w2_b2_status": "OK",
  "w2_b3_registry_bytes": 94395294,
  "w2_b3_inspect_bytes": 344990761,
  "w2_b3_expanded_bytes": 247542272,
  "w2_b3_layers": 10,
  "w2_b3_build_s_cached": 0.2,
  "w2_b3_status": "OK",
  "w3_b1_registry_bytes": 151993329,
  "w3_b1_inspect_bytes": 615740923,
  "w3_b1_expanded_bytes": 440248320,
  "w3_b1_layers": 12,
  "w3_b1_build_s_cached": 0.2,
  "w3_b1_status": "OK",
  "w3_b2_registry_bytes": 160965689,
  "w3_b2_inspect_bytes": 640621582,
  "w3_b2_expanded_bytes": 462895616,
  "w3_b2_layers": 9,
  "w3_b2_build_s_cached": 0.4,
  "w3_b2_status": "OK",
  "w3_b3_registry_bytes": 108467804,
  "w3_b3_inspect_bytes": 416219048,
  "w3_b3_expanded_bytes": 304660992,
  "w3_b3_layers": 11,
  "w3_b3_build_s_cached": 0.4,
  "w3_b3_status": "OK",
  "w1_b1_startup_s": 1.029,
  "w1_b2_startup_s": 1.03,
  "w1_b3_startup_s": 1.087,
  "w2_b1_startup_s": 0.918,
  "w2_b2_startup_s": 0.929,
  "w2_b3_startup_s": 0.982,
  "w3_b1_startup_s": 0.553,
  "w3_b2_startup_s": 0.552,
  "w3_b3_startup_s": 0.559,
  "w1_b1_repull_delta_bytes": 19823037,
  "w1_b1_v2_total_bytes": 138062326,
  "w2_b1_repull_delta_bytes": 2932,
  "w2_b1_v2_total_bytes": 137882907,
  "w3_b1_repull_delta_bytes": 14074155,
  "w3_b1_v2_total_bytes": 151954130,
  "pull_w2_b1_s": 1.331,
  "pull_w2_b1_status": "ok",
  "pull_w2_b2_s": 1.321,
  "pull_w2_b2_status": "ok",
  "pull_w2_b3_s": 1.339,
  "pull_w2_b3_status": "ok",
  "smallest_image": "w2_b3",
  "smallest_registry_bytes": 94395294,
  "largest_image": "w3_b2",
  "largest_registry_bytes": 160965689,
  "largest_over_smallest_ratio": 1.71
}
```

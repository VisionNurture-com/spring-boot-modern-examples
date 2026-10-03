# expected: 004-image-size

**記事に載せる値の正本です。**ここに無い数を記事へ書きません。
値は `results/004-image-size/summary.json` と機械的に突き合わせます（`tools/check-provenance.py`）。
本文の表は `summary.json` から生成しています（手で書き写していません）。

- 測定日: 2026-10-04（Darwin 27.0.0 / arm64 / Docker 29.8.1 / Apache Maven 3.9.16 (2bdd9fddda4b155ebf8000e807eb73fd829a51d5)）
- 🔴 **2026-10-04 に測り直しました。**ビルドを専用の buildx ビルダーへ移し、「何も持っていない状態からの pull」を層の数で確かめる形にしたためです。前回（2026-10-03）からの変化は「前回からの変化」の節にまとめています。

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

🔴 **土台はタグで引くと中身が変わります。**比べるときは土台をダイジェストで固定してください。

## 🔴 「サイズ」は 1 つの数ではありません

同じイメージ（w1-b1）に **3 つの数**が出ます。

| 数の種類 | 値 | 何を指すか |
|---|---:|---|
| `registry_bytes` | 138,072,127 | レジストリの層（gzip 済み）+ config の合計 = **pull で転送されるバイト数** |
| `inspect_bytes` | 544,626,516 | `docker image inspect` の `.Size` |
| `expanded_bytes` | 383,174,144 | `docker export` した rootfs の tar のバイト数 = **実際に展開される中身** |

🔴 **展開後は転送量の 2.78 倍**です。
🔴 **`inspect_bytes` は転送量の 3.94 倍で、展開後よりも大きい**値です。
Docker 29.8.0 で containerd image store の `.Size` が「unpacked snapshot usage」を含むように直されたためです
（[moby/moby#53426](https://github.com/moby/moby/pull/53426)・リリースノート 29.8.0「Fix `docker image inspect` reporting a smaller image size than `docker image ls`」）。
2026-08-29（Docker 29.7.2）は `inspect_bytes` が転送量にほぼ一致していました。**`.Size` の意味は Docker の版でも変わります。**
⚠️ Docker 29.0.0 から、新しく入れた Docker は Linux でも containerd image store が既定です（リリースノート 29.0.0）。旧来の graph driver（overlay2）での挙動は本測定では**測っていません**。

## 9 イメージの実測

| 作り方 | 土台 | 転送量 | 展開後 | 層 | 起動（中央値）|
|---|---|---:|---:|---:|---:|
| w1 | b1 | 138,072,127 | 383,174,144 | 8 | 1.045 s |
| w1 | b2 | 147,043,587 | 405,886,464 | 5 | 1.043 s |
| w1 | b3 | 94,574,259 | 247,717,888 | 7 | 1.149 s |
| w2 | b1 | 137,893,149 | 382,998,528 | 11 | 0.952 s |
| w2 | b2 | 146,864,611 | 405,710,848 | 8 | 0.938 s |
| w2 | b3 | 94,395,294 | 247,542,272 | 10 | 1.022 s |
| w3 | b1 | 151,986,501 | 440,248,320 | 12 | 0.572 s |
| w3 | b2 | 160,969,837 | 462,961,152 | 9 | 0.568 s |
| w3 | b3 | 108,467,665 | 304,726,528 | 11 | 0.585 s |

**最小は `w2_b3` の 94,395,294 bytes、最大は `w3_b2` の 160,969,837 bytes**で、
**その比は 1.71 倍**です。

## 土台だけで決まる差

アプリの層が同じ w1 どうしで比べます。

| 土台 | w1 の転送量 | 土台の展開後 |
|---|---:|---:|
| b3 `eclipse-temurin:25-jre-alpine` | 94,574,259 | 225,732,608 |
| b1 `eclipse-temurin:25-jre` | 138,072,127 | 361,188,864 |
| b2 `bellsoft/liberica-openjre-debian:25-cds` | 147,043,587 | 383,901,184 |

b1 → b3 の差は **43,497,868 bytes**で、**アプリの層 19,823,040 bytes の 2.19 倍**です。

## 🔴 レイヤ抽出が効くのは 2 回目です

土台を b1 に固定し、**アプリの層だけを変えた v2** を押し直して、v1 を持っている人が取り直すバイト数を測りました。

| 作り方 | 取り直すバイト数 | v2 の全体 | 全体 / 差分 |
|---|---:|---:|---:|
| w1 素の jar | 19,823,040 | 138,062,329 | 7.0 倍 |
| w2 レイヤ抽出 | 2,934 | 137,882,905 | 46,994.9 倍 |
| w3 抽出 + AOT | 14,052,317 | 151,932,288 | 10.8 倍 |

- **初回は w1 と w2 でほとんど変わりません**（138,072,127 → 137,893,149 bytes・-0.13%）。
- **2 回目で 6,756 分の 1** になります（19,823,040 → 2,934 bytes）。
- 🔴 **AOT キャッシュを載せると、この利得の大半が消えます**（2,934 → 14,052,317 bytes・**4,789 倍**）。キャッシュはアプリと一緒に作り直されるためです。

## 🔴 AOT キャッシュは「大きくして速くする」

土台 b1 で比べます。

| | 転送量 | 起動（中央値）| 取り直すバイト数 |
|---|---:|---:|---:|
| w2 抽出のみ | 137,893,149 | 0.952 s | 2,934 |
| w3 抽出 + AOT | 151,986,501 | **0.572 s** | 14,052,317 |
| 差 | **+10.2%** | **-39.9%** | **×4,789** |

## 🔴 土台による起動の差は、AOT キャッシュを載せると小さくなります

| 作り方 | b1 Temurin | b2 Liberica-cds | b3 Alpine | 最速と最遅の差 |
|---|---:|---:|---:|---:|
| w1 | 1.045 s | 1.043 s | 1.149 s | 106 ms |
| w2 | 0.952 s | 0.938 s | 1.022 s | 84 ms |
| w3 | 0.572 s | 0.568 s | 0.585 s | 17 ms |

- **同じ作り方の中では、いちばん小さい土台（Alpine）がいちばん遅く起動します。**
- 🔴 **9 通り全体の最小（w2-b3）が最も遅いわけではありません。**成り立つのは「同じ作り方の中では」までです。
- ⚠️ **w3 の土台どうしの差は、測り直すたびに大きく揺れます**（2026-08-29 は 57 ms、2026-10-03 は 7 ms、今回は 17 ms。起動は 3 回の中央値です）。言えるのは「w1・w2 より小さくなる」までで、何 ms に縮むとは言いません。

## ⚠️ pull の秒数は、何も持っていない状態からの回だけを読みます

ローカルレジストリから取り直した秒数です。**流れた層の数が manifest の層の数と一致した回（`ok`）だけ**が、何も持っていない状態からの pull です。

| 土台（w2）| 転送量 | 所要 | 流れた層 / manifest の層（重複を除く）| status |
|---|---:|---:|---:|---|
| b1 | 137,893,149 | 0.888 s | 4 / 9 | `partial` |
| b2 | 146,864,611 | 2.346 s | 7 / 7 | `ok` |
| b3 | 94,395,294 | 0.845 s | 4 / 9 | `partial` |

🔴 **測定機では b1 と b3 が `partial` です。**イメージと土台を消しても、手元にある別のイメージが同じ層を持っていると、その層は流れません（測定機は他の作業のイメージを多く持っており、どのイメージが層を持っていたかは調べていません）。`partial` の秒数は、流れなかった層の分だけ短く出ます。
🔴 **2026-10-03 までの測定（3 つとも 1.32〜1.34 s）は、この確かめをしていませんでした。**ビルドのキャッシュが層を持ったままの取り直しで、秒数がそろって見えたのはそのためです。
本シナリオの主指標は引き続き**転送バイト数**です。秒数は経路の帯域と手元の展開の速さで変わるため、読者は転送量を自分の帯域で割って換算します。

## 前回からの変化（2026-10-03 → 2026-10-04）

| 項目 | 前回 | 今回 | 由来 |
|---|---:|---:|---|
| ビルド | 既定のビルダー | 専用の buildx ビルダー（`moby/buildkit:v0.33.0`）| 既定のビルダーのキャッシュが層を持ち続け、何も持っていない状態からの pull を作れなかった |
| w1-b1 の転送量 | 138,072,109 | 138,072,127 | config の作成時刻の差（数十バイト）|
| 取り直すバイト数（w2）| 2,932 | 2,934 | 構造で決まる値。ほぼ不変 |
| w3 の土台による起動の差 | 7 ms | 17 ms | 揺れる量 |
| pull の秒数（w2）| 1.321〜1.339 s（確かめなし）| 上表 | 層の数で「何も持っていない状態」を確かめるようにした |

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
  "w1_b1_registry_bytes": 138072127,
  "w1_b1_inspect_bytes": 544626516,
  "w1_b1_expanded_bytes": 383174144,
  "w1_b1_layers": 8,
  "w1_b1_build_s_cached": 8.6,
  "w1_b1_status": "OK",
  "w1_b2_registry_bytes": 147043587,
  "w1_b2_inspect_bytes": 569571812,
  "w1_b2_expanded_bytes": 405886464,
  "w1_b2_layers": 5,
  "w1_b2_build_s_cached": 7.3,
  "w1_b2_status": "OK",
  "w1_b3_registry_bytes": 94574259,
  "w1_b3_inspect_bytes": 345263371,
  "w1_b3_expanded_bytes": 247717888,
  "w1_b3_layers": 7,
  "w1_b3_build_s_cached": 4.5,
  "w1_b3_status": "OK",
  "w2_b1_registry_bytes": 137893149,
  "w2_b1_inspect_bytes": 544353894,
  "w2_b1_expanded_bytes": 382998528,
  "w2_b1_layers": 11,
  "w2_b1_build_s_cached": 2.6,
  "w2_b1_status": "OK",
  "w2_b2_registry_bytes": 146864611,
  "w2_b2_inspect_bytes": 569299191,
  "w2_b2_expanded_bytes": 405710848,
  "w2_b2_layers": 8,
  "w2_b2_build_s_cached": 2.6,
  "w2_b2_status": "OK",
  "w2_b3_registry_bytes": 94395294,
  "w2_b3_inspect_bytes": 344990761,
  "w2_b3_expanded_bytes": 247542272,
  "w2_b3_layers": 10,
  "w2_b3_build_s_cached": 2.2,
  "w2_b3_status": "OK",
  "w3_b1_registry_bytes": 151986501,
  "w3_b1_inspect_bytes": 615734095,
  "w3_b1_expanded_bytes": 440248320,
  "w3_b1_layers": 12,
  "w3_b1_build_s_cached": 5.4,
  "w3_b1_status": "OK",
  "w3_b2_registry_bytes": 160969837,
  "w3_b2_inspect_bytes": 640691266,
  "w3_b2_expanded_bytes": 462961152,
  "w3_b2_layers": 9,
  "w3_b2_build_s_cached": 5.5,
  "w3_b2_status": "OK",
  "w3_b3_registry_bytes": 108467665,
  "w3_b3_inspect_bytes": 416284445,
  "w3_b3_expanded_bytes": 304726528,
  "w3_b3_layers": 11,
  "w3_b3_build_s_cached": 5.3,
  "w3_b3_status": "OK",
  "w1_b1_startup_s": 1.045,
  "w1_b2_startup_s": 1.043,
  "w1_b3_startup_s": 1.149,
  "w2_b1_startup_s": 0.952,
  "w2_b2_startup_s": 0.938,
  "w2_b3_startup_s": 1.022,
  "w3_b1_startup_s": 0.572,
  "w3_b2_startup_s": 0.568,
  "w3_b3_startup_s": 0.585,
  "w1_b1_repull_delta_bytes": 19823040,
  "w1_b1_v2_total_bytes": 138062329,
  "w2_b1_repull_delta_bytes": 2934,
  "w2_b1_v2_total_bytes": 137882905,
  "w3_b1_repull_delta_bytes": 14052317,
  "w3_b1_v2_total_bytes": 151932288,
  "pull_w2_b1_s": 0.888,
  "pull_w2_b1_status": "partial",
  "pull_w2_b1_reused_layers": 0,
  "pull_w2_b1_pulled_layers": 4,
  "pull_w2_b1_unique_layers": 9,
  "pull_w2_b2_s": 2.346,
  "pull_w2_b2_status": "ok",
  "pull_w2_b2_reused_layers": 0,
  "pull_w2_b2_pulled_layers": 7,
  "pull_w2_b2_unique_layers": 7,
  "pull_w2_b3_s": 0.845,
  "pull_w2_b3_status": "partial",
  "pull_w2_b3_reused_layers": 0,
  "pull_w2_b3_pulled_layers": 4,
  "pull_w2_b3_unique_layers": 9,
  "smallest_image": "w2_b3",
  "smallest_registry_bytes": 94395294,
  "largest_image": "w3_b2",
  "largest_registry_bytes": 160969837,
  "largest_over_smallest_ratio": 1.71
}
```

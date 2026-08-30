# expected: 004-image-size

**記事に載せる値の正本です。**ここに無い数を記事へ書きません。
値は `results/004-image-size/summary.json` と機械的に突き合わせます（`tools/check-provenance.py`）。

## 何を測ったか

同じ Spring Boot アプリ（jar 21,983,846 bytes）を **作り方 3 通り × 土台 3 種 = 9 イメージ**で作り、
サイズ・層の数・pull の転送バイト数・起動時間を測りました。

| 記号 | 作り方 |
|---|---|
| w1 | 素の jar をそのまま入れる |
| w2 | レイヤ抽出（`java -Djarmode=tools -jar application.jar extract --layers`・公式の手順）|
| w3 | w2 + AOT キャッシュの訓練実行をビルド中に行う（公式の手順）|

| 記号 | 土台 | digest |
|---|---|---|
| b1 | `eclipse-temurin:25-jre` | `sha256:f9e65324a37f28209ce7dd0e5149a7aa954520ed936fb87813cf6ded2400a112` |
| b2 | `bellsoft/liberica-openjre-debian:25-cds` | `sha256:20c7cbd6e25c9b9687682b11674769843f845b6435b5ddc7d11440d1b71ea8ed` |
| b3 | `eclipse-temurin:25-jre-alpine` | `sha256:3137541deb3cac6626b5d9a4a2187bc0d6a34312f858bd2c67dd01e732e6b682` |

## 🔴 「サイズ」は 1 つの数ではありません

同じイメージ（w1-b1）に **3 つの数**が出ます。

| 数の種類 | 値 | 何を指すか |
|---|---:|---|
| `registry_bytes` | 134,556,430 | レジストリの層（gzip 済み）+ config の合計 = **pull で転送されるバイト数** |
| `inspect_bytes` | 134,559,099 | `docker image inspect` の `.Size` |
| `expanded_bytes` | 382,808,576 | `docker export` した rootfs の tar のバイト数 = **実際に展開される中身** |

🔴 **展開後は転送量の 2.84 倍**です。
🔴 **この環境では `inspect_bytes` が転送量にほぼ一致します**（差 2,669 bytes）。
Docker の image store が containerd（`io.containerd.snapshotter.v1` / overlayfs）のためで、
`docker image ls` の SIZE を「展開後の大きさ」と読むと **2.84 倍**ずれます。
⚠️ 旧来の graph driver（overlay2）での挙動は**測っていません**。

## 9 イメージの実測

| 作り方 | 土台 | 転送量 | 展開後 | 層 | 起動（中央値）|
|---|---|---:|---:|---:|---:|
| w1 | b1 | 134,556,430 | 382,808,576 | 8 | 1.100 s |
| w1 | b2 | 147,043,585 | 405,886,464 | 5 | 1.100 s |
| w1 | b3 | 94,561,682 | 247,699,456 | 7 | 1.201 s |
| w2 | b1 | 134,377,453 | 382,632,960 | 11 | 0.992 s |
| w2 | b2 | 146,864,608 | 405,710,848 | 8 | 0.987 s |
| w2 | b3 | 94,382,720 | 247,523,840 | 10 | 1.113 s |
| w3 | b1 | 148,469,490 | 439,882,752 | 12 | 0.604 s |
| w3 | b2 | 160,968,497 | 462,961,152 | 9 | 0.586 s |
| w3 | b3 | 108,477,138 | 304,773,632 | 11 | 0.643 s |

**最小は `w2_b3` の 94,382,720 bytes、最大は `w3_b2` の 160,968,497 bytes**で、
**その比は 1.71 倍**です。

## 土台だけで決まる差

| 土台 | 転送量（`inspect_bytes`）| 展開後 |
|---|---:|---:|
| b3 `eclipse-temurin:25-jre-alpine` | 74,742,439 | 225,714,176 |
| b1 `eclipse-temurin:25-jre` | 114,740,584 | 360,823,296 |
| b2 `bellsoft/liberica-openjre-debian:25-cds` | 127,222,562 | 383,901,184 |

土台の差は **39,998,145 bytes**（1.54 倍）で、
**アプリの層 19,823,039 bytes より大きい**です。

## 🔴 レイヤ抽出が効くのは 2 回目です

土台を b1 に固定し、**アプリの層だけを変えた v2** を押し直して、v1 を持っている人が取り直すバイト数を測りました。

| 作り方 | 取り直すバイト数 | v2 の全体 | 全体 / 差分 |
|---|---:|---:|---:|
| w1 素の jar | 19,823,039 | 134,546,658 | 6.8 倍 |
| w2 レイヤ抽出 | **2,933** | 134,367,234 | **45,812 倍** |
| w3 抽出 + AOT | 14,109,883 | 148,474,184 | 10.5 倍 |

- **初回は w1 と w2 でほとんど変わりません**（134,556,430 → 134,377,453 bytes・-0.13%）。
- **2 回目で 6,759 分の 1** になります（19,823,039 → 2,933 bytes）。
- 🔴 **AOT キャッシュを載せると、この利得の大半が消えます**（2,933 → 14,109,883 bytes・**4,811 倍**）。キャッシュはアプリと一緒に作り直されるためです。

## 🔴 AOT キャッシュは「大きくして速くする」

土台 b1 で比べます。

| | 転送量 | 起動（中央値）| 取り直すバイト数 |
|---|---:|---:|---:|
| w2 抽出のみ | 134,377,453 | 0.992 s | 2,933 |
| w3 抽出 + AOT | 148,469,490 | **0.604 s** | 14,109,883 |
| 差 | **+10.5%** | **−39.1%** | **×4,811** |

## 🔴 一番小さいイメージが一番速いわけではありません

| 土台 | 転送量（w3）| 起動（w3）|
|---|---:|---:|
| b3 Alpine（最小）| 108,477,138 | 0.643 s ← **最も遅い** |
| b1 Temurin | 148,469,490 | 0.604 s |
| b2 Liberica-cds（最大）| 160,968,497 | **0.586 s** ← 最も速い |

## ⚠️ pull の秒数は根拠に使いません

ローカルレジストリから何も持っていない状態で取り直した秒数です。

| 土台（w2）| 転送量 | 所要 |
|---|---:|---:|
| b3 | 94,382,720 | 2.32 s |
| b1 | 134,377,453 | 2.324 s |
| b2 | 146,864,608 | 2.325 s |

🔴 **転送量が 1.56 倍違っても、秒数はほぼ同じ**です。
`localhost` は帯域が実質無限で、サイズ差が時間差に化けません。**時間で測ると「サイズは効かない」という結論が測り方の産物になります。**
だから本シナリオの主指標は**転送バイト数**です。読者は自分の帯域で割り算できます。

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
  "base_b1_inspect_bytes": 114740584,
  "base_b1_expanded_bytes": 360823296,
  "base_b2_inspect_bytes": 127222562,
  "base_b2_expanded_bytes": 383901184,
  "base_b3_inspect_bytes": 74742439,
  "base_b3_expanded_bytes": 225714176,
  "w1_b1_registry_bytes": 134556430,
  "w1_b1_inspect_bytes": 134559099,
  "w1_b1_expanded_bytes": 382808576,
  "w1_b1_layers": 8,
  "w1_b1_build_s_cached": 0.4,
  "w1_b1_status": "OK",
  "w1_b2_registry_bytes": 147043585,
  "w1_b2_inspect_bytes": 147045690,
  "w1_b2_expanded_bytes": 405886464,
  "w1_b2_layers": 5,
  "w1_b2_build_s_cached": 0.2,
  "w1_b2_status": "OK",
  "w1_b3_registry_bytes": 94561682,
  "w1_b3_inspect_bytes": 94564162,
  "w1_b3_expanded_bytes": 247699456,
  "w1_b3_layers": 7,
  "w1_b3_build_s_cached": 0.2,
  "w1_b3_status": "OK",
  "w2_b1_registry_bytes": 134377453,
  "w2_b1_inspect_bytes": 134380686,
  "w2_b1_expanded_bytes": 382632960,
  "w2_b1_layers": 11,
  "w2_b1_build_s_cached": 0.3,
  "w2_b1_status": "OK",
  "w2_b2_registry_bytes": 146864608,
  "w2_b2_inspect_bytes": 146867276,
  "w2_b2_expanded_bytes": 405710848,
  "w2_b2_layers": 8,
  "w2_b2_build_s_cached": 0.2,
  "w2_b2_status": "OK",
  "w2_b3_registry_bytes": 94382720,
  "w2_b3_inspect_bytes": 94385763,
  "w2_b3_expanded_bytes": 247523840,
  "w2_b3_layers": 10,
  "w2_b3_build_s_cached": 0.3,
  "w2_b3_status": "OK",
  "w3_b1_registry_bytes": 148469490,
  "w3_b1_inspect_bytes": 148472916,
  "w3_b1_expanded_bytes": 439882752,
  "w3_b1_layers": 12,
  "w3_b1_build_s_cached": 0.3,
  "w3_b1_status": "OK",
  "w3_b2_registry_bytes": 160968497,
  "w3_b2_inspect_bytes": 160971358,
  "w3_b2_expanded_bytes": 462961152,
  "w3_b2_layers": 9,
  "w3_b2_build_s_cached": 0.2,
  "w3_b2_status": "OK",
  "w3_b3_registry_bytes": 108477138,
  "w3_b3_inspect_bytes": 108480374,
  "w3_b3_expanded_bytes": 304773632,
  "w3_b3_layers": 11,
  "w3_b3_build_s_cached": 0.3,
  "w3_b3_status": "OK",
  "w1_b1_startup_s": 1.1,
  "w1_b2_startup_s": 1.1,
  "w1_b3_startup_s": 1.201,
  "w2_b1_startup_s": 0.992,
  "w2_b2_startup_s": 0.987,
  "w2_b3_startup_s": 1.113,
  "w3_b1_startup_s": 0.604,
  "w3_b2_startup_s": 0.586,
  "w3_b3_startup_s": 0.643,
  "w1_b1_repull_delta_bytes": 19823039,
  "w1_b1_v2_total_bytes": 134546658,
  "w2_b1_repull_delta_bytes": 2933,
  "w2_b1_v2_total_bytes": 134367234,
  "w3_b1_repull_delta_bytes": 14109883,
  "w3_b1_v2_total_bytes": 148474184,
  "pull_w2_b1_s": 2.324,
  "pull_w2_b1_status": "ok",
  "pull_w2_b2_s": 2.325,
  "pull_w2_b2_status": "ok",
  "pull_w2_b3_s": 2.32,
  "pull_w2_b3_status": "ok",
  "smallest_image": "w2_b3",
  "smallest_registry_bytes": 94382720,
  "largest_image": "w3_b2",
  "largest_registry_bytes": 160968497,
  "largest_over_smallest_ratio": 1.71
}
```

# 006-otel-cost: 記事に載せる値の正本

`spring-boot-starter-opentelemetry` を入れたとき、サンプリング率ごとに何がどれだけ増えるかを測りました。
**記事に書く数値はこのファイルからしか引きません。**このファイルと `results/006-otel-cost/summary.json` が
食い違えば `tools/check-provenance.py` が落ちます。

## 測った条件

| 項目 | 値 |
|---|---|
| ラウンド | 3（中央値を採る）|
| ウォームアップ / 計測 | 8 秒 / 10 秒 |
| 同時実行 | 8 |
| 負荷（app）| `/work?n=2000`（アプリ内で反復計算する経路）|
| 負荷（app-db）| `/dbcpu?n=20000`（PostgreSQL 側に CPU を使わせる経路）|
| コレクタ | `otel/opentelemetry-collector:0.159.0`（受けて捨てる構成）|
| PostgreSQL | `postgres:18.6` |

⚠️ **負荷生成器とサーバが同一機体で CPU を共有します。**絶対値はその前提でしか読めません。
比較に使うのは対照（計装なし）との比であり、他の機体の絶対値と並べることはできません。

## 1. 依存を足すと jar は何バイト増えるか

計装あり / なしを**同じ pom** で作り分けているため、この差は starter のぶんだけです。

| 対象 | 計装なし | 計装あり | 差 |
|---|---:|---:|---:|
| `app-otelcost` | 21,984,451 | 29,779,989 | **+7,795,538（+35.5%）** |
| `app-db-otelcost` | 22,593,700 | 31,759,546 | +9,165,846 |

## 2. 率ごとに、実際に何本のスパンが届いたか（検算パス）

リクエスト 100 回あたりの受信スパン数です。`debug` エクスポータで実際に数えました。

| 腕 | 率 | 受信スパン / 100 リクエスト |
|---|---|---:|
| A0 計装なし | — | **0** |
| A1 | 0.0 | 0 |
| A2 | 0.01 | 0 |
| A3 **既定（未指定）** | 0.1 | **10** |
| A4 | 0.5 | 57 |
| A5 | 1.0 | 101 |
| B0 計装なし | — | **0** |
| B1 **既定** | 0.1 | 8 |
| B2 | 1.0 | 101 |

🔵 **A0 / B0 が 0 本であることが「計装なし」の裏づけです**（依存ごと外した jar を使っています）。
🔵 A5 / B2 の 101 本は、100 回の負荷に加えて起動確認の `/hello` が 1 本入った数です（内訳は `results/006-otel-cost/spans/` に保存）。
⚠️ **1 回きりの標本です。**率 0.1 の腕で 10 本、率 0.5 の腕で 57 本というように、
サンプリングは確率なので 100 回では期待値どおりになりません。**率が実際に効いていることの確認**であって、率そのものの測定ではありません。
🔴 **B1 / B2 で届いたのは HTTP のスパンだけで、JDBC の子スパンは 1 本もありません。**
`spring-boot-starter-opentelemetry` 単体では、データベースアクセスは計装されません。

## 3. app（軽い仕事・約 4 万 rps）

| 腕 | 率 | スループット | p50 | p95 | p99 | CPU/リクエスト | RSS 最大 |
|---|---|---:|---:|---:|---:|---:|---:|
| **A0 計装なし** | — | 40,054.2 rps | 0.19 ms | 0.24 ms | 0.37 ms | **109.37 μs** | 624,768 KB |
| A1 | 0.0 | 39,856.1 rps | 0.2 ms | 0.25 ms | 0.38 ms | 116.39 μs | 633,856 KB |
| A2 | 0.01 | 39,878.2 rps | 0.19 ms | 0.25 ms | 0.38 ms | 117.05 μs | 648,096 KB |
| **A3 既定** | 0.1 | 39,931.0 rps | 0.19 ms | 0.25 ms | 0.38 ms | 116.77 μs | 632,960 KB |
| A4 | 0.5 | 39,482.8 rps | 0.2 ms | 0.25 ms | 0.38 ms | 125.24 μs | 650,736 KB |
| A5 | 1.0 | 39,057.9 rps | 0.2 ms | 0.26 ms | 0.38 ms | **132.69 μs** | 646,144 KB |

**対照（A0）との比**

| 腕 | p99 | スループット | CPU/リクエスト | RSS |
|---|---:|---:|---:|---:|
| A1（率 0.0）| +2.7% | -0.5% | **+6.4%** | +1.5% |
| A2（0.01）| +2.7% | -0.4% | +7.0% | +3.7% |
| **A3（既定 0.1）**| +2.7% | -0.3% | **+6.8%** | +1.3% |
| A4（0.5）| +2.7% | -1.4% | +14.5% | +4.2% |
| **A5（1.0）**| +2.7% | **-2.5%** | **+21.3%** | +3.4% |

🔴 **p99 の「+2.7%」を差として読まないでください。**対照が 0.37 ms、計装ありが全腕 0.38 ms で、
**差は 0.01 ms** です。`LoadGen` の出力は小数第 2 位までで、この負荷では **p99 の差が分解能に張り付いています**。
**この経路で読めるのは CPU とスループットだけ**です。

## 4. app-db（重い仕事・約 770 rps）

| 腕 | 率 | スループット | p99 | CPU/リクエスト | RSS 最大 |
|---|---|---:|---:|---:|---:|
| **B0 計装なし** | — | 771.6 rps | 12.34 ms | 929.24 μs | 282,480 KB |
| **B1 既定** | 0.1 | 768.0 rps | 12.65 ms | 1180.37 μs | 339,456 KB |
| B2 | 1.0 | 770.0 rps | 13.36 ms | 1271.43 μs | 362,176 KB |

**対照（B0）との比**

| 腕 | p99 | スループット | CPU/リクエスト | RSS |
|---|---:|---:|---:|---:|
| B1（既定）| +2.5% | -0.5% | **+27.0%** | +20.2% |
| B2（1.0）| +8.3% | -0.2% | **+36.8%** | +28.2% |

⚠️ **B 系のスループットは差が測定のばらつきに埋もれています**（-0.5% と -0.2%）。
この経路は PostgreSQL 側が律速で、アプリ側の計装コストが処理量に現れません。

⚠️ **B 系の「CPU/リクエスト」を A 系と絶対値で比べないでください。**app-db は 10 秒間に約 7,700 件しか
さばかないため、JVM の背景処理（GC・JIT）が 1 リクエストあたりへ重く配分されます。A 系は約 40 万件です。
**比べてよいのは、それぞれの対照との比だけ**です。

## 5. 全量にすると、送信先が生きていてもキューが溢れることがある

3 ラウンド回して、キューで捨てられたスパンを数えました。

| 率 | 計測リクエスト（中央値）| 溢れたラウンド | 各ラウンドの本数 | 最大 |
|---|---:|---:|---|---:|
| **1.0** | 386,462 | **2 / 3** | `7554,0,5001` | **7,554** |
| 0.5 | 394,868 | 0 / 3 | `0,0,0` | 0 |
| 0.1 | 397,055 | 0 / 3 | `0,0,0` | 0 |
| 0.01 | 399,358 | 0 / 3 | `0,0,0` | 0 |

🔴 **率 1.0 は「必ず溢れる」でも「溢れない」でもありません。**3 ラウンド中 2 ラウンドで溢れました。
`management.opentelemetry.tracing.export.max-queue-size` の既定は **2048** で、この負荷はちょうどその境目にあります。
**単発の測定で「溢れる / 溢れない」を断定できません。**
🔵 率 0.5 以下では 3 ラウンドとも 0 本でした。

## 6. 送信先を止めるとどうなるか（C1・率 1.0）

| | スループット | p99 | エラー |
|---|---:|---:|---:|
| 停止前 | 38,794.8 rps | 0.4 ms | 0 |
| 停止後 | 39,279.6 rps | 0.4 ms | **0** |

停止後のアプリのログには **`BatchSpanProcessor dropped ... span(s) since the last export because the queue is full (maxQueueSize=2048)`**
が出て、累計 **631,144 本**が捨てられました。エクスポート失敗のログは **2 行**です。
**リクエストのエラーは 0 件**で、アプリは止まりませんでした。

## 7. n を変えると比はどう動くか（2026-08-30 追加）

VALUE-01 §問い 5（設計にバイアスはないか）で計画しながら測る回で実施していなかった検算です。
**同じ `/work` 経路のまま `n` だけを 2000 → 20000 の 1 段変え、腕を A0 / A3 / A5 の 3 本に絞って 3 ラウンド**回しました。

| | 対照の CPU/リクエスト | 既定（0.1）| 全量（1.0）|
|---|---:|---:|---:|
| `n=2000`（本文の値）| 109.37 μs | **+6.8%** | **+21.3%** |
| `n=20000` | 177.39 μs | **+5.6%** | **+10.5%** |

🔴 **`n` は結論を動かします。**1 リクエストあたりの仕事が重くなると、**同じ経路のままでも計装の比は小さくなります**（全量で 21.3% → 10.5%）。
計装のコストは 1 リクエストにつきほぼ一定量が乗るため、分母が大きくなれば比は薄まります。

⚠️ **したがって「+21.3%」は `n=2000` という条件つきの値です。**自分のアプリに当てるときは、比そのものではなく**測り方**を持ち帰ってください。

🔵 **素のアプリが `n` でどう動くかは測り直していません。**002 が既に測っており（計算量 10 倍でスループット −5.4%）、本検算が見たのは**計装ありと計装なしの比の `n` 依存**だけです。

⚠️ **`app-db`（重い仕事）の比が大きいこと（既定 +27.0%）と、この結果は矛盾しません。**
`app-db` は経路そのものが違い（PostgreSQL への往復が入り、10 秒で約 7,700 件しかさばかない）、
**1 リクエストあたりへ配分される JVM の背景処理の量が A 系と別**です。**「重いほど比が大きい」という一般則は、この 2 つからは引けません。**

## 生ログの所在

| 種類 | 場所 |
|---|---|
| 実行ログ | `results/006-otel-cost/run.log` |
| 1 ラウンドごとの生値 | `results/006-otel-cost/measurements/<腕>_<ラウンド>.json` |
| 受信スパンの内訳 | `results/006-otel-cost/spans/<腕>.txt` |
| 実効値（機械可読）| `results/006-otel-cost/summary.json` |

---

```json
{
  "A0_plain_cpu_sec": 43.81,
  "A0_plain_cpu_us_per_req": 109.37,
  "A0_plain_errors": 0,
  "A0_plain_p50_ms": 0.19,
  "A0_plain_p95_ms": 0.24,
  "A0_plain_p99_ms": 0.37,
  "A0_plain_requests": 400569,
  "A0_plain_rss_max_kb": 624768,
  "A0_plain_throughput_rps": 40054.2,
  "A1_p000_cpu_sec": 46.4,
  "A1_p000_cpu_sec_vs_control_pct": 5.9,
  "A1_p000_cpu_us_per_req": 116.39,
  "A1_p000_cpu_us_per_req_vs_control_pct": 6.4,
  "A1_p000_errors": 0,
  "A1_p000_p50_ms": 0.2,
  "A1_p000_p50_ms_vs_control_pct": 5.3,
  "A1_p000_p95_ms": 0.25,
  "A1_p000_p95_ms_vs_control_pct": 4.2,
  "A1_p000_p99_ms": 0.38,
  "A1_p000_p99_ms_vs_control_pct": 2.7,
  "A1_p000_requests": 398661,
  "A1_p000_rss_max_kb": 633856,
  "A1_p000_rss_max_kb_vs_control_pct": 1.5,
  "A1_p000_throughput_rps": 39856.1,
  "A1_p000_throughput_rps_vs_control_pct": -0.5,
  "A2_p001_cpu_sec": 46.7,
  "A2_p001_cpu_sec_vs_control_pct": 6.6,
  "A2_p001_cpu_us_per_req": 117.05,
  "A2_p001_cpu_us_per_req_vs_control_pct": 7.0,
  "A2_p001_errors": 0,
  "A2_p001_p50_ms": 0.19,
  "A2_p001_p50_ms_vs_control_pct": 0.0,
  "A2_p001_p95_ms": 0.25,
  "A2_p001_p95_ms_vs_control_pct": 4.2,
  "A2_p001_p99_ms": 0.38,
  "A2_p001_p99_ms_vs_control_pct": 2.7,
  "A2_p001_requests": 398982,
  "A2_p001_rss_max_kb": 648096,
  "A2_p001_rss_max_kb_vs_control_pct": 3.7,
  "A2_p001_throughput_rps": 39878.2,
  "A2_p001_throughput_rps_vs_control_pct": -0.4,
  "A3_default_cpu_sec": 46.65,
  "A3_default_cpu_sec_vs_control_pct": 6.5,
  "A3_default_cpu_us_per_req": 116.77,
  "A3_default_cpu_us_per_req_vs_control_pct": 6.8,
  "A3_default_errors": 0,
  "A3_default_p50_ms": 0.19,
  "A3_default_p50_ms_vs_control_pct": 0.0,
  "A3_default_p95_ms": 0.25,
  "A3_default_p95_ms_vs_control_pct": 4.2,
  "A3_default_p99_ms": 0.38,
  "A3_default_p99_ms_vs_control_pct": 2.7,
  "A3_default_requests": 399511,
  "A3_default_rss_max_kb": 632960,
  "A3_default_rss_max_kb_vs_control_pct": 1.3,
  "A3_default_throughput_rps": 39931.0,
  "A3_default_throughput_rps_vs_control_pct": -0.3,
  "A4_p050_cpu_sec": 49.46,
  "A4_p050_cpu_sec_vs_control_pct": 12.9,
  "A4_p050_cpu_us_per_req": 125.24,
  "A4_p050_cpu_us_per_req_vs_control_pct": 14.5,
  "A4_p050_errors": 0,
  "A4_p050_p50_ms": 0.2,
  "A4_p050_p50_ms_vs_control_pct": 5.3,
  "A4_p050_p95_ms": 0.25,
  "A4_p050_p95_ms_vs_control_pct": 4.2,
  "A4_p050_p99_ms": 0.38,
  "A4_p050_p99_ms_vs_control_pct": 2.7,
  "A4_p050_requests": 394912,
  "A4_p050_rss_max_kb": 650736,
  "A4_p050_rss_max_kb_vs_control_pct": 4.2,
  "A4_p050_throughput_rps": 39482.8,
  "A4_p050_throughput_rps_vs_control_pct": -1.4,
  "A5_p100_cpu_sec": 51.84,
  "A5_p100_cpu_sec_vs_control_pct": 18.3,
  "A5_p100_cpu_us_per_req": 132.69,
  "A5_p100_cpu_us_per_req_vs_control_pct": 21.3,
  "A5_p100_errors": 0,
  "A5_p100_p50_ms": 0.2,
  "A5_p100_p50_ms_vs_control_pct": 5.3,
  "A5_p100_p95_ms": 0.26,
  "A5_p100_p95_ms_vs_control_pct": 8.3,
  "A5_p100_p99_ms": 0.38,
  "A5_p100_p99_ms_vs_control_pct": 2.7,
  "A5_p100_requests": 390675,
  "A5_p100_rss_max_kb": 646144,
  "A5_p100_rss_max_kb_vs_control_pct": 3.4,
  "A5_p100_throughput_rps": 39057.9,
  "A5_p100_throughput_rps_vs_control_pct": -2.5,
  "B0_plain_cpu_sec": 7.17,
  "B0_plain_cpu_us_per_req": 929.24,
  "B0_plain_errors": 0,
  "B0_plain_p50_ms": 10.19,
  "B0_plain_p95_ms": 11.67,
  "B0_plain_p99_ms": 12.34,
  "B0_plain_requests": 7716,
  "B0_plain_rss_max_kb": 282480,
  "B0_plain_throughput_rps": 771.6,
  "B1_default_cpu_sec": 9.07,
  "B1_default_cpu_sec_vs_control_pct": 26.5,
  "B1_default_cpu_us_per_req": 1180.37,
  "B1_default_cpu_us_per_req_vs_control_pct": 27.0,
  "B1_default_errors": 0,
  "B1_default_p50_ms": 10.19,
  "B1_default_p50_ms_vs_control_pct": 0.0,
  "B1_default_p95_ms": 11.69,
  "B1_default_p95_ms_vs_control_pct": 0.2,
  "B1_default_p99_ms": 12.65,
  "B1_default_p99_ms_vs_control_pct": 2.5,
  "B1_default_requests": 7684,
  "B1_default_rss_max_kb": 339456,
  "B1_default_rss_max_kb_vs_control_pct": 20.2,
  "B1_default_throughput_rps": 768.0,
  "B1_default_throughput_rps_vs_control_pct": -0.5,
  "B2_p100_cpu_sec": 9.79,
  "B2_p100_cpu_sec_vs_control_pct": 36.5,
  "B2_p100_cpu_us_per_req": 1271.43,
  "B2_p100_cpu_us_per_req_vs_control_pct": 36.8,
  "B2_p100_errors": 0,
  "B2_p100_p50_ms": 10.2,
  "B2_p100_p50_ms_vs_control_pct": 0.1,
  "B2_p100_p95_ms": 11.64,
  "B2_p100_p95_ms_vs_control_pct": -0.3,
  "B2_p100_p99_ms": 13.36,
  "B2_p100_p99_ms_vs_control_pct": 8.3,
  "B2_p100_requests": 7700,
  "B2_p100_rss_max_kb": 362176,
  "B2_p100_rss_max_kb_vs_control_pct": 28.2,
  "B2_p100_throughput_rps": 770.0,
  "B2_p100_throughput_rps_vs_control_pct": -0.2,
  "app_n": 2000,
  "c1_after_errors": 0,
  "c1_after_p99_ms": 0.4,
  "c1_after_throughput_rps": 39279.6,
  "c1_before_errors": 0,
  "c1_before_p99_ms": 0.4,
  "c1_before_throughput_rps": 38794.8,
  "c1_dropped_spans": 631144,
  "c1_export_error_lines": 2,
  "c1_p99_delta_pct": 0.0,
  "collector_image": "otel/opentelemetry-collector:0.159.0",
  "concurrency": 8,
  "db_n": 20000,
  "duration_sec": 10,
  "jar_app_delta_bytes": 7795538,
  "jar_app_delta_pct": 35.5,
  "jar_app_otel_bytes": 29779989,
  "jar_app_plain_bytes": 21984451,
  "jar_appdb_delta_bytes": 9165846,
  "jar_appdb_otel_bytes": 31759546,
  "jar_appdb_plain_bytes": 22593700,
  "postgres_image": "postgres:18.6",
  "queue_dropped_each_p001": "0,0,0",
  "queue_dropped_each_p01": "0,0,0",
  "queue_dropped_each_p05": "0,0,0",
  "queue_dropped_each_p10": "7554,0,5001",
  "queue_dropped_max_p001": 0,
  "queue_dropped_max_p01": 0,
  "queue_dropped_max_p05": 0,
  "queue_dropped_max_p10": 7554,
  "queue_dropped_rounds_with_drop_p001": 0,
  "queue_dropped_rounds_with_drop_p01": 0,
  "queue_dropped_rounds_with_drop_p05": 0,
  "queue_dropped_rounds_with_drop_p10": 2,
  "queue_requests_median_p001": 399358,
  "queue_requests_median_p01": 397055,
  "queue_requests_median_p05": 394868,
  "queue_requests_median_p10": 386462,
  "queue_rounds_p001": 3,
  "queue_rounds_p01": 3,
  "queue_rounds_p05": 3,
  "queue_rounds_p10": 3,
  "rounds": 3,
  "spans_A0_plain_per100": 0,
  "spans_A1_p000_per100": 0,
  "spans_A2_p001_per100": 0,
  "spans_A3_default_per100": 10,
  "spans_A4_p050_per100": 57,
  "spans_A5_p100_per100": 101,
  "spans_B0_plain_per100": 0,
  "spans_B1_default_per100": 8,
  "spans_B2_p100_per100": 101,
  "warmup_sec": 8,
  "nsens_A0_plain_cpu_us_per_req": 177.39,
  "nsens_A0_plain_throughput_rps": 37795.0,
  "nsens_A3_default_cpu_us_per_req": 187.34,
  "nsens_A3_default_cpu_us_per_req_vs_control_pct": 5.6,
  "nsens_A3_default_throughput_rps": 37388.8,
  "nsens_A3_default_throughput_rps_vs_control_pct": -1.1,
  "nsens_A5_p100_cpu_us_per_req": 195.93,
  "nsens_A5_p100_cpu_us_per_req_vs_control_pct": 10.5,
  "nsens_A5_p100_throughput_rps": 36667.9,
  "nsens_A5_p100_throughput_rps_vs_control_pct": -3.0,
  "nsens_app_n": 20000
}
```

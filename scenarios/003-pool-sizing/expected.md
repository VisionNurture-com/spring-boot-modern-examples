# expected: 003-pool-sizing

> 🔴 **記事に載せる値は本書からしか引きません。**本書の値は `results/003-pool-sizing/summary.json` と
> `tools/check-provenance.py` で機械照合されます。食い違えば CI（M0）が落ちます。

## 何を測ったか

| 項目 | 内容 |
|---|---|
| シナリオ | `003-pool-sizing` |
| モード | M2（JDK 25 + Maven + **Docker**） |
| 測ったもの | プールサイズ別のスループット・待ち時間・pinning 件数 |
| 対象アプリ | `app-db`（Spring Boot 4.1.1 + `spring-boot-starter-webmvc` + `spring-boot-starter-jdbc`・**仮想スレッド有効**） |
| 負荷 | **待つ問い合わせ**（`pg_sleep(0.05`秒`)`）と **CPU を使う問い合わせ**（`generate_series(1, 100,000)` の md5 走査） |
| 同時実行数 | **64**（固定。プールだけを振る） |
| プールサイズ | 2 / 4 / 8 / 16 / 32 / 64 |
| ラウンド数 | **3 ラウンド**・ラウンドロビン・**中央値**で比較 |
| JFR | **既定設定**（`jdk.VirtualThreadPinned` は閾値 20 ms） |
| 再現手順 | `bash scenarios/003-pool-sizing/run.sh` |

## 測定環境

| 項目 | 値 |
|---|---|
| OS | Darwin 25.6.0 |
| アーキテクチャ | arm64 |
| 論理コア数 | **14** |
| PostgreSQL | 18.6 (Debian 18.6-1.pgdg13+2)（イメージ `postgres:18.6`） |

⚠️ **クライアント・アプリ・データベースが同一機体で CPU を共有します。**絶対値はその前提で読んでください。

## 結果 1: 待つ問い合わせ（データベース側が CPU を使わない）

| プールサイズ | スループット | p50 | p99 | pinning |
|---:|---:|---:|---:|---:|
| 2 | **36.4 req/s** | 1757.2 ms | 1785.8 ms | 0 件 |
| 4 | **73.1 req/s** | 877.4 ms | 906.7 ms | 0 件 |
| 8 | **144.7 req/s** | 442.9 ms | 819.7 ms | 0 件 |
| 16 | **291.7 req/s** | 219.0 ms | 376.8 ms | 0 件 |
| 32 | **575.7 req/s** | 110.9 ms | 170.4 ms | 0 件 |
| 64 | **1121.0 req/s** | 56.3 ms | 67.7 ms | 0 件 |

**プールを倍にするとスループットもほぼ倍になります。**待ち時間も同じ比で縮みます。
最大は **プール 64 の 1121.0 req/s** でした。

## 結果 2: CPU を使う問い合わせ

| プールサイズ | スループット | p50 | p99 | pinning |
|---:|---:|---:|---:|---:|
| 2 | **43.3 req/s** | 1477.2 ms | 2899.0 ms | 0 件 |
| 4 | **83.5 req/s** | 766.3 ms | 793.2 ms | 0 件 |
| 8 | **165.0 req/s** | 387.2 ms | 717.7 ms | 0 件 |
| **16** | **221.0 req/s** | 287.2 ms | 461.3 ms | 0 件 |
| 32 | **215.1 req/s** | 287.9 ms | 427.1 ms | 0 件 |
| 64 | **218.6 req/s** | 305.9 ms | 518.4 ms | 0 件 |

🔴 **プール 16 で頭打ちになります。**そこから先はスループットが伸びず、**p99 は悪化します**
（461.3 ms → 518.4 ms）。データベース側の CPU が飽和し、
接続を足しても順番待ちが接続の内側から外側へ移るだけだからです。

HikariCP 公式の式で計算すると **コア数 14 × 2 + 1 = 29** です。
実測の頭打ちは **16** で、式の値より小さいところに来ました。

## 結果 3: プール待ちでは pinning が記録されない

**3 ラウンド × 2 負荷 × 6 プールサイズ = 36 セルすべてで pinning は 0 件**でした（既定閾値 20 ms）。

プールが空くのを待つあいだ、仮想スレッドはキャリアスレッドを手放しています。
HikariCP の待ち行列が `synchronized` ではなく `java.util.concurrent` の仕組みでできているためです。

🔴 **「詰まっている = pinning している」ではありません。**待ち時間が 1.7 秒に伸びていても、pinning は 0 件です。

## 記事が主張してよい範囲 / よくない範囲

| 主張 | 可否 |
|---|---|
| 待つだけの問い合わせでは、プールを倍にするとスループットがほぼ倍になった | ✅ |
| CPU を使う問い合わせでは、プール 16 を超えるとスループットが伸びなかった | ✅ |
| そのとき p99 は 461.3 ms から 518.4 ms へ悪化した | ✅ |
| プール待ちのあいだ pinning は 1 件も記録されなかった（36 セルすべて 0 件） | ✅ |
| **「詰まっている」ことと「pinning している」ことは別である** | ✅ |
| **最適なプールサイズは 16 である** | ❌ **この機体・この問い合わせでの頭打ちの位置**です。読者の環境では動きます |
| **HikariCP 公式の式は誤っている** | ❌ 式が想定する条件（実効スピンドル数・実運用の問い合わせ）と本測定は違います。**式より小さいところで頭打ちになった**とだけ言えます |
| **プールは大きいほどよい** | ❌ 待つだけの負荷でしか成り立ちません |
| **プールは小さいほどよい** | ❌ CPU を使う負荷でも、プール 2 は 16 の 5 分の 1 でした |
| **仮想スレッドを有効にするとプールの設定が効かなくなる** | ❌ Spring 公式が「スレッドプールを設定するプロパティは効かなくなる」と書いているのは**タスク実行のスレッドプール**の話で、コネクションプールには当てはまりません |
| **どのアプリでも同じ数字になる** | ❌ 測っていません |

## 機械照合用（`tools/check-provenance.py` が読む）

```json
{
  "concurrency": 64,
  "db_sleep_ms": 50,
  "db_cpu_n": 100000,
  "cores": 14,
  "hikari_formula_pool": 29,
  "rounds": 3,
  "pools": "2,4,8,16,32,64",
  "wait_pool2_rps": 36.4,
  "wait_pool2_p50_ms": 1757.2,
  "wait_pool2_p99_ms": 1785.8,
  "wait_pool2_pinned": 0,
  "wait_pool4_rps": 73.1,
  "wait_pool4_p50_ms": 877.4,
  "wait_pool4_p99_ms": 906.7,
  "wait_pool4_pinned": 0,
  "wait_pool8_rps": 144.7,
  "wait_pool8_p50_ms": 442.9,
  "wait_pool8_p99_ms": 819.7,
  "wait_pool8_pinned": 0,
  "wait_pool16_rps": 291.7,
  "wait_pool16_p50_ms": 219.0,
  "wait_pool16_p99_ms": 376.8,
  "wait_pool16_pinned": 0,
  "wait_pool32_rps": 575.7,
  "wait_pool32_p50_ms": 110.9,
  "wait_pool32_p99_ms": 170.4,
  "wait_pool32_pinned": 0,
  "wait_pool64_rps": 1121.0,
  "wait_pool64_p50_ms": 56.3,
  "wait_pool64_p99_ms": 67.7,
  "wait_pool64_pinned": 0,
  "wait_best_rps_pool": 64,
  "wait_best_rps": 1121.0,
  "cpu_pool2_rps": 43.3,
  "cpu_pool2_p50_ms": 1477.2,
  "cpu_pool2_p99_ms": 2899.0,
  "cpu_pool2_pinned": 0,
  "cpu_pool4_rps": 83.5,
  "cpu_pool4_p50_ms": 766.3,
  "cpu_pool4_p99_ms": 793.2,
  "cpu_pool4_pinned": 0,
  "cpu_pool8_rps": 165.0,
  "cpu_pool8_p50_ms": 387.2,
  "cpu_pool8_p99_ms": 717.7,
  "cpu_pool8_pinned": 0,
  "cpu_pool16_rps": 221.0,
  "cpu_pool16_p50_ms": 287.2,
  "cpu_pool16_p99_ms": 461.3,
  "cpu_pool16_pinned": 0,
  "cpu_pool32_rps": 215.1,
  "cpu_pool32_p50_ms": 287.9,
  "cpu_pool32_p99_ms": 427.1,
  "cpu_pool32_pinned": 0,
  "cpu_pool64_rps": 218.6,
  "cpu_pool64_p50_ms": 305.9,
  "cpu_pool64_p99_ms": 518.4,
  "cpu_pool64_pinned": 0,
  "cpu_best_rps_pool": 16,
  "cpu_best_rps": 221.0,
  "pinned_total": 0
}
```

# expected: 002-steady-throughput

> 🔴 **記事に載せる値は本書からしか引きません。**本書の値は `results/002-steady-throughput/summary.json` と
> `tools/check-provenance.py` で機械照合されます。食い違えば CI（M0）が落ちます。

## 何を測ったか

| 項目 | 内容 |
|---|---|
| シナリオ | `002-steady-throughput` |
| モード | M3（JDK 25 + Maven + GraalVM。Docker 不要） |
| 測ったもの | **ウォームアップ後の定常状態**のスループットと p99 レイテンシ |
| 対象アプリ | `app`（Spring Boot 4.1.1 + web + actuator）の `/work?n=…` |
| ラウンド | **3 ラウンド**・ラウンドロビン（1 ラウンド = JVM → AOT → Native）・**中央値** |
| 1 計測あたり | ウォームアップ **8 秒**（記録しない）→ 計測 **10 秒** |
| 同時実行 | 8 |
| 負荷 | 軽 `n=2,000` / 重 `n=1,000,000` |
| AOT キャッシュの作り方 | 🔴 **Spring Boot 公式の手順**（`java -Djarmode=tools -jar app.jar extract` で展開してから training run）。展開しないと効果が半減する（`002-startup-3ways` で -30.8% 対 -53.1% を実測） |
| 再現手順 | `bash scenarios/002-steady-throughput/run.sh` |

### なぜ負荷を 2 種類かけたか

**計算量を 10 倍（n=2,000 → 20,000）にしてもスループットは 5.4% しか落ちません。**この領域では**アプリの計算ではなく HTTP の往復が支配的**で、JIT と AOT の差は現れません。
同時実行を 16 → 128 に振ってもスループットは 8.9% しか動かず、**p99 だけが 11.7 倍**に伸びます。飽和の兆候です。

🔴 **この 2 つのスイープは [`002-steady-design`](../002-steady-design/expected.md) が担当します。**
本シナリオの `expected.md` は以前ここに 2 表を持っていましたが、**どの値も `results/` の生ログに存在せず、機械照合の射程外**でした（探索的な実行の値が手書きされていた）。2026-08-27 に取り直して別シナリオへ移しています。

## 測定環境

| 項目 | 値 |
|---|---|
| OS | Darwin 25.5.0 |
| アーキテクチャ | arm64 |
| Java | openjdk version "25.0.4" 2026-07-21 LTS |

> ⚠️ **クライアントとサーバが同一機体で CPU を共有しています。**絶対値はその前提で読んでください。方式間の比較には同じ条件が等しくかかります。

## 実効値

### 軽い負荷（n=2,000・HTTP の往復が支配的）

| 方式 | スループット | p99 | 対 JVM |
|---|---:|---:|---:|
| 素の JVM（基準） | 46,064.6 rps | 0.27 ms | 基準 |
| JVM AOT キャッシュ（**展開した形**） | 46,100.5 rps | 0.27 ms | **+0.1%** |
| GraalVM Native Image | 43,547.7 rps | 0.55 ms | **-5.5%** |

### 重い負荷（n=1,000,000・アプリの計算が支配的）

| 方式 | スループット | p99 | 対 JVM |
|---|---:|---:|---:|
| 素の JVM（基準） | 4,011.3 rps | 2.16 ms | 基準 |
| JVM AOT キャッシュ（**展開した形**） | 4,012.9 rps | 2.16 ms | **+0.0%** |
| GraalVM Native Image | 3,896.1 rps | 2.63 ms | **-2.9%** |

エラーはすべての計測で **0 件**です。

## この測定で分かったこと

1. **AOT キャッシュは定常状態を変えません**（軽 +0.1% / 重 +0.0%）。**公式手順で展開してキャッシュを効かせた状態でも変わりません。**
2. **Native Image は定常状態で JVM より遅い**（軽 -5.5% / 重 -2.9%）。
3. **Native Image は p99 が悪い**（軽い負荷で 0.55 ms 対 0.27 ms）。
4. `002-startup-3ways` では Native が起動を 95.3% 短縮しました。**起動と定常で結論が逆になります。**

> 🔴 **「AOT キャッシュは実行時の最適化に関与しないから定常が変わらない」とは書けません。**
> [JEP 515](https://openjdk.org/jeps/515)（JDK 25 で delivered）は method-execution profiles を **AOT キャッシュ経由で運び warmup を縮めること**を目的にしています。
> 上の ±0.0〜0.1% と矛盾しないのは、**JEP 515 が狙うのは warmup（peak に達するまでの時間）であって peak そのものではない**からです。
> **本シナリオはウォームアップ 8 秒の後を測っており、warmup 曲線は測っていません。**

## ウォームアップの妥当性

ウォームアップ時間を振って、定常値が頭打ちになることを確認しています。
**8 秒から 40 秒へ 5 倍に伸ばしても +0.47%** で、残差は Native が遅い幅（軽 -5.5% / 重 -2.9%）より小さく、しかも **JVM 側を有利にする方向**のため、結論は覆りません。

🔴 **このスイープは [`002-steady-design`](../002-steady-design/expected.md) が担当します。**
本シナリオの `expected.md` は以前ここに表を持っていましたが、**どの値も `results/` の生ログに存在せず、機械照合の射程外**でした。2026-08-27 に取り直し、**各点でサーバを立て直す形**（同一プロセスでの連続実行をやめる）へ設計を改めたうえで別シナリオへ移しています。

## 記事が主張してよい範囲 / よくない範囲

| 主張 | 可否 |
|---|---|
| この機種・このアプリで、AOT キャッシュは定常状態をほぼ変えなかった | ✅ |
| 同じく Native Image は定常状態で JVM より遅く、p99 も悪かった | ✅ |
| 起動と定常で有利な方式が入れ替わる | ✅ |
| **Native Image は常に遅い** | ❌ ワークロード次第です。測ったのは 2 種類の合成負荷だけです |
| **JIT の最適化が効いたから速い** | ❌ 機序は測っていません（JIT ログもコンパイル状況も見ていません） |
| **メモリ使用量が Native のほうが少ない** | ❌ 測っていません |
| **実アプリでも同じ差になる** | ❌ 依存の多い実アプリでは測っていません |
| **AOT キャッシュは warmup を縮めない** | ❌ **warmup を測っていません**（JEP 515 はそれを狙う仕組みです）|

## 機械照合用（`tools/check-provenance.py` が読む）

```json
{
  "rounds": 3,
  "warmup_sec": 8,
  "duration_sec": 10,
  "concurrency": 8,
  "light_n": 2000,
  "heavy_n": 1000000,
  "methods": "jvm,aot,native",
  "light_jvm_throughput_rps": 46064.6,
  "light_jvm_p99_ms": 0.27,
  "light_jvm_errors": 0,
  "light_aot_throughput_rps": 46100.5,
  "light_aot_p99_ms": 0.27,
  "light_aot_errors": 0,
  "light_native_throughput_rps": 43547.7,
  "light_native_p99_ms": 0.55,
  "light_native_errors": 0,
  "heavy_jvm_throughput_rps": 4011.3,
  "heavy_jvm_p99_ms": 2.16,
  "heavy_jvm_errors": 0,
  "heavy_aot_throughput_rps": 4012.9,
  "heavy_aot_p99_ms": 2.16,
  "heavy_aot_errors": 0,
  "heavy_native_throughput_rps": 3896.1,
  "heavy_native_p99_ms": 2.63,
  "heavy_native_errors": 0,
  "light_aot_vs_jvm_pct": 0.1,
  "light_native_vs_jvm_pct": -5.5,
  "heavy_aot_vs_jvm_pct": 0.0,
  "heavy_native_vs_jvm_pct": -2.9
}
```

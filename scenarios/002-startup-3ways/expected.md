# expected: 002-startup-3ways

> 🔴 **記事に載せる値は本書からしか引きません。**本書の値は `results/002-startup-3ways/summary.json` と
> `tools/check-provenance.py` で機械照合されます。食い違えば CI（M0）が落ちます。

## 何を測ったか

| 項目 | 内容 |
|---|---|
| シナリオ | `002-startup-3ways` |
| モード | M3（JDK 25 + Maven + GraalVM。Docker 不要） |
| 測ったもの | Spring context refresh までの**プロセス実時間** |
| 対象アプリ | `app`（Spring Boot 4.1.1 + `spring-boot-starter-web` + `spring-boot-starter-actuator`） |
| セット数 | **7 セット**・ラウンドロビン（1 セットで全アームを隣り合わせる）・**中央値**で比較 |
| 捨て走り | **1 セット**（記録しない） |
| 再現手順 | `bash scenarios/002-startup-3ways/run.sh` |

### アーム（5 つ）の意味

| アーム | 中身 | なぜ置くか |
|---|---|---|
| `jvm` | 素の JVM・**実行可能 jar のまま** | 基準。多くの人の出発点 |
| `jvmx` | 素の JVM・**展開した形** | **展開そのものの寄与**を切り出す |
| `aotfat` | AOT キャッシュ・**展開せずに当てる** | **手順を飛ばしたとき何が起きるか** |
| `aot` | AOT キャッシュ・**展開した形** | **Spring Boot 公式の手順** |
| `native` | GraalVM Native Image | — |

### 🔴 AOT キャッシュは「展開した形」で使う

Spring Boot の公式ドキュメントは次のとおり明記しています。

> "To use the AOT cache feature, you should first perform a training run on your application **in extracted form**"
>
> "**You have to use the cache file with the extracted form of the application, otherwise it has no effect.**"
>
> —— [Spring Boot Reference — AOT Cache](https://docs.spring.io/spring-boot/reference/packaging/aot-cache.html)

これは JEP 483 の Non-Goals と整合します。

> "It is not a goal to cache classes that are loaded by **user-defined class loaders**. Only classes loaded from the class path, the module path, and the JDK itself, by the JDK's **built-in class loaders**, can be cached."
>
> —— [JEP 483: Ahead-of-Time Class Loading & Linking](https://openjdk.org/jeps/483)

実行可能 jar はアプリのクラスを独自のクラスローダで読むため、展開しないとアプリのクラスがキャッシュ対象から外れます。**本シナリオはその差を実測しています**（`aotfat` と `aot`）。

### 測定設計（意図的な選択）

1. **基準（素の JVM）は本シナリオが唯一持ちます。**他シナリオで基準を測り直しません。値が 2 つ存在すると、記事の比較がどちらを引くかで揺れるためです。
2. **ブロック実行ではなくラウンドロビン**です。「A を N 回 → B を N 回」だと、機体の熱や背景負荷が特定のアームにだけ乗ります。
3. **捨て走りを 1 セット行い記録しません。**初回のページキャッシュ効果を特定のアームへ乗せないためです。
4. **展開だけのアーム（`jvmx`）を置きます。**展開の寄与とキャッシュの寄与を分けるためです。

## 測定環境

| 項目 | 値 |
|---|---|
| OS | Darwin 25.5.0 |
| アーキテクチャ | arm64 |
| Java | openjdk version "25.0.4" 2026-07-21 LTS |

> ⚠️ **1 機種の測定です。**読者環境での絶対値は異なります。**短縮率は機体をまたいでも近い**ことを別途確認しています（同じシナリオを GitHub Actions の `ubuntu-latest` で走らせると短縮率は 27.6%、この macOS 機では 29.8% でした。いずれも展開せずに測った当時の値です）。

## 実効値

| アーム | 中央値 | 最小 | 最大 | 対 基準 |
|---|---:|---:|---:|---:|
| 素の JVM（基準・jar のまま） | **0.911 秒** | 0.901 | 0.938 | — |
| 展開しただけ（AOT なし） | **0.789 秒** | 0.785 | 0.808 | **-13.4%** |
| AOT キャッシュ（**展開せず**） | **0.63 秒** | 0.626 | 0.64 | **-30.8%** |
| AOT キャッシュ（**展開あり・公式手順**） | **0.427 秒** | 0.42 | 0.434 | **-53.1%** |
| GraalVM Native Image | **0.043 秒** | 0.042 | 0.048 | **-95.3%** |

### 短縮の内訳（公式手順の -53.1% は何でできているか）

| 段 | 寄与 |
|---|---:|
| 展開そのもの | **-13.4%** |
| キャッシュの上乗せ（展開ありで測った差） | **-39.7%** |
| 合計 | **-53.1%** |

## 代償（起動の速さと引き換えに何が要るか）

| アーム | ビルド時間 | 成果物 | 追加で要るもの |
|---|---:|---|---|
| 素の JVM | — | jar **21,983,846 バイト（21.0 MiB）** | なし |
| 展開しただけ | — | 展開後の合計 **21,775,294 バイト（20.8 MiB）** | なし |
| AOT キャッシュ（展開せず） | 2 秒 | キャッシュ **54,984,704 バイト（52.4 MiB）** | JDK 25。**コード変更なし** |
| AOT キャッシュ（展開あり） | 3 秒 | キャッシュ **58,195,968 バイト（55.5 MiB）** | JDK 25。**コード変更なし** |
| GraalVM Native Image | **43 秒** | バイナリ **91,016,208 バイト（86.8 MiB）** | GraalVM。ビルド時ピークメモリ **3.66 GB** |

> 🔴 **サイズは「バイト」と「MiB」を併記します。**「MB」とだけ書くと 10 進の 100 万バイトと 2 進の 1,048,576 バイトのどちらか読み手に判別できません。
> - キャッシュは展開の有無で **54,984,704 → 58,195,968 バイト**に増えます。アプリのクラスがキャッシュ対象に入るためです。
> - キャッシュ生成時の**警告は展開の有無で 20 件 → 111 件**に増えます。**警告件数は手順とセットでしか意味を持ちません。**

## この測定で分かった落とし穴

| 現象 | 実測 |
|---|---|
| 🔴 **展開を飛ばすと効果が半分近くになる** | 展開せずにキャッシュを当てると **-30.8%**、公式手順どおり展開すると **-53.1%**。エラーも警告も「効いていない」とは言わない（**既定の出力に aot 関連の行が 0 行**であることを [`002-cache-pitfalls`](../002-cache-pitfalls/expected.md) で実測）|
| **AOT キャッシュは jar が変わると効かなくなる** | 🔴 **本シナリオでは測っていません。**[`002-cache-pitfalls`](../002-cache-pitfalls/expected.md) が担当します（既定の出力に warning 1 行 + error 3 行・キャッシュなしより **+7.5%** 遅い）|
| **Native バイナリの初回起動だけ遅い** | 捨て走りの native は **1.039 秒**で、本計測（0.043 秒）の約 24 倍 |
| **`clean` を挟まないと素の jar が汚れる** | 前回の Native ビルドが残した Spring AOT 生成クラスが混ざる。🔴 **サイズは本シナリオでは測っていません。**[`002-cache-pitfalls`](../002-cache-pitfalls/expected.md) が担当します（21,983,846 → 22,217,685 バイト・生成クラス 91 件）|

## 機構（なぜそうなるか）

| 仕組み | 何を狙うか | 出典 |
|---|---|---|
| **JEP 483**（JDK 24 で delivered） | **起動**。クラスのロードとリンクを training run で先に済ませる | [JEP 483](https://openjdk.org/jeps/483) |
| **JEP 514**（JDK 25 で delivered） | 上記を**1 コマンドで**作れるようにする（`-XX:AOTCacheOutput`） | [JEP 514](https://openjdk.org/jeps/514) |
| **JEP 515**（JDK 25 で delivered） | 🔴 **warmup**。method-execution profiles を **AOT キャッシュ経由で運ぶ** | [JEP 515](https://openjdk.org/jeps/515) |

> 🔴 **「AOT キャッシュは実行時最適化に関与しない」とは書けません。**JEP 515 は JDK 25 で delivered され、**プロファイルを AOT キャッシュ経由で運んで warmup を縮めること**を目的にしています。
> **ただし warmup は本シナリオの測定範囲の外です。**本シナリオは起動を、`002-steady-throughput` はウォームアップ**後**の定常状態を測っており、**その間の warmup 曲線は測っていません**。

## 記事が主張してよい範囲 / よくない範囲

| 主張 | 可否 |
|---|---|
| この機種・このアプリで、公式手順の AOT キャッシュが context refresh を 53.1% 短縮した | ✅ |
| 同じく Native Image が 95.3% 短縮した | ✅ |
| 展開を飛ばすと 30.8% にとどまった | ✅ |
| 展開だけでも 13.4% 縮んだ | ✅ |
| AOT キャッシュはコード変更なし・GraalVM なしで使える | ✅ |
| Native Image はビルドに 43 秒とピーク 3.66 GB を要した | ✅ |
| **どのアプリでも同じ率で短縮する** | ❌ 測っていません |
| **AOT キャッシュは warmup を縮めない** | ❌ **warmup を測っていません**（JEP 515 はそれを狙う仕組みです） |
| **スループット / メモリ使用量で Native が有利 / 不利** | ❌ 本シナリオは定常状態を測っていません（`002-steady-throughput` の担当） |
| **Native Image のほうが常に良い** | ❌ 起動しか測っていません。ビルド時間・制約・バイナリサイズは上表のとおり代償があります |
| **AOT キャッシュは常に効く** | ❌ jar が変われば効きません（[`002-cache-pitfalls`](../002-cache-pitfalls/expected.md) の担当）。展開を飛ばしても半分近くしか効きません |
| **jar が食い違っても静かに効かなくなる** | ❌ 🔴 **既定の出力に warning と error が出ます**（[`002-cache-pitfalls`](../002-cache-pitfalls/expected.md) で実測）|
| **キャッシュのサイズはここに載せたバイト数で再現する** | ❌ 学習実行のたびに数十万バイトの範囲で変わります。**幅そのものは本シナリオの環境では測っていません**（別 OS で 4 回観測しただけです）。手順を正しく踏めたかどうかは、サイズの一致では判定できません |

## 機械照合用（`tools/check-provenance.py` が読む）

```json
{
  "sets": 7,
  "methods": "jvm,jvmx,aotfat,aot,native",
  "jar_bytes": 21983846,
  "jvm_median_s": 0.911,
  "jvm_min_s": 0.901,
  "jvm_max_s": 0.938,
  "jvmx_median_s": 0.789,
  "jvmx_min_s": 0.785,
  "jvmx_max_s": 0.808,
  "aotfat_median_s": 0.63,
  "aotfat_min_s": 0.626,
  "aotfat_max_s": 0.64,
  "aot_median_s": 0.427,
  "aot_min_s": 0.42,
  "aot_max_s": 0.434,
  "native_median_s": 0.043,
  "native_min_s": 0.042,
  "native_max_s": 0.048,
  "jvmx_reduction_pct": 13.4,
  "aotfat_reduction_pct": 30.8,
  "aot_reduction_pct": 53.1,
  "native_reduction_pct": 95.3,
  "extracted_total_bytes": 21775294,
  "aotfat_cache_bytes": 54984704,
  "aotfat_build_sec": 2,
  "aotfat_build_warnings": 20,
  "aot_cache_bytes": 58195968,
  "aot_build_sec": 3,
  "aot_build_warnings": 111,
  "native_binary_bytes": 91016208,
  "native_build_sec": 43,
  "native_build_peak_gb": 3.66
}
```

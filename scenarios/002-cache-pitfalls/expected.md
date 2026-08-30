# expected: 002-cache-pitfalls

> 🔴 **記事に載せる値は本書からしか引きません。**本書の値は `results/002-cache-pitfalls/summary.json` と
> `tools/check-provenance.py` で機械照合されます。食い違えば CI（M0）が落ちます。

## なぜこのシナリオを足したか

`002-startup-3ways` の expected.md は「落とし穴」として次の 2 件を書いていました。

1. 食い違うキャッシュは `Opened AOT cache` と表示されたまま、基準より 5.4% 遅い（素 0.911s / 食い違い 0.960s）
2. `clean` を挟まないと jar が 21,983,358 → 22,217,180 バイトに増える

**どちらも生ログが `results/` に無く、機械照合用の json ブロックにも入っていませんでした。**
手書きで入った記述であり、`check-provenance.py` は 1 度も見ていません。本シナリオで測り直します。

🔴 **測り直した結果、1 の記述は事実と食い違っていました。**下記「経路 1」のとおりです。

## 何を測ったか

| 項目 | 内容 |
|---|---|
| シナリオ | `002-cache-pitfalls` |
| モード | M1（JDK 25 + Maven。**GraalVM も Docker も不要**） |
| 測ったもの | AOT キャッシュが効かなくなる 2 経路の**出力**と**起動時間** |
| 対象アプリ | `app`（Spring Boot 4.1.1 + `spring-boot-starter-web` + `spring-boot-starter-actuator`） |
| セット数 | **5 セット**・ラウンドロビン・**中央値**で比較 |
| 捨て走り | **1 セット**（記録しない） |
| 再現手順 | `bash scenarios/002-cache-pitfalls/run.sh` |

### アーム（3 つ・すべて展開した形で土俵をそろえる）

| アーム | 中身 | なぜ置くか |
|---|---|---|
| `none` | キャッシュなし | 基準。展開だけ済ませた状態 |
| `stale` | **キャッシュを作った jar と違う jar** に当てる | 食い違い |
| `match` | 同じ jar に当てる | 正しく効いた状態 |

`stale` の jar は、`/hello` の戻り値を 1 行だけ変えて作り直したものです（21,983,846 → **21,983,850 バイト**）。
読者が実際にやること（コードを直して `mvn package` を打ち直す）を再現しています。
リポジトリの working tree は書き換えず、モジュールを一時ディレクトリへ複製してから変更しています。

## 測定環境

| 項目 | 値 |
|---|---|
| OS | Darwin 25.5.0 |
| アーキテクチャ | arm64 |
| Java | openjdk version "25.0.4" 2026-07-21 LTS |

## 経路 1: jar が食い違うと何が起きるか

### 🔴 静かではありません（旧記述の訂正）

`-Xlog` を付けない**既定の出力**に、次の **warning 1 行 + error 3 行**が出ます。

```text
[0.034s][warning][aot] This file is not the one used while building the AOT cache: 'app.jar', timestamp has changed, size has changed
[0.034s][error  ][aot] An error has occurred while processing the AOT cache. Run with -Xlog:aot for details.
[0.034s][error  ][aot] shared class paths mismatch (hint: enable -Xlog:class+path=info to diagnose the failure)
[0.034s][error  ][aot] Unable to map shared spaces
```

**プロセスは終了コード 0 で起動します。**キャッシュを捨てて素の起動に落ちるためです。

### 🔴 `Opened AOT cache` は成功の証拠になりません

| 実行 | `Opened AOT cache` の出現 |
|---|---:|
| 既定（`-Xlog` なし） | **0 行** |
| `-Xlog:aot` 付き | **1 行** |

**既定では 1 行も出ません。**`-Xlog:aot` を付けたときだけ出ますが、その行は**検証より前**に出力されるため、
食い違っているキャッシュでも同じように出ます。効いている証拠として読めません。

### 実効値（5 セット中央値・すべて展開した形）

| アーム | 中央値 | 最小 | 最大 | 対 キャッシュなし |
|---|---:|---:|---:|---:|
| キャッシュなし（基準） | **0.783 秒** | 0.78 | 0.789 | — |
| **食い違うキャッシュ** | **0.842 秒** | 0.833 | 0.845 | **+7.5%（遅い）** |
| 一致するキャッシュ | **0.422 秒** | 0.407 | 0.424 | **-46.1%** |

**キャッシュを付けたのに、付けないより遅くなります。**マップして検証して捨てるぶんの往復が乗るためです。

## 経路 2: `clean` を挟まないと素の jar に何が混ざるか

`-Pnative` を付けたビルドは `spring-boot:process-aot` を走らせ、Spring AOT の生成クラスを `target/classes` へ置きます。
そのあと `clean` を挟まずに `mvn package` を打ち直すと、**生成クラスを含んだ jar** ができます。

| 状態 | jar のサイズ |
|---|---:|
| `clean` あり | **21,983,846 バイト（21.0 MiB）** |
| `clean` なし（`-Pnative` の後） | **22,217,685 バイト（21.2 MiB）** |
| 差 | **233,839 バイト** |

混ざっていたのは `__BeanDefinitions` / `__BeanFactoryRegistrations` / `__ApplicationContextInitializer` で終わる
Spring AOT の生成クラス **91 件**です。

**素の JVM の基準値をこの jar で測ると、比較の土俵が崩れます。**`002-startup-3ways` が `clean` を必ず挟むのはこのためです。

## 記事が主張してよい範囲 / よくない範囲

| 主張 | 可否 |
|---|---|
| キャッシュを作った jar と違う jar に当てると、キャッシュなしより 7.5% 遅くなった | ✅ |
| そのとき既定の出力に warning 1 行と error 3 行が出た | ✅ |
| それでもプロセスは終了コード 0 で起動した | ✅ |
| `Opened AOT cache` は既定では出ず、`-Xlog:aot` を付けたときだけ出た | ✅ |
| **展開を飛ばした場合は、既定の出力に aot 関連の行が 1 行も出ない** | ✅ **0 行**を実測 |
| `-Pnative` の後に `clean` を挟まないと jar が 233,839 バイト増えた | ✅ |
| **食い違うキャッシュは静かに効かなくなる** | ❌ **既定で警告とエラーが出ます**（旧記述の誤り） |
| **食い違うキャッシュは基準より 5.4% 遅い** | ❌ 生ログのない旧記述です。同じ土俵（展開した形）で測り直すと **+7.5%** です |
| **どのアプリでも同じ差になる** | ❌ 測っていません |
| **警告が出れば必ず気づける** | ❌ 出力を捨てている環境（`> /dev/null`・ログ収集の設定次第）では見えません |

## 機械照合用（`tools/check-provenance.py` が読む）

```json
{
  "sets": 5,
  "arms": "none,stale,match",
  "jar_a_bytes": 21983846,
  "jar_b_bytes": 21983850,
  "stale_cache_bytes": 57950208,
  "match_cache_bytes": 57982976,
  "none_median_s": 0.783,
  "none_min_s": 0.78,
  "none_max_s": 0.789,
  "stale_median_s": 0.842,
  "stale_min_s": 0.833,
  "stale_max_s": 0.845,
  "match_median_s": 0.422,
  "match_min_s": 0.407,
  "match_max_s": 0.424,
  "stale_vs_none_pct": 7.5,
  "match_vs_none_pct": -46.1,
  "stale_default_warning_lines": 1,
  "stale_default_error_lines": 3,
  "stale_exit_code": 0,
  "skip_extract_default_aot_lines": 0,
  "opened_msg_default_lines": 0,
  "opened_msg_xlog_lines": 1,
  "jar_clean_bytes": 21983846,
  "jar_dirty_bytes": 22217685,
  "jar_dirty_delta_bytes": 233839,
  "aot_generated_classes": 91
}
```

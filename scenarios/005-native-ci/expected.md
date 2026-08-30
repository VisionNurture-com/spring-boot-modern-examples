# 005-native-ci — 実効値

測定日: 2026-08-29 / 測定場所: GitHub Actions `ubuntu-latest`（パブリックリポジトリの標準 runner）
測定リポジトリ: [`orcus-tbpd/native-ci-measure`](https://github.com/orcus-tbpd/native-ci-measure)

🔴 **記事に載せる値は本ファイルの末尾 json ブロックからしか引かない。**散文と表の数値も、
すべて同じキーを出所とする（手書きで足した数値は突合を 1 度も通らない）。

## 測定条件

| 項目 | 値 | 出所キー |
|---|---|---|
| runner | 4 vCPU / 16373448 kB / 空きディスク 89689280 kB | `runner_vcpu` `runner_mem_total_kb` `runner_disk_avail_kb` |
| `CI` 環境変数 | true（= `native-image` は dedicated mode を選ぶ）| `runner_ci_env_is_true` |
| GraalVM | GraalVM CE 25.0.2+10.1 / Java 25.0.2+10 | `graalvm_version` `java_version` |
| ラウンド数 | 3（中央値を採る）| `rounds` |

## ビルドの所要（壁時計・秒）

| 腕 | R1 | R2 | R3 | 中央値 |
|---|---:|---:|---:|---:|
| 対照 JVM `mvn package` | 21.445 | 14.904 | 22.152 | **21.445** |
| Native（キャッシュなし）| 199.447 | 214.902 | 204.851 | **204.851** |
| Native（キャッシュあり）| 202.618 | 219.361 | 200.888 | **202.618** |
| Native（ヒープ 2g・落ちる）| 377.242 | 533.566 | 457.62 | **457.62** |

- Native は対照の **9.552 倍**（`native_over_jvm_ratio`）
- Maven キャッシュありは **-1.09%**（`cache_wall_delta_pct`）。ビルド本体だけで見ても -1.12%（`cache_build_delta_pct`）

## メモリ

| 項目 | 値 | 出所キー |
|---|---:|---|
| Peak RSS（キャッシュなし・中央値）| 4444340224 バイト | `native_nocache_peak_rss_bytes_median` |
| runner の総メモリ（`native-image` の認識）| 16766402560 バイト | `system_total_bytes` |
| 総メモリに対する比 | 26.51% | `peak_rss_over_system_pct` |

## 成果物

| 項目 | 値 | 出所キー |
|---|---:|---|
| jar | 21984304 バイト | `jar_bytes` |
| ネイティブバイナリ | 97192200 バイト | `native_nocache_binary_bytes` |
| 比 | 4.421 倍 | `binary_over_jar_ratio` |
| 到達可能な型 / メソッド | 20120 / 91932 | `reachable_types` `reachable_methods` |

## 落ちる条件

`-J-Xmx2g` に絞ると **3 ラウンドとも失敗**した。

| 項目 | 値 | 出所キー |
|---|---:|---|
| 終了コード | 1 | `oom_exit_code` |
| `OutOfMemoryError` の行数（各ラウンド）| 1 | `oom_lines_per_round` |
| できたバイナリ | 0 バイト | `oom_binary_bytes` |

🔴 **落ちるまでの所要は成功時より長い**（中央値 457.62 秒 ⟷ 204.851 秒）。
上限に張りついた状態で GC を繰り返してから落ちるためである。

## 正典のコマンドだけではバイナリができない

`mvn -Pnative package`（Native Build Tools のドキュメントが示す形）だけを走らせると、
**BUILD SUCCESS で終わるがネイティブバイナリはできない**。3 ラウンドとも同じである。

| 項目 | 値 | 出所キー |
|---|---:|---|
| `package` のみでバイナリができたか（1 = できた）| 0 | `package_only_binary_created` |

`spring-boot-starter-parent` 4.1.1 の `native` プロファイルが束縛するのは
`add-reachability-metadata` だけで、`compile-no-fork` は effective POM に現れない。

## 測っていない範囲

- **プライベートリポジトリ（2 vCPU / 8 GB）は測っていない。**公式仕様の引用にとどめる
- **`graal-25.3.4.1` は測っていない。**`setup-graalvm` に `java-version: '25'` を渡すと
  GraalVM CE 25.0.2+10.1 が入り、`version: '25.3'` は失敗した（証跡は `raw/graalvm-*.txt`）
- **Gradle は測っていない**（Maven のみ）
- **アプリは 1 本のみ。**規模の違うアプリでの所要は測っていない

```json
{
  "runner_ci_env_is_true": 1,
  "rounds": 3,
  "runner_vcpu": 4,
  "runner_mem_total_kb": 16373448,
  "runner_disk_avail_kb": 89689280,
  "jar_bytes": 21984304,
  "jvm_wall_sec_r1": 21.445,
  "jvm_wall_sec_r2": 14.904,
  "jvm_wall_sec_r3": 22.152,
  "jvm_wall_sec_median": 21.445,
  "native_nocache_binary_bytes": 97192200,
  "native_nocache_image_bytes": 102345560,
  "reachable_types": 20120,
  "reachable_methods": 91932,
  "system_total_bytes": 16766402560,
  "graalvm_version": "GraalVM CE 25.0.2+10.1",
  "java_version": "25.0.2+10",
  "native_nocache_wall_sec_r1": 199.447,
  "native_nocache_wall_sec_r2": 214.902,
  "native_nocache_wall_sec_r3": 204.851,
  "native_nocache_wall_sec_median": 204.851,
  "native_nocache_build_sec_r1": 188.008,
  "native_nocache_build_sec_r2": 203.755,
  "native_nocache_build_sec_r3": 193.938,
  "native_nocache_build_sec_median": 193.938,
  "native_nocache_peak_rss_bytes_r1": 4329230336,
  "native_nocache_peak_rss_bytes_r2": 4444340224,
  "native_nocache_peak_rss_bytes_r3": 4521082880,
  "native_nocache_peak_rss_bytes_median": 4444340224,
  "native_cache_binary_bytes": 97192200,
  "native_cache_image_bytes": 102345640,
  "native_cache_wall_sec_r1": 202.618,
  "native_cache_wall_sec_r2": 219.361,
  "native_cache_wall_sec_r3": 200.888,
  "native_cache_wall_sec_median": 202.618,
  "native_cache_build_sec_r1": 191.757,
  "native_cache_build_sec_r2": 208.884,
  "native_cache_build_sec_r3": 191.711,
  "native_cache_build_sec_median": 191.757,
  "native_cache_peak_rss_bytes_r1": 4346052608,
  "native_cache_peak_rss_bytes_r2": 4287074304,
  "native_cache_peak_rss_bytes_r3": 4419584000,
  "native_cache_peak_rss_bytes_median": 4346052608,
  "package_only_binary_created": 0,
  "oom_binary_bytes": 0,
  "oom_wall_sec_r1": 377.242,
  "oom_wall_sec_r2": 533.566,
  "oom_wall_sec_r3": 457.62,
  "oom_wall_sec_median": 457.62,
  "oom_exit_code": 1,
  "oom_lines_per_round": 1,
  "oom_xmx_gib": 2,
  "native_over_jvm_ratio": 9.552,
  "cache_wall_delta_pct": -1.09,
  "cache_build_delta_pct": -1.12,
  "peak_rss_over_system_pct": 26.51,
  "binary_over_jar_ratio": 4.421
}
```

# 006-otel-cost — 計装のコストをサンプリング率ごとに測る

`spring-boot-starter-opentelemetry` を入れたとき、**サンプリング率と仕事の重さごとに
レイテンシ・スループット・CPU・メモリがどれだけ変わるか**を測る。

## 対照の作り方（ここが設計の要）

「計装なし」は **プロパティで無効にした状態ではなく、依存ごと外してビルドした jar** である。
Maven の `otel` プロファイル（`app/pom.xml` / `app-db/pom.xml`）を外すと starter が入らない。

```bash
mvn -pl app -am package          # 計装なし
mvn -Potel -pl app package       # 計装あり
```

無効化と非搭載は別物で、無効化ではクラスパス上のクラスも自動設定の評価も残る。
**対照が本当に計装なしであることは、コレクタ側の受信スパン 0 本で裏を取る**（検算パス）。

⚠️ ただし対照にも `spring-boot-starter-actuator` は入ったままである（`app` の既存構成）。
「何も入っていない状態」ではない。

## 腕

| 腕 | アプリ | 率 | 狙い |
|---|---|---|---|
| `A0_plain` | `app` | — | **対照**（計装なし）|
| `A1_p000` | `app` | 0.0 | 記録しないが計装は入っている。判定と伝播だけのコストを分離する |
| `A2_p001` | `app` | 0.01 | 率の下端 |
| `A3_default` | `app` | **既定（未指定）** | 読者が何もしないときの状態 |
| `A4_p050` | `app` | 0.5 | 中間 |
| `A5_p100` | `app` | 1.0 | 全量 |
| `B0_plain` | `app-db` | — | **対照**（DB 経路）|
| `B1_default` | `app-db` | 既定 | 仕事が重いときの既定 |
| `B2_p100` | `app-db` | 1.0 | 仕事が重いときの全量 |
| `C1` | `app` | 1.0 | 測定の途中で**コレクタを止める** |

## フェーズ

1 回で全部回すと手元では 15 分ほどかかる。フェーズを分けて回せる。

```bash
bash scenarios/006-otel-cost/run.sh                       # 全部
bash scenarios/006-otel-cost/run.sh --phase build         # jar を 4 つ作る
bash scenarios/006-otel-cost/run.sh --phase verify        # 受信スパンを数える
bash scenarios/006-otel-cost/run.sh --phase app --rounds 1 --round-start 2
bash scenarios/006-otel-cost/run.sh --phase db
bash scenarios/006-otel-cost/run.sh --phase queue         # キュー溢れを数える
bash scenarios/006-otel-cost/run.sh --phase drop          # コレクタを止める
bash scenarios/006-otel-cost/run.sh --phase aggregate     # 集計だけ
```

## 測っていないもの

| 対象 | 理由 |
|---|---|
| メトリクスの送信コスト | `management.otlp.metrics.export.step` の既定が **1 分**で、10 秒の負荷では送信が数回しか起きない。全腕で無効にして揃えた |
| ログの送信コスト | 同上（本シナリオはトレースのコストを測る）|
| `opentelemetry-javaagent` 経路 | 別の入れ方であり、本シリーズは Spring チームの starter を測る |
| OTel コミュニティの Spring Boot starter | 同上（`io.opentelemetry.instrumentation:opentelemetry-spring-boot-starter`）|
| JDBC の子スパン | 🔴 **starter 単体では出ない**（実測）。出すにはサポート外の追加依存が要る |
| コレクタから先（バックエンド）| 受けて捨てる構成にしてある。測るのはアプリ側のコストだけ |

## 値の出所

`tools/loadgen/LoadGen.java`（002 と同じ負荷生成器）が出す JSON と、
`ps -o rss=,time=` によるプロセス単位の CPU・RSS だけを使う。
コレクタ側の受信スパン数は `debug` エクスポータの出力を数えたものである。

**記事に載せる値は [`expected.md`](expected.md) の json ブロックからしか引かない。**

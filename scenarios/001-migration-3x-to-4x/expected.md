# expected: 001-migration-3x-to-4x

> 🔴 **記事に載せる値は本書からしか引きません。**本書の値は `results/001-migration-3x-to-4x/summary.json` と
> `tools/check-provenance.py` で機械照合されます。食い違えば CI（M0）が落ちます。

## 何を測ったか

| 項目 | 内容 |
|---|---|
| シナリオ | `001-migration-3x-to-4x` |
| モード | M1（JDK 25 + Maven）|
| 測ったもの | 3.5.16 → 4.1.1 の移行で、**直しては再ビルドする波ごとに**ビルドを止める箇所（N1）と非推奨警告どまりの箇所（N2）が何件出るか |
| 対象アプリ | `scenarios/001-migration-3x-to-4x/app/`（**ソース 6 ファイル・直接依存 3 個**）|
| アーム | **naive**（親の版だけ上げる）と **classic**（公式 §Migration Strategy の `spring-boot-starter-classic` / `-test-classic` を最初から入れる）|
| 再現手順 | `bash scenarios/001-migration-3x-to-4x/run.sh` |

⚠️ **件数はこの題材アプリの構成に強く依存します。**ソース 6 ファイル・直接依存 3 個という規模とセットで読んでください。

## 測定環境

| 項目 | 値 |
|---|---|
| OS | Darwin 25.6.0 |
| アーキテクチャ | arm64 |
| Java | openjdk version "25.0.4" 2026-07-21 LTS |
| Maven | Apache Maven 3.9.16 (2bdd9fddda4b155ebf8000e807eb73fd829a51d5) |
| Spring Boot（出発点）| **3.5.16**（3.5 系 GA 最新）|
| Spring Boot（到達点）| **4.1.1**（4 系 GA 最新）|

## 波の内容（累積・公式移行ガイドの節に対応）

| 波 | 当てた修正 | 対応する節 |
|---|---|---|
| W0 | なし（出発点のまま）| — |
| W1 | 親を 4.1.1 へ上げる | §Upgrade to Spring Boot 4 |
| W2 | W1 + Jackson 3 へ移す（`com.fasterxml.jackson` → `tools.jackson`・`throws` を落とす）| §Upgrading Jackson |
| W3 | W2 + テストを移す（`@MockBean` → `@MockitoBean`・`@WebMvcTest` のパッケージ移動）| §Upgrading Testing Features |

## 実測

| アーム / 波 | N1（止まる）| N2（警告どまり）| ビルド | テスト |
|---|---:|---:|:--:|---:|
| base W0（3.5.16）| 0 | **1** | 緑 | 2 |
| naive W1 | **4** | 0 | 赤 | 0 |
| naive W2 | **4** | 0 | 赤 | 0 |
| naive W3 | 0 | 0 | **緑** | 2 |
| classic W1 | **4** | 0 | 赤 | 0 |
| classic W2 | **4** | 0 | 赤 | 0 |
| classic W3 | 0 | 0 | **緑** | 2 |

**緑になった波**: naive = `w3` / classic = `w3`

### 壊れた箇所（一意の「ファイル:行」）

| アーム / 波 | 箇所 |
|---|---|
| naive W1 | `TaskController.java:22` / `TaskController.java:35` / `TaskController.java:8` / `TaskController.java:9` |
| naive W2 | `TaskControllerTest.java:25` / `TaskControllerTest.java:31` / `TaskControllerTest.java:7` / `TaskControllerTest.java:8` |
| classic W1 | `TaskController.java:22` / `TaskController.java:35` / `TaskController.java:8` / `TaskController.java:9` |
| classic W2 | `TaskControllerTest.java:25` / `TaskControllerTest.java:31` / `TaskControllerTest.java:7` / `TaskControllerTest.java:8` |

### W0 の N2 = 1 の中身

`TaskControllerTest.java:31` —— `org.springframework.boot.test.mock.mockito.MockBean` が
`has been deprecated and marked for removal` として警告に出ています。
**4 系で削除されるものが、3.5.16 の時点ですでに見えている**ことになります。
出所は `results/001-migration-3x-to-4x/run.log` の `base / w0` 区間です。

## 🔴 測って分かった、想定と違ったこと

**classic starters は、この題材では 1 件も減らしませんでした。**naive と classic は
W1 / W2 / W3 のすべてで N1 が一致し、緑になる波も同じ `w3` でした。

理由は特定できています。classic starters が戻すのは**クラスパスに乗るモジュール**であって、
**移動したパッケージ名や削除された API ではない**ためです。本題材の破損は
Jackson の groupId 変更・パッケージ移動・API 削除の 3 種で、**いずれも classic の守備範囲外**でした。

⚠️ **これは「classic が役に立たない」という意味ではありません。**本題材が classic の効く
破損（モジュール分離による「依存が足りない」型）を含んでいなかった、というのが正確な言い方です。

## 主張の範囲

- 本書の件数は**この題材アプリ 1 つ**の実測です。他のプロジェクトで同じ件数になるとは言えません
- **波の数（3）と順序**は題材に依存します。破損の種類が違えば波の内訳も変わります
- **測っていないもの**: 実行時の挙動（本測定はビルドとテストの通過までです）／ Gradle での移行 ／ Kotlin での移行 ／ Kafka・Batch など本題材が使っていない領域

```json
{
  "before_version": "3.5.16",
  "after_version": "4.1.1",
  "source_files": 6,
  "direct_dependencies": 3,
  "base_w0_n1": 0,
  "base_w0_n2": 1,
  "base_w0_build_success": true,
  "base_w0_tests_run": 2,
  "naive_w1_n1": 4,
  "naive_w1_n2": 0,
  "naive_w1_build_success": false,
  "naive_w1_tests_run": 0,
  "naive_w2_n1": 4,
  "naive_w2_n2": 0,
  "naive_w2_build_success": false,
  "naive_w2_tests_run": 0,
  "naive_w3_n1": 0,
  "naive_w3_n2": 0,
  "naive_w3_build_success": true,
  "naive_w3_tests_run": 2,
  "classic_w1_n1": 4,
  "classic_w1_n2": 0,
  "classic_w1_build_success": false,
  "classic_w1_tests_run": 0,
  "classic_w2_n1": 4,
  "classic_w2_n2": 0,
  "classic_w2_build_success": false,
  "classic_w2_tests_run": 0,
  "classic_w3_n1": 0,
  "classic_w3_n2": 0,
  "classic_w3_build_success": true,
  "classic_w3_tests_run": 2,
  "naive_green_at": "w3",
  "classic_green_at": "w3"
}
```

# 001-migration-3x-to-4x

Spring Boot **3.5.16 → 4.1.1** の移行で、**直しては再ビルドする波ごとに**何が止まり、何が警告どまりかを数えます。

## 何を測るか

| 記号 | 定義 |
|---|---|
| **N1** | コンパイルを止めた一意の「ファイル:行」の数。**直さないと先へ進めない** |
| **N2** | 非推奨警告の一意の「ファイル:行」の数。**ビルドは通る** |

🔴 **N1 と N2 は合算しません。**片方だけでは移行コストを表せないためです。

## なぜ波で測るか

1 回のビルドで出る件数は**原理的に過少**です。main のコンパイルで止まると、テストコードの破損に到達しません。実際の移行と同じく、直しては次を出す形で数えます。

| 波 | 当てる修正 | 対応する節（Spring Boot 4.0 Migration Guide）|
|---|---|---|
| W0 | なし（出発点）| — |
| W1 | 親を 4.1.1 へ上げる | §Upgrade to Spring Boot 4 |
| W2 | W1 + Jackson 3 へ移す | §Upgrading Jackson |
| W3 | W2 + テストを移す | §Upgrading Testing Features |

## アーム

| アーム | 内容 |
|---|---|
| **naive** | 親の版だけを上げる |
| **classic** | 公式 §Migration Strategy が勧める中間状態（`spring-boot-starter-classic` / `spring-boot-starter-test-classic`）を最初から入れる |

## 出発点を 3.5.16 にした理由

移行ガイド §Before You Start が **"make sure to upgrade to the latest available `3.5.x` version"** と明示しているためです。3.5 系の GA 最新を実測で確認して選んでいます。

## 構成

```
scenarios/001-migration-3x-to-4x/
├── README.md
├── run.sh          # モード: M1
├── expected.md     # 記事に載せる値の出典
├── apply-wave.py   # アーム × 波の書き換え
├── tally.py        # ログから N1 / N2 を数える
└── app/            # 🔴 ソースは 1 部だけ
```

🔴 **ソースを 1 部しか持たないのは意図です。**`before` / `after` を 2 部持つと、片方だけ直したときにソースが黙ってずれ、「同じソースで版だけ違う」という前提が壊れても何も検出できません。アームと波は `/tmp` のコピーに対して作ります。

🔴 **本プロジェクトはルートの集約 POM から外してあります。**ルートの親は 4.1.1 で、ここは出発点の 3.5 系を保つ必要があるためです。

## 実行

```bash
bash scenarios/001-migration-3x-to-4x/run.sh
bash scenarios/001-migration-3x-to-4x/run.sh --out /tmp/x
```

Maven Central への到達が要ります（3.5 系と 4 系の両方の依存を取得するため）。

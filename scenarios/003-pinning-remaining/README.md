# 003-pinning-remaining

仮想スレッドがキャリアスレッドを手放せなくなる経路が、**JDK 25 で何件・どんな理由で記録されるか**を測ります。

## 何を確かめるシナリオか

JEP 491（JDK 24）は `synchronized` による pinning を解消しました。ただし同 JEP は **Future Work** に、
`synchronized` とは無関係に残る 3 つの経路を書いています。クラスのロード中にブロックする場合、
クラス初期化子の中でブロックする場合、他スレッドによる初期化を待つ場合です。

本シナリオは、その残る経路が **JFR の既定設定で見えるのか**を測ります。

## 実行

```bash
bash scenarios/003-pinning-remaining/run.sh
```

JDK 25 と JDK 21 の場所は環境変数で差し替えられます。

```bash
JAVA25_HOME=/path/to/jdk25 JAVA21_HOME=/path/to/jdk21 bash scenarios/003-pinning-remaining/run.sh
```

JDK 21 が見つからない場合、対照はスキップして JDK 25 のぶんだけ測ります（該当値は `-1` になります）。

## アーム（3 つ）

| アーム | 中身 | なぜ置くか |
|---|---|---|
| `noop` | 待ち合わせるだけで何もしない | **対照**。ハーネス自身が出すイベントを数える |
| `sync` | `synchronized` ブロックの中で 100 ms ブロックする | JEP 491 が解消したと述べる経路 |
| `clinit` | クラス初期化子の中で 100 ms ブロックし、他の 7 スレッドがその初期化を待つ | JEP 491 Future Work の 2 つ目と 3 つ目 |

## 閾値を 2 段で録る理由

`jdk.VirtualThreadPinned` は**既定で有効・閾値 20 ms**です。既定のまま録ると、20 ms より短い pin は
1 件も現れません。**「0 件」が題材の性質なのか閾値の結果なのかを分けるため**、既定（20 ms）と 0 ms の
両方で録ります。

## 出力

- `results/003-pinning-remaining/run.log` —— 生ログ（アームごとの件数・理由の内訳・代表スタック）
- `results/003-pinning-remaining/summary.json` —— 実効値
- `scenarios/003-pinning-remaining/expected.md` —— **記事に載せる値の正本**

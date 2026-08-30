# 003-pool-sizing

仮想スレッドを有効にした Spring Boot アプリで、**コネクションプールのサイズを振ると
スループットと待ち時間がどう動くか**を測ります。あわせて、その間に pinning が何件記録されるかも数えます。

## 何を確かめるシナリオか

`synchronized` による pinning が解消されたあと、同時実行の上限を決めるのは何か——という問いです。
仮想スレッドは何万本でも作れますが、データベースへの接続はプールのサイズが上限になります。

HikariCP の公式 wiki は `connections = ((core_count * 2) + effective_spindle_count)` という式と、
「小さいプールのほうが速い」という主張を持っています。**その主張が仮想スレッドの下でも成り立つか**を測ります。

## 実行

```bash
bash scenarios/003-pool-sizing/run.sh
```

Docker が要ります。PostgreSQL のコンテナを立てて、終了時に消します。

```bash
bash scenarios/003-pool-sizing/run.sh --rounds 1 --duration-sec 4 --out /tmp/x
```

## 負荷を 2 種類かける理由

| 負荷 | 中身 | なぜ置くか |
|---|---|---|
| **待つ問い合わせ** | `SELECT 1 FROM pg_sleep(0.05)` | データベース側で CPU を使わない。プール待ちだけを取り出す |
| **CPU を使う問い合わせ** | `SELECT count(*) FROM generate_series(1, 100000) s WHERE md5(s::text) < 'f'` | 実運用の問い合わせは CPU を使う。**待つだけの負荷では「プールは大きいほどよい」という結論しか出ない** |

片方だけ測ると、公式が言う「小さいプールのほうが速い」を検算できません。

## 測り方

- 同時実行数を **64 に固定**し、プールサイズだけを 2 / 4 / 8 / 16 / 32 / 64 と振ります
- **プールを十分大きくした腕（64）も置きます。**「プールが制約になる」と決めて測ると、効かない条件を測らないことになります
- 1 ラウンド = 全プールサイズ。ラウンドロビンで機体の状態を各条件へ均等に乗せます
- 計測中は JFR を**既定設定**（`jdk.VirtualThreadPinned` は閾値 20 ms）で録ります。読者が実際に使う設定で何件出るかを見るためです

## 出力

- `results/003-pool-sizing/run.log` —— 生ログ
- `results/003-pool-sizing/summary.json` —— 実効値
- `scenarios/003-pool-sizing/expected.md` —— **記事に載せる値の正本**

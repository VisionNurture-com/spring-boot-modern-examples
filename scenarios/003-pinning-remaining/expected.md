# expected: 003-pinning-remaining

> 🔴 **記事に載せる値は本書からしか引きません。**本書の値は `results/003-pinning-remaining/summary.json` と
> `tools/check-provenance.py` で機械照合されます。食い違えば CI（M0）が落ちます。

## 何を測ったか

| 項目 | 内容 |
|---|---|
| シナリオ | `003-pinning-remaining` |
| モード | M1（JDK 25 + JDK 21。**Maven も Docker も不要**） |
| 測ったもの | 仮想スレッドがキャリアスレッドを手放せなくなる経路の**件数**と**理由** |
| アーム | `noop`（対照）／ `sync`（synchronized の中でブロック）／ `clinit`（クラス初期化子の中でブロック + 他スレッドの初期化待ち） |
| 閾値 | **既定 20 ms** と **0 ms** の 2 段 |
| スレッド数 | 8（うち 1 本が初期化子を走らせ、7 本が待つ） |
| ブロック時間 | 100 ms |
| セット数 | **5 セット**・**中央値**で比較 |
| 再現手順 | `bash scenarios/003-pinning-remaining/run.sh` |

## 測定環境

| 項目 | 値 |
|---|---|
| OS | Darwin 25.6.0 |
| アーキテクチャ | arm64 |
| Java（対象） | openjdk version 25.0.4 2026-07-21 LTS（Temurin 25.0.4+7） |
| Java（対照） | openjdk version 21.0.12.1 2026-08-18 LTS（Temurin 21.0.12.1+1） |

## 結果 1: 既定の閾値（20 ms）で録ると何件出るか

| アーム | JDK 25 | JDK 21 |
|---|---:|---:|
| `noop`（対照） | **0 件** | **0 件** |
| `sync` | **0 件** | **8 件** |
| `clinit` | **8 件** | **1 件** |

**5 セットすべてで同じ値が出ました**（最小 = 最大）。この 3 行は再現します。

### 読み方

- **`sync` は JDK 21 で 8 件・JDK 25 で 0 件。**JEP 491 が効いていることを、対照つきで確認できます
- 🔴 **`clinit` は JDK 25 のほうが多く出ます（1 件 → 8 件）。**pinning が増えたのではなく、**イベントが拾う範囲が広がった**ためです。JEP 491 は "we will retain it for other pinning situations" と述べ、イベント自体を拡張しています
- **JDK 21 の `clinit` で出る 1 件**は初期化子を走らせているスレッドのぶんだけです。**待っている 7 本は JDK 21 のイベントに現れません**

## 結果 2: `clinit` の 8 件は何だったか（JDK 25・既定閾値）

| 理由（`pinnedReason`） | ブロック操作 | 件数 | 継続時間（参考） |
|---|---|---:|---|
| `VM call to PinDemo$SlowInit.<clinit> on stack` | `LockSupport.park` | **1 件** | 110 ms |
| `Waited for initialization of PinDemo$SlowInit by another thread` | `Object.wait` | **7 件** | 110 ms |

> 🔴 **継続時間は最終セット 1 回の観測値**で、5 セットの中央値ではありません。**JSON ブロックの外にあるため `check-provenance.py` の突合対象でもありません。**
> 記事にはこの列を載せていません（2026-08-28 訂正。旧版は **103 ms** と書いていましたが、それは `j21_clinit_default` の値で、JDK 25 側の実測は `run.log` のとおり 110 ms です）。

**JEP 491 §Future Work の 2 つ目と 3 つ目が、そのままイベントの理由として出ます。**

## 結果 3: 閾値を 0 ms にすると何が起きるか

| アーム | 中央値 | 最小 | 最大 |
|---|---:|---:|---:|
| `noop`（対照） | **5 件** | 0 | 11 |
| `sync` | **14 件** | 5 | 15 |
| `clinit` | **21 件** | 12 | 26 |

🔴 **この 3 行は再現しません。**セットごとに大きく振れます。理由は、**待ち合わせのハーネス自身が pin を出す**ためです。
`noop`（何もしないアーム）でも件数が出ることが、その証拠です。生ログの内訳では次の形が並びます。

```text
pinnedReason = "Freeze or preempt failed (2)"
blockingOperation = "Contended monitor enter"
duration = 0.00125 ms
stackTrace = [
  java.util.concurrent.locks.AbstractQueuedSynchronizer.tryInitializeHead() line: 592
  ...
  java.util.concurrent.CountDownLatch.await() line: 230
```

**マイクロ秒の pin で、題材ではなく `CountDownLatch` の待ち合わせに由来します。**

## 記事が主張してよい範囲 / よくない範囲

| 主張 | 可否 |
|---|---|
| 既定の閾値（20 ms）では `synchronized` 経路が JDK 25 で 0 件・JDK 21 で 8 件だった | ✅ 5 セットとも一致 |
| 既定の閾値でもクラス初期化子の経路は JDK 25 で 8 件出た | ✅ 5 セットとも一致 |
| その 8 件の内訳は「初期化子の中で 1 件」「他スレッドの初期化待ちで 7 件」だった | ✅ |
| JDK 21 では同じ題材で 1 件しか出ない（イベントの守備範囲が違う） | ✅ 5 セットとも一致 |
| **閾値を 0 ms にすると件数が増える** | ✅ ただし**再現しない値**として書く |
| **閾値 0 ms の件数そのもの（5 件 / 14 件 / 21 件）** | ⚠️ **中央値であり再現しません。**必ず対照（`noop`）と併記する |
| **閾値 0 ms で出る件数は pinning の実害を表す** | ❌ 大半がハーネス由来のマイクロ秒 pin です |
| **JDK 25 は JDK 21 より pinning が多い** | ❌ 逆です。**イベントが拾う範囲が広がった**だけで、pin が増えたわけではありません |
| **クラス初期化子の pin は実運用で必ず問題になる** | ❌ 測っていません。JEP 491 自身が "These cases should rarely cause issues" と書いています |
| **この件数がどのアプリでも出る** | ❌ 題材固有です |

## 機械照合用（`tools/check-provenance.py` が読む）

```json
{
  "threads": 8,
  "block_ms": 100,
  "sets": 5,
  "default_threshold_ms": 20,
  "j25_noop_default": 0,
  "j25_sync_default": 0,
  "j25_clinit_default": 8,
  "j25_noop_zero": 5,
  "j25_noop_zero_min": 0,
  "j25_noop_zero_max": 11,
  "j25_sync_zero": 14,
  "j25_sync_zero_min": 5,
  "j25_sync_zero_max": 15,
  "j25_clinit_zero": 21,
  "j25_clinit_zero_min": 12,
  "j25_clinit_zero_max": 26,
  "j21_noop_default": 0,
  "j21_sync_default": 8,
  "j21_clinit_default": 1,
  "j25_clinit_reason_in_clinit": 1,
  "j25_clinit_reason_waited": 7
}
```

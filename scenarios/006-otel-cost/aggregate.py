#!/usr/bin/env python3
"""006-otel-cost の集計。

measurements/ に貯めた 1 ラウンド 1 ファイルの生値から中央値を取り、
対照（計装なし）との比を出して summary.json を書く。

記事に載せる値はここで作った summary.json と expected.md の突合を通ったものだけである。
"""
import glob
import json
import os
import platform
import statistics
import subprocess
import sys

APP_ARMS = ["A0_plain", "A1_p000", "A2_p001", "A3_default", "A4_p050", "A5_p100"]
# n 感度チェック（記事 006 の実機確認で追加）。同じ /work 経路で n だけを 1 段変え、
# 「計装ありと計装なしの比」が n でどう動くかを見る。素のアプリが n でどう動くかは
# 002 が既測（計算量 10 倍でスループット -5.4%）なので、ここでは測り直さない。
NSENS_ARMS = ["A0_plain", "A3_default", "A5_p100"]
NSENS_DIRNAME = "006-otel-cost-nsens"
DB_ARMS = ["B0_plain", "B1_default", "B2_p100"]
JARS = ["app-plain", "app-otel", "appdb-plain", "appdb-otel"]


def _rel(p):
    # 出力先はリポジトリからの相対で見せる（生ログに実行環境の絶対パスを残さない）
    i = p.find("/results/")
    return p[i + 1:] if i >= 0 else p


def median_of(out, arm, key):
    vals = []
    for f in sorted(glob.glob(os.path.join(out, "measurements", f"{arm}_*.json"))):
        if os.path.basename(f).startswith(("C1_before", "C1_after")):
            continue
        vals.append(json.load(open(f))[key])
    return statistics.median(vals) if vals else None


def main():
    out, rounds, warmup, duration, conc, app_n, db_n, col_img, pg_img = sys.argv[1:10]
    v = {
        "rounds": int(rounds), "warmup_sec": int(warmup), "duration_sec": int(duration),
        "concurrency": int(conc), "app_n": int(app_n), "db_n": int(db_n),
        "collector_image": col_img, "postgres_image": pg_img,
    }
    lines = []

    # jar のサイズ（計装を足すと jar が何バイト増えるか）
    for k in JARS:
        p = os.path.join(out, "work", f"006-{k}.jar")
        if os.path.isfile(p):
            v[f"jar_{k.replace('-', '_')}_bytes"] = os.path.getsize(p)
    if "jar_app_plain_bytes" in v and "jar_app_otel_bytes" in v:
        v["jar_app_delta_bytes"] = v["jar_app_otel_bytes"] - v["jar_app_plain_bytes"]
        v["jar_app_delta_pct"] = round(v["jar_app_delta_bytes"] / v["jar_app_plain_bytes"] * 100, 1)
    if "jar_appdb_plain_bytes" in v and "jar_appdb_otel_bytes" in v:
        v["jar_appdb_delta_bytes"] = v["jar_appdb_otel_bytes"] - v["jar_appdb_plain_bytes"]

    # 検算パス: リクエスト 100 回あたりの受信スパン
    for arm in APP_ARMS + DB_ARMS:
        p = os.path.join(out, "spans", f"{arm}.count")
        if os.path.isfile(p):
            v[f"spans_{arm}_per100"] = int(open(p).read().strip())

    # 各腕の実測（中央値）
    for arm in APP_ARMS + DB_ARMS:
        got = False
        for key, dst, nd in (("throughput_rps", "throughput_rps", 1), ("p50_ms", "p50_ms", 2),
                             ("p95_ms", "p95_ms", 2), ("p99_ms", "p99_ms", 2),
                             ("cpu_sec", "cpu_sec", 2), ("rss_max_kb", "rss_max_kb", 0)):
            m = median_of(out, arm, key)
            if m is None:
                continue
            got = True
            v[f"{arm}_{dst}"] = round(m, nd) if nd else int(m)
        if got:
            errs = 0
            for f in sorted(glob.glob(os.path.join(out, "measurements", f"{arm}_*.json"))):
                errs += json.load(open(f))["errors"]
            v[f"{arm}_errors"] = errs
            # 🔴 CPU 秒をそのまま腕どうしで比べない。腕によってさばいたリクエスト数が
            #    2 桁違うため、1 リクエストあたりへ正規化してから比べる。
            reqs = median_of(out, arm, "requests")
            if reqs:
                v[f"{arm}_requests"] = int(reqs)
                v[f"{arm}_cpu_us_per_req"] = round(v[f"{arm}_cpu_sec"] / reqs * 1e6, 2)
            lines.append(
                f"{arm:11s} {v.get(arm+'_throughput_rps', 0):8.1f} rps  "
                f"p50 {v.get(arm+'_p50_ms', 0):6.2f}  p95 {v.get(arm+'_p95_ms', 0):7.2f}  "
                f"p99 {v.get(arm+'_p99_ms', 0):7.2f} ms  cpu {v.get(arm+'_cpu_sec', 0):6.2f} s  "
                f"rss {v.get(arm+'_rss_max_kb', 0):8d} KB  err {errs}")

    # 対照との比（app は A0、app-db は B0）
    for arms, base in ((APP_ARMS, "A0_plain"), (DB_ARMS, "B0_plain")):
        if f"{base}_p99_ms" not in v:
            continue
        for arm in arms:
            if arm == base or f"{arm}_p99_ms" not in v:
                continue
            for key in ("p99_ms", "p95_ms", "p50_ms", "throughput_rps", "cpu_sec",
                        "cpu_us_per_req", "rss_max_kb"):
                b, a = v[f"{base}_{key}"], v[f"{arm}_{key}"]
                if b:
                    v[f"{arm}_{key}_vs_control_pct"] = round((a - b) / b * 100, 1)

    if lines:
        lines.append("")
        for arms, base in ((APP_ARMS, "A0_plain"), (DB_ARMS, "B0_plain")):
            for arm in arms:
                k = f"{arm}_p99_ms_vs_control_pct"
                if k in v:
                    lines.append(
                        f"{arm:11s} 対 {base}: p99 {v[k]:+.1f}%  "
                        f"スループット {v[arm+'_throughput_rps_vs_control_pct']:+.1f}%  "
                        f"CPU {v[arm+'_cpu_sec_vs_control_pct']:+.1f}%  "
                        f"RSS {v[arm+'_rss_max_kb_vs_control_pct']:+.1f}%")

    # n 感度チェック（別 out の測定を読み、比だけを summary へ載せる）
    nsens_out = os.path.join(os.path.dirname(os.path.abspath(out)), NSENS_DIRNAME)
    if os.path.isdir(os.path.join(nsens_out, "measurements")):
        ns = {}
        for arm in NSENS_ARMS:
            cpu = median_of(nsens_out, arm, "cpu_sec")
            reqs = median_of(nsens_out, arm, "requests")
            rps = median_of(nsens_out, arm, "throughput_rps")
            if cpu is None or not reqs:
                continue
            ns[arm] = {"cpu_us": round(cpu / reqs * 1e6, 2), "rps": round(rps, 1)}
        if len(ns) == len(NSENS_ARMS):
            n0 = json.load(open(sorted(glob.glob(os.path.join(
                nsens_out, "measurements", "A0_plain_*.json")))[0]))
            v["nsens_app_n"] = int(n0["url"].rsplit("n=", 1)[1])
            base = ns["A0_plain"]
            v["nsens_A0_plain_cpu_us_per_req"] = base["cpu_us"]
            for arm in NSENS_ARMS:
                v[f"nsens_{arm}_cpu_us_per_req"] = ns[arm]["cpu_us"]
                v[f"nsens_{arm}_throughput_rps"] = ns[arm]["rps"]
                if arm != "A0_plain":
                    v[f"nsens_{arm}_cpu_us_per_req_vs_control_pct"] = round(
                        (ns[arm]["cpu_us"] - base["cpu_us"]) / base["cpu_us"] * 100, 1)
                    v[f"nsens_{arm}_throughput_rps_vs_control_pct"] = round(
                        (ns[arm]["rps"] - base["rps"]) / base["rps"] * 100, 1)
            lines.append("")
            lines.append(f"n 感度（n={v['nsens_app_n']}・A0/A3/A5 のみ）")
            for arm in NSENS_ARMS[1:]:
                lines.append(
                    f"{arm:11s} 対 A0_plain: CPU/req "
                    f"{v[f'nsens_{arm}_cpu_us_per_req_vs_control_pct']:+.1f}%  "
                    f"スループット {v[f'nsens_{arm}_throughput_rps_vs_control_pct']:+.1f}%")

    # キュー溢れの検算（送信先は生かしたまま）
    # 🔴 単発では出ない。溢れるかどうかはラウンドで割れるため、全ラウンドを列挙して残す。
    for rate in ("1.0", "0.5", "0.1", "0.01"):
        key = rate.replace(".", "")
        drops, reqs_all = [], []
        for d in sorted(glob.glob(os.path.join(out, "spans", f"queue_dropped_{rate}_r*.count"))):
            drops.append(int(open(d).read().strip()))
        for r in sorted(glob.glob(os.path.join(out, "spans", f"queue_requests_{rate}_r*.count"))):
            reqs_all.append(int(open(r).read().strip()))
        if drops:
            v[f"queue_rounds_p{key}"] = len(drops)
            v[f"queue_dropped_max_p{key}"] = max(drops)
            v[f"queue_dropped_rounds_with_drop_p{key}"] = sum(1 for x in drops if x > 0)
            v[f"queue_dropped_each_p{key}"] = ",".join(str(x) for x in drops)
        if reqs_all:
            v[f"queue_requests_median_p{key}"] = int(statistics.median(reqs_all))

    # C1: コレクタ停止の前後
    for tag in ("before", "after"):
        p = os.path.join(out, "measurements", f"C1_{tag}_1.json")
        if os.path.isfile(p):
            d = json.load(open(p))
            v[f"c1_{tag}_throughput_rps"] = round(d["throughput_rps"], 1)
            v[f"c1_{tag}_p99_ms"] = round(d["p99_ms"], 2)
            v[f"c1_{tag}_errors"] = d["errors"]
    for name, key in (("C1_dropped_spans", "c1_dropped_spans"),
                      ("C1_export_error_lines", "c1_export_error_lines")):
        p2 = os.path.join(out, "spans", f"{name}.count")
        if os.path.isfile(p2):
            v[key] = int(open(p2).read().strip())
    if "c1_before_p99_ms" in v and "c1_after_p99_ms" in v:
        v["c1_p99_delta_pct"] = round(
            (v["c1_after_p99_ms"] - v["c1_before_p99_ms"]) / v["c1_before_p99_ms"] * 100, 1)
        lines.append("")
        lines.append(f"C1 停止前: {v['c1_before_throughput_rps']} rps / p99 {v['c1_before_p99_ms']} ms / err {v['c1_before_errors']}")
        lines.append(f"C1 停止後: {v['c1_after_throughput_rps']} rps / p99 {v['c1_after_p99_ms']} ms / err {v['c1_after_errors']}  (p99 {v['c1_p99_delta_pct']:+.1f}%)")

    print("\n".join(lines))

    summary = {
        "scenario": "006-otel-cost",
        "mode": "M2",
        "measures": "計装のコスト（サンプリング率別のレイテンシ・スループット・CPU・メモリ）",
        "env": {
            "os": f"{platform.system()} {platform.release()}",
            "arch": platform.machine(),
            "java": subprocess.run(["java", "-version"], capture_output=True, text=True).stderr.splitlines()[0],
        },
        "values": v,
    }
    with open(os.path.join(out, "summary.json"), "w") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"\nsummary: {_rel(os.path.join(out, 'summary.json'))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""各腕 × 波のビルドログから N1 / N2 を数え、summary.json を書く。

判定は生ログの [ERROR] / [WARNING] 行から機械的に行う。
メッセージ文の一致では判定しない（文言は実装が差し替えるため）。

使い方: tally.py <work> <out> <scenario> <before_version> <after_version>
"""
import json
import pathlib
import platform
import re
import subprocess
import sys

LOC = re.compile(r"([^ \[\]]+\.java):\[(\d+),(\d+)\]")
TOTAL = re.compile(r"^\[INFO\] Tests run: (\d+), Failures: (\d+), Errors: (\d+), Skipped: (\d+)\s*$")
ARMS = [("base", "w0"), ("naive", "w1"), ("naive", "w2"), ("naive", "w3"),
        ("classic", "w1"), ("classic", "w2"), ("classic", "w3")]


def count(log_path: pathlib.Path) -> dict:
    text = log_path.read_text(encoding="utf-8", errors="replace")
    errs: set[str] = set()
    deps: set[str] = set()
    tests = 0
    for line in text.splitlines():
        m = LOC.search(line)
        if line.startswith("[ERROR]") and m:
            errs.add(f"{pathlib.Path(m.group(1)).name}:{m.group(2)}")
        elif line.startswith("[WARNING]") and m and ("deprecat" in line or "非推奨" in line):
            deps.add(f"{pathlib.Path(m.group(1)).name}:{m.group(2)}")
        t = TOTAL.match(line)
        if t:
            # 合計行（"-- in <クラス>" が付かない行）だけを採る。
            # クラスごとの行を先に拾うと総数を取り違える（2026-08-29 に実際に踏んだ）。
            tests = int(t.group(1))
    return {
        "n1": len(errs), "n1_locations": sorted(errs),
        "n2": len(deps), "n2_locations": sorted(deps),
        "build_success": "BUILD SUCCESS" in text,
        "tests_run": tests,
    }


def main() -> int:
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        return 3
    work, out, scenario, before_v, after_v = (pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]),
                                              sys.argv[3], sys.argv[4], sys.argv[5])
    res = {f"{t}-{w}": count(work / f"{t}-{w}.build.log") for t, w in ARMS}
    java_v = subprocess.run(["java", "-version"], capture_output=True, text=True).stderr.splitlines()[0]
    # 🔴 Maven の版も記録する。記事の動作検証環境の表に載る値であり、
    #    載せる版は測ったものでなければならない。
    mvn_v = subprocess.run(["mvn", "-v"], capture_output=True, text=True).stdout.splitlines()[0]

    values = {
        "before_version": before_v,
        "after_version": after_v,
        "source_files": 6,
        "direct_dependencies": 3,
    }
    for key, r in res.items():
        k = key.replace("-", "_")
        values[f"{k}_n1"] = r["n1"]
        values[f"{k}_n2"] = r["n2"]
        values[f"{k}_build_success"] = r["build_success"]
        values[f"{k}_tests_run"] = r["tests_run"]

    # 何波目で緑になったか。到達しなければ null。
    for track in ("naive", "classic"):
        green = next((w for w in ("w1", "w2", "w3") if res[f"{track}-{w}"]["build_success"]), None)
        values[f"{track}_green_at"] = green

    summary = {
        "scenario": scenario,
        "mode": "M1",
        "measures": ("3.5.16 から 4.1.1 へ上げる過程で、直しては再ビルドする波ごとに "
                     "ビルドを止める箇所（N1）と非推奨警告どまりの箇所（N2）が何件出るか。"
                     "素直に上げる道と公式の classic starters を使う道を比べる"),
        "env": {
            "os": f"{platform.system()} {platform.release()}",
            "arch": platform.machine(),
            "java": java_v,
            "maven": mvn_v,
        },
        "values": values,
        "detail": {k: {"n1_locations": r["n1_locations"], "n2_locations": r["n2_locations"]}
                   for k, r in res.items()},
    }
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
                                      encoding="utf-8")

    print("=" * 42)
    print("結果")
    print("=" * 42)
    for key, r in res.items():
        mark = "緑" if r["build_success"] else "赤"
        print(f"  {key:12} N1={r['n1']:3}  N2={r['n2']:3}  {mark}  tests={r['tests_run']}")
        for loc in r["n1_locations"]:
            print(f"      [N1] {loc}")
        for loc in r["n2_locations"]:
            print(f"      [N2] {loc}")
    print()
    for track in ("naive", "classic"):
        print(f"  {track} が緑になった波: {values[f'{track}_green_at'] or '（3 波では到達せず）'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

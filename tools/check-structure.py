#!/usr/bin/env python3
"""M0: 構造検査。

各シナリオが必要なファイルを持ち、モード宣言があることを確かめる。
Docker もネットワークも要らない。CI で常に回す。

終了コード: 0 = PASS / 1 = FAIL / 3 = 使い方エラー
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODES = {"M0", "M1", "M2", "M3"}
REQUIRED = ["README.md", "run.sh", "expected.md"]

def main() -> int:
    scen_dir = ROOT / "scenarios"
    if not scen_dir.is_dir():
        print("🔴 scenarios/ がありません", file=sys.stderr)
        return 3

    scenarios = sorted(p for p in scen_dir.iterdir() if p.is_dir())
    if not scenarios:
        print("🔴 シナリオが 1 つもありません", file=sys.stderr)
        return 1

    fails = []
    for s in scenarios:
        sid = s.name
        for f in REQUIRED:
            if not (s / f).is_file():
                fails.append(f"{sid}: {f} がありません")

        run = s / "run.sh"
        if run.is_file():
            text = run.read_text()
            m = re.search(r"^#\s*モード:\s*(M[0-3])", text, re.M)
            if not m:
                fails.append(f"{sid}: run.sh にモード宣言（# モード: M0〜M3）がありません")
            elif m.group(1) not in MODES:
                fails.append(f"{sid}: run.sh のモード宣言が不正です（{m.group(1)}）")
            if not (run.stat().st_mode & 0o111):
                fails.append(f"{sid}: run.sh に実行権限がありません")

        res = ROOT / "results" / sid
        if not (res / "summary.json").is_file():
            fails.append(f"{sid}: results/{sid}/summary.json がありません")
        if not (res / "run.log").is_file():
            fails.append(f"{sid}: results/{sid}/run.log がありません")

    print("=" * 42)
    print("check-structure（M0・構造検査）")
    print("=" * 42)
    for s in scenarios:
        mark = "🔴" if any(f.startswith(s.name + ":") for f in fails) else "✅"
        print(f"  {mark} {s.name}")
    if fails:
        print("\n--- FAIL ---")
        for f in fails:
            print(f"  🔴 {f}")
    print("=" * 42)
    print(f"サマリー: シナリオ {len(scenarios)} / FAIL {len(fails)}")
    print("=" * 42)
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""M0: provenance 突合。

scenarios/<id>/expected.md の末尾 json ブロックと
results/<id>/summary.json の values を突き合わせる。

記事に載せる値は expected.md からしか引かない。expected.md が実測ログと
食い違ったまま記事へ流れる経路を、ここで塞ぐ。

終了コード: 0 = PASS / 1 = FAIL / 3 = 使い方エラー
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FENCE = re.compile(r"```json\s*\n(.*?)\n```", re.S)

def extract_expected(md: pathlib.Path):
    blocks = FENCE.findall(md.read_text())
    if not blocks:
        return None, "expected.md に ```json ブロックがありません"
    try:
        return json.loads(blocks[-1]), None
    except json.JSONDecodeError as e:
        return None, f"expected.md の json ブロックが不正です: {e}"

def diff(expected: dict, actual: dict):
    out = []
    for k in sorted(set(expected) | set(actual)):
        e, a = expected.get(k, "<なし>"), actual.get(k, "<なし>")
        if e != a:
            out.append(f"{k}: expected={e} / summary={a}")
    return out

def main() -> int:
    scen_dir = ROOT / "scenarios"
    if not scen_dir.is_dir():
        print("🔴 scenarios/ がありません", file=sys.stderr)
        return 3

    scenarios = sorted(p for p in scen_dir.iterdir() if p.is_dir())
    fails = []

    print("=" * 42)
    print("check-provenance（M0・記事に載せる値の突合）")
    print("=" * 42)

    for s in scenarios:
        sid = s.name
        md = s / "expected.md"
        sj = ROOT / "results" / sid / "summary.json"
        if not md.is_file() or not sj.is_file():
            fails.append(f"{sid}: expected.md または summary.json がありません")
            print(f"  🔴 {sid} — ファイル不足")
            continue

        expected, err = extract_expected(md)
        if err:
            fails.append(f"{sid}: {err}")
            print(f"  🔴 {sid} — {err}")
            continue

        try:
            actual = json.loads(sj.read_text()).get("values")
        except json.JSONDecodeError as e:
            fails.append(f"{sid}: summary.json が不正です: {e}")
            print(f"  🔴 {sid} — summary.json が不正")
            continue

        if actual is None:
            fails.append(f"{sid}: summary.json に values がありません")
            print(f"  🔴 {sid} — values なし")
            continue

        d = diff(expected, actual)
        if d:
            for line in d:
                fails.append(f"{sid}: {line}")
            print(f"  🔴 {sid} — 値が {len(d)} 件食い違っています")
            for line in d:
                print(f"      {line}")
        else:
            print(f"  ✅ {sid} — 値 {len(actual)} 件が一致")

    print("=" * 42)
    print(f"サマリー: シナリオ {len(scenarios)} / FAIL {len(fails)}")
    print("=" * 42)
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())

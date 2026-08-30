#!/usr/bin/env python3
"""native-image のビルド出力 JSON と経過時間から、1 ラウンド分の値を作る。

`-H:BuildOutputJSONFile` が出す機械可読な出力だけを値の出所にする。
テキストログの見た目に依存すると、書式が変わったときに黙って空になる。
"""
import json
import os
import sys


def get(d, *path, default=None):
    cur = d
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return default
        cur = cur[k]
    return cur


def main() -> int:
    arm = sys.argv[1]
    elapsed = float(sys.argv[2])
    exit_code = int(sys.argv[3])
    json_path = sys.argv[4]
    binary = sys.argv[5]

    out = {
        "arm": arm,
        "wall_sec": round(elapsed, 3),
        "exit_code": exit_code,
        "binary_exists": os.path.isfile(binary),
        "binary_bytes": os.path.getsize(binary) if os.path.isfile(binary) else 0,
    }

    if os.path.isfile(json_path):
        with open(json_path, encoding="utf-8") as fh:
            b = json.load(fh)
        out["build_output_json"] = True
        out["image_bytes"] = get(b, "image_details", "total_bytes")
        out["total_build_sec"] = get(b, "resource_usage", "total_secs")
        out["peak_rss_bytes"] = get(b, "resource_usage", "memory", "peak_rss_bytes")
        out["system_total_bytes"] = get(b, "resource_usage", "memory", "system_total")
        out["gc_secs"] = get(b, "resource_usage", "garbage_collection", "total_secs")
        out["gc_count"] = get(b, "resource_usage", "garbage_collection", "count")
        out["cpu_load"] = get(b, "resource_usage", "cpu", "load")
        out["reachable_types"] = get(b, "analysis_results", "types", "reachable")
        out["reachable_methods"] = get(b, "analysis_results", "methods", "reachable")
        out["graalvm_version"] = get(b, "general_info", "graalvm_version")
        out["java_version"] = get(b, "general_info", "java_version")
    else:
        out["build_output_json"] = False

    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

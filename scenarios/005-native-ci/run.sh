#!/usr/bin/env bash
# モード: M3（GitHub Actions 上の GraalVM。手元では成立しない）
# 005-native-ci — 測定用パブリックリポジトリでワークフローを回し、結果を取り込む。
#
# 測定は GitHub Actions の上でしか成立しない（runner の資源そのものが測定対象のため）。
# 本スクリプトはワークフローを起動し、成果物を results/005-native-ci/raw/ へ集める。
#
# 使い方:
#   bash scenarios/005-native-ci/run.sh [--rounds N] [--out DIR]
set -euo pipefail

# 測定は PUBLIC リポジトリでしか成立しない（4 vCPU / 16 GB は公開側の標準 runner だけ）。
# 公開サンプル自身が PUBLIC なので、そこへ同居させた measure.yml / measure-oom.yml を回す。
REPO="VisionNurture-com/spring-boot-modern-examples"
ROUNDS=3
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/results/005-native-ci"

# 出力先はリポジトリからの相対で見せる（生ログに実行環境の絶対パスを残さない）
rel() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;; *) printf '%s' "$1" ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rounds) ROUNDS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 3 ;;
  esac
done

command -v gh >/dev/null || { echo "gh が要ります" >&2; exit 3; }

mkdir -p "$OUT/raw"
echo "測定リポジトリ: $REPO / ラウンド数: $ROUNDS"

dispatch_and_wait() {
  local wf="$1"
  gh workflow run "$wf" --repo "$REPO"
  sleep 15
  local id
  id=$(gh api "repos/$REPO/actions/runs" --jq "[.workflow_runs[] | select(.name==\"${wf%.yml}\")][0].id")
  echo "  run=$id"
  while [ "$(gh api "repos/$REPO/actions/runs/$id" --jq .status)" != "completed" ]; do sleep 30; done
  echo "$id"
}

for i in $(seq 1 "$ROUNDS"); do
  echo "[ラウンド $i] measure.yml"
  rid=$(dispatch_and_wait measure.yml | tail -1)
  for a in probe jvm-package native-nocache native-cache; do
    gh run download "$rid" --repo "$REPO" -n "$a" -D "$OUT/raw/round$i-$a" || true
  done
done

for i in $(seq 1 "$ROUNDS"); do
  echo "[ラウンド $i] measure-oom.yml"
  rid=$(dispatch_and_wait measure-oom.yml | tail -1)
  gh run download "$rid" --repo "$REPO" -n native-xmx-limited -D "$OUT/raw/oom-round$i" || true
done

echo "取り込み完了: $(rel "$OUT/raw")"
echo "summary.json は scenarios/005-native-ci/summarize.py で作る"

# 子プロセス（Maven / JVM / Docker）の出力は上の echo を直しても生ログに入るため、
# 書き終えたところで実行環境に固有の情報を落とす（tools/check-neutrality.py が検査する）
python3 "$ROOT/tools/sanitize-log.py" "$OUT"

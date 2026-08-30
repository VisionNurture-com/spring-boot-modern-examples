#!/usr/bin/env bash
# シナリオ: 002-steady-design
# モード: M1（JDK 25 + Maven。GraalVM も Docker も要らない）
# 測るもの: 002-steady-throughput の測定条件（同時実行 8 / 負荷 2 種 / ウォームアップ 8 秒）を
#           なぜその値にしたのか、素の JVM だけで 3 つのスイープを振って確かめる。
#
# 🔴 なぜ別シナリオにしたか
#   002-steady-throughput の expected.md は「感度測定」「飽和の確認」「ウォームアップの妥当性」
#   の 3 表を載せていたが、**どの値も results/ の run.log に出現せず**、機械照合用の
#   json ブロックにも入っていなかった（check-provenance の射程外）。
#   本計測の前に手元で振った探索的な実行の値が、ログを残さないまま手書きされたものである。
#   本シナリオは 3 つとも取り直して results/ にログを残し、突合の射程へ入れる。
#
# スイープ（すべて素の JVM・実行可能 jar のまま）:
#   A. 同時実行   16 / 32 / 64 / 128     n=2,000 固定       → どこで飽和するか
#   B. 計算量     n=2,000 〜 1,000,000   同時実行 8 固定    → どこから計算が律速になるか
#   C. ウォームアップ 2 / 8 / 20 / 40 秒  n=1,000,000 固定  → 8 秒で頭打ちに達しているか
#
# 🔴 C は各点でサーバを起動し直す。
#   同一プロセスで連続実行するとウォームアップが累積し、「2 秒」の点が
#   直前の実行のぶんまで温まった状態になる。独立した比較にするため毎回立て直す。
#
# 出力: results/002-steady-design/run.log と summary.json（--out で変更可）
# 使い方:
#   bash scenarios/002-steady-design/run.sh
#   bash scenarios/002-steady-design/run.sh --duration-sec 5 --out /tmp/x

set -euo pipefail

SCENARIO="002-steady-design"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/results/$SCENARIO"
DURATION=10
WARMUP=8
PORT=18080

while [ $# -gt 0 ]; do
  case "$1" in
    --out)          OUT="$2"; shift 2 ;;
    --duration-sec) DURATION="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 3 ;;
  esac
done

mkdir -p "$OUT"
LOG="$OUT/run.log"
: > "$LOG"
log() { echo "$@" | tee -a "$LOG"; }

log "=== シナリオ: $SCENARIO / モード: M1 ==="
log "実行日時: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log "計測: ${DURATION}s / 既定ウォームアップ: ${WARMUP}s / ポート: ${PORT}"
log ""
log "--- 環境 ---"
log "os: $(uname -s) $(uname -r)"
log "arch: $(uname -m)"
log "cpu: $(sysctl -n hw.ncpu 2>/dev/null || nproc) コア"
log "java: $(java -version 2>&1 | head -1)"
log ""

WORK="$(TMPDIR=/tmp mktemp -d /tmp/sbme-steady-design.XXXXXX)"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

log "--- ビルド（clean を挟む）---"
( cd "$ROOT" && mvn -q -B -pl app -am clean package -DskipTests ) >> "$LOG" 2>&1
JAR="$WORK/app.jar"
cp "$ROOT/app/target/app.jar" "$JAR"
log "jar: $(wc -c < "$JAR" | tr -d ' ') bytes"
log ""

start_server() {
  java -Dserver.port="$PORT" -jar "$JAR" > "$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 80); do
    curl -sf "http://localhost:${PORT}/hello" > /dev/null 2>&1 && return 0
    sleep 0.25
  done
  log "🔴 サーバが起動しませんでした"; tail -15 "$WORK/server.log" | tee -a "$LOG"; return 1
}

stop_server() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
  sleep 1
}

measure() {  # $1=n / $2=concurrency / $3=warmup / $4=ラベル
  local f="$WORK/$4.json"
  java "$ROOT/tools/loadgen/LoadGen.java" \
    --url "http://localhost:${PORT}/work?n=$1" \
    --concurrency "$2" --warmup-sec "$3" --duration-sec "$DURATION" \
    --out "$f" > /dev/null
  local tp p99 err
  tp=$(grep -o '"throughput_rps": [0-9.]*' "$f" | cut -d' ' -f2)
  p99=$(grep -o '"p99_ms": [0-9.]*' "$f" | cut -d' ' -f2)
  err=$(grep -o '"errors": [0-9]*' "$f" | cut -d' ' -f2)
  log "  $4: ${tp} rps / p99 ${p99} ms / エラー ${err} 件"
}

log "--- A. 同時実行スイープ（n=2,000 固定・サーバは 1 度だけ立てる）---"
start_server
for c in 16 32 64 128; do
  measure 2000 "$c" "$WARMUP" "conc${c}"
done
stop_server
log ""

log "--- B. 計算量スイープ（同時実行 8 固定・サーバは 1 度だけ立てる）---"
start_server
for n in 2000 20000 100000 300000 1000000; do
  measure "$n" 8 "$WARMUP" "n${n}"
done
stop_server
log ""

log "--- C. ウォームアップスイープ（n=1,000,000・同時実行 8・各点でサーバを立て直す）---"
for w in 2 8 20 40; do
  start_server
  measure 1000000 8 "$w" "warmup${w}"
  stop_server
done
log ""

python3 - "$OUT/summary.json" "$WORK" "$DURATION" <<'PYEOF'
import json, subprocess, sys, platform

outpath, work, duration = sys.argv[1:4]

def read(label):
    with open(f"{work}/{label}.json") as f:
        d = json.load(f)
    return d["throughput_rps"], d["p99_ms"], d["errors"]

values = {"duration_sec": int(duration)}

for c in (16, 32, 64, 128):
    tp, p99, err = read(f"conc{c}")
    values[f"conc{c}_throughput_rps"] = tp
    values[f"conc{c}_p99_ms"] = p99
    values[f"conc{c}_errors"] = err

for n in (2000, 20000, 100000, 300000, 1000000):
    tp, p99, err = read(f"n{n}")
    values[f"n{n}_throughput_rps"] = tp
    values[f"n{n}_p99_ms"] = p99
    values[f"n{n}_errors"] = err

for w in (2, 8, 20, 40):
    tp, p99, err = read(f"warmup{w}")
    values[f"warmup{w}_throughput_rps"] = tp
    values[f"warmup{w}_p99_ms"] = p99
    values[f"warmup{w}_errors"] = err

base = values["warmup8_throughput_rps"]
values["warmup8_to_40_pct"] = round((values["warmup40_throughput_rps"] - base) / base * 100, 2)
c16 = values["conc16_throughput_rps"]
values["conc16_to_128_pct"] = round((values["conc128_throughput_rps"] - c16) / c16 * 100, 1)
values["conc16_to_128_p99_ratio"] = round(values["conc128_p99_ms"] / values["conc16_p99_ms"], 1)

summary = {
    "scenario": "002-steady-design",
    "mode": "M1",
    "measures": "002-steady-throughput の測定条件（同時実行・負荷・ウォームアップ）の妥当性を素の JVM で振って確かめる",
    "env": {
        "os": f"{platform.system()} {platform.release()}",
        "arch": platform.machine(),
        "java": subprocess.run(["java", "-version"], capture_output=True, text=True).stderr.splitlines()[0],
    },
    "values": values,
}
with open(outpath, "w") as f:
    json.dump(summary, f, ensure_ascii=False, indent=2)
    f.write("\n")
def _rel(p):
    # 出力先はリポジトリからの相対で見せる（生ログに実行環境の絶対パスを残さない）
    i = p.find("/results/")
    return p[i + 1:] if i >= 0 else p

print(f"summary: {_rel(outpath)}")
PYEOF

log ""
log "=== 完了 ==="

# 子プロセス（Maven / JVM / Docker）の出力は上の echo を直しても生ログに入るため、
# 書き終えたところで実行環境に固有の情報を落とす（tools/check-neutrality.py が検査する）
python3 "$ROOT/tools/sanitize-log.py" "$OUT"

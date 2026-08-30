#!/usr/bin/env bash
# シナリオ: 002-steady-throughput
# モード: M3（JDK 25 + Maven + GraalVM。Docker 不要）
# 測るもの: ウォームアップ後の定常状態で、素の JVM / JVM AOT キャッシュ /
#           GraalVM Native Image のスループットと p99 レイテンシがどう違うか。
#
# 🔴 測定設計（意図的な選択）
#   1) 負荷を 2 種類かける。軽い負荷（HTTP 往復が支配的）と重い負荷（アプリの計算が
#      支配的）。計算量を 10 倍（n=2,000 → 20,000）にしてもスループットが 5.4% しか
#      落ちず、その領域では測定側が律速だと分かったため（実測は scenarios/002-steady-design）。
#   2) ウォームアップ中の応答は記録しない（JIT が最適化を終える前の値を混ぜない）。
#   3) ラウンドロビン。1 ラウンド = jvm → aot → native。機体の状態を 3 方式へ均等に乗せる。
#   4) 負荷生成器は JDK だけで動くものをリポジトリに置く（読者が追加インストール不要）。
#
# ⚠️ クライアントとサーバが同一機体で CPU を共有する。絶対値はその前提で読むこと。
#
# 使い方:
#   bash scenarios/002-steady-throughput/run.sh
#   bash scenarios/002-steady-throughput/run.sh --rounds 1 --duration-sec 5 --out /tmp/x

set -euo pipefail

SCENARIO="002-steady-throughput"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/results/$SCENARIO"
ROUNDS=3
WARMUP=8
DURATION=10
CONCURRENCY=8
LIGHT_N=2000
HEAVY_N=1000000
PORT=18080
METHODS="jvm,aot,native"
GRAALVM_HOME_ARG="${GRAALVM_HOME:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out)          OUT="$2"; shift 2 ;;
    --rounds)       ROUNDS="$2"; shift 2 ;;
    --warmup-sec)   WARMUP="$2"; shift 2 ;;
    --duration-sec) DURATION="$2"; shift 2 ;;
    --concurrency)  CONCURRENCY="$2"; shift 2 ;;
    --methods)      METHODS="$2"; shift 2 ;;
    --graalvm-home) GRAALVM_HOME_ARG="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 3 ;;
  esac
done

if [ "$OUT" = "$ROOT/results/$SCENARIO" ] && [ "$METHODS" != "jvm,aot,native" ]; then
  echo "🔴 方式を減らした結果を results/ へ書こうとしています。--out で別ディレクトリを指定してください。" >&2
  exit 3
fi

mkdir -p "$OUT"
LOG="$OUT/run.log"
: > "$LOG"
log() { echo "$@" | tee -a "$LOG"; }

log "=== シナリオ: ${SCENARIO} / モード: M3 ==="
log "実行日時: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log "方式: ${METHODS} / ラウンド: ${ROUNDS} / ウォームアップ: ${WARMUP}s / 計測: ${DURATION}s / 同時実行: ${CONCURRENCY}"
log "負荷: 軽 n=${LIGHT_N}（HTTP 往復が支配的）/ 重 n=${HEAVY_N}（アプリの計算が支配的）"
log ""
log "--- 環境 ---"
log "os: $(uname -s) $(uname -r)"
log "arch: $(uname -m)"
log "cpu: $(sysctl -n hw.ncpu 2>/dev/null || nproc) コア"
log "java: $(java -version 2>&1 | head -1)"
log ""

case ",$METHODS," in *,native,*) WANT_NATIVE=1 ;; *) WANT_NATIVE=0 ;; esac
if [ "$WANT_NATIVE" = "1" ]; then
  if [ -z "$GRAALVM_HOME_ARG" ] && [ -d "$HOME/.sdkman/candidates/java/25.0.2-graalce" ]; then
    GRAALVM_HOME_ARG="$HOME/.sdkman/candidates/java/25.0.2-graalce"
  fi
  if [ -z "$GRAALVM_HOME_ARG" ] || [ ! -x "$GRAALVM_HOME_ARG/bin/native-image" ]; then
    log "🔴 GraalVM が見つかりません。--graalvm-home か GRAALVM_HOME を指定するか、--methods jvm,aot を使ってください。"
    exit 3
  fi
fi

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

log "--- 成果物をすべて先に揃える ---"
# 🔴 clean を挟む（前回の Native ビルドが残す Spring AOT 生成クラスの混入を防ぐ）
( cd "$ROOT" && mvn -q -B -pl app -am clean package -DskipTests ) 2>&1 | tee -a "$LOG"
# 🔴 素の jar を退避（Native ビルドが target/app.jar を作り直すため）
JAR="$WORK/app.jar"
cp "$ROOT/app/target/app.jar" "$JAR"
log "jar: $(wc -c < "$JAR" | tr -d ' ') bytes"

# 🔴 AOT キャッシュは「展開した形」で使う（Spring Boot 公式の手順）。
#    docs.spring.io: "You have to use the cache file with the extracted form of the
#    application, otherwise it has no effect."
#    実行可能 jar のままだと、アプリのクラスは独自のクラスローダ経由になり
#    JEP 483 の Non-Goals によりキャッシュ対象から外れる。
#    起動シナリオの実測では、展開の有無で -30.8% と -55.0% の差が出る。
EXT_DIR="$WORK/application"
( cd "$WORK" && java -Djarmode=tools -jar app.jar extract --destination application ) > "$WORK/extract.log" 2>&1 || {
  log "🔴 展開に失敗しました"; tail -20 "$WORK/extract.log" | tee -a "$LOG"; exit 1; }
[ -f "$EXT_DIR/app.jar" ] || { log "🔴 展開後に app.jar がありません"; exit 1; }
log "展開先: ${EXT_DIR} 中身: $(ls "$EXT_DIR" | tr '\n' ' ')"

CACHE="$EXT_DIR/app.aot"
( cd "$EXT_DIR" && java -XX:AOTCacheOutput=app.aot -Dspring.context.exit=onRefresh -jar app.jar ) > "$EXT_DIR/aot.log" 2>&1 || true
[ -f "$CACHE" ] || { log "🔴 AOT キャッシュが生成されていません"; exit 1; }
log "aot cache: $(wc -c < "$CACHE" | tr -d ' ') bytes / 警告 $(grep -c 'warning..aot' "$EXT_DIR/aot.log" || true) 件"

NATIVE_BIN=""
if [ "$WANT_NATIVE" = "1" ]; then
  ( cd "$ROOT" && JAVA_HOME="$GRAALVM_HOME_ARG" PATH="$GRAALVM_HOME_ARG/bin:$PATH" \
      mvn -B -Pnative -pl app package native:compile-no-fork -DskipTests ) > "$WORK/native.log" 2>&1 || {
        log "🔴 Native Image のビルドに失敗しました"; tail -20 "$WORK/native.log" | tee -a "$LOG"; exit 1; }
  NATIVE_BIN="$ROOT/app/target/app"
  [ -x "$NATIVE_BIN" ] || { log "🔴 native バイナリが見つかりません"; exit 1; }
  log "native: $(wc -c < "$NATIVE_BIN" | tr -d ' ') bytes"
fi
log ""

start_server() {   # $1 = method
  case "$1" in
    jvm)    java -Dserver.port="$PORT" -jar "$JAR" > "$WORK/server.log" 2>&1 & ;;
    # 🔴 exec でサブシェルを java に置き換える。置き換えないと $! がサブシェルの PID を指し、
    #    stop_server の kill がサーバ本体に届かず、次のアームとポートを奪い合う。
    aot)    ( cd "$EXT_DIR"; exec java -XX:AOTCache=app.aot -Dserver.port="$PORT" -jar app.jar ) > "$WORK/server.log" 2>&1 & ;;
    native) "$NATIVE_BIN" -Dserver.port="$PORT" > "$WORK/server.log" 2>&1 & ;;
  esac
  SERVER_PID=$!
  for _ in $(seq 1 80); do
    curl -sf "http://localhost:${PORT}/hello" > /dev/null 2>&1 && return 0
    sleep 0.25
  done
  log "🔴 サーバが起動しませんでした（$1）"; tail -15 "$WORK/server.log" | tee -a "$LOG"; return 1
}

stop_server() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
  sleep 1
}

log "--- 計測（ラウンドロビン）---"
RESULTS_DIR="$WORK/measurements"
mkdir -p "$RESULTS_DIR"

for r in $(seq 1 "$ROUNDS"); do
  for m in jvm aot native; do
    case ",$METHODS," in *,$m,*) ;; *) continue ;; esac
    start_server "$m"
    for load in light heavy; do
      [ "$load" = "light" ] && n="$LIGHT_N" || n="$HEAVY_N"
      f="$RESULTS_DIR/${m}_${load}_${r}.json"
      java "$ROOT/tools/loadgen/LoadGen.java" \
        --url "http://localhost:${PORT}/work?n=${n}" \
        --concurrency "$CONCURRENCY" --warmup-sec "$WARMUP" --duration-sec "$DURATION" \
        --out "$f" > /dev/null
      tp=$(grep -o '"throughput_rps": [0-9.]*' "$f" | cut -d' ' -f2)
      p99=$(grep -o '"p99_ms": [0-9.]*' "$f" | cut -d' ' -f2)
      log "round ${r} ${m} ${load}(n=${n}): ${tp} rps / p99 ${p99} ms"
    done
    stop_server
  done
done
log ""

python3 - "$LOG" "$OUT/summary.json" "$RESULTS_DIR" "$METHODS" \
         "$ROUNDS" "$WARMUP" "$DURATION" "$CONCURRENCY" "$LIGHT_N" "$HEAVY_N" <<'PYEOF'
import json, glob, os, statistics, subprocess, sys, platform

logpath, outpath, rdir, methods, rounds, warmup, duration, conc, light_n, heavy_n = sys.argv[1:11]
wanted = [m for m in ("jvm", "aot", "native") if m in methods.split(",")]

values = {
    "rounds": int(rounds), "warmup_sec": int(warmup), "duration_sec": int(duration),
    "concurrency": int(conc), "light_n": int(light_n), "heavy_n": int(heavy_n),
    "methods": ",".join(wanted),
}
lines = []
for load in ("light", "heavy"):
    for m in wanted:
        tps, p99s, errs = [], [], 0
        for f in sorted(glob.glob(os.path.join(rdir, f"{m}_{load}_*.json"))):
            d = json.loads(open(f).read())
            tps.append(d["throughput_rps"]); p99s.append(d["p99_ms"]); errs += d["errors"]
        if not tps:
            continue
        values[f"{load}_{m}_throughput_rps"] = round(statistics.median(tps), 1)
        values[f"{load}_{m}_p99_ms"] = round(statistics.median(p99s), 2)
        values[f"{load}_{m}_errors"] = errs
        lines.append(f"{load:5s} {m:7s} throughput {statistics.median(tps):9.1f} rps  p99 {statistics.median(p99s):6.2f} ms  errors {errs}")

for load in ("light", "heavy"):
    k = f"{load}_jvm_throughput_rps"
    if k in values:
        base = values[k]
        for m in wanted:
            if m != "jvm" and f"{load}_{m}_throughput_rps" in values:
                values[f"{load}_{m}_vs_jvm_pct"] = round((values[f"{load}_{m}_throughput_rps"] - base) / base * 100, 1)

lines.append("")
for load in ("light", "heavy"):
    for m in wanted:
        k = f"{load}_{m}_vs_jvm_pct"
        if k in values:
            lines.append(f"{load:5s} {m:7s} 対 JVM: {values[k]:+.1f}%")

with open(logpath, "a") as f:
    f.write("\n".join(lines) + "\n")
print("\n".join(lines))

summary = {
    "scenario": "002-steady-throughput",
    "mode": "M3",
    "measures": "ウォームアップ後の定常状態のスループットと p99（ラウンドロビン・負荷 2 種）",
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

print(f"\nsummary: {_rel(outpath)}")
PYEOF

log ""
log "=== 完了 ==="

# 子プロセス（Maven / JVM / Docker）の出力は上の echo を直しても生ログに入るため、
# 書き終えたところで実行環境に固有の情報を落とす（tools/check-neutrality.py が検査する）
python3 "$ROOT/tools/sanitize-log.py" "$OUT"

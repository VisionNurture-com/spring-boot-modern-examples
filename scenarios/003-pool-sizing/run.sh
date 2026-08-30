#!/usr/bin/env bash
# シナリオ: 003-pool-sizing
# モード: M2（JDK 25 + Maven + Docker）
# 測るもの: 仮想スレッドを有効にした Spring Boot アプリで、コネクションプールのサイズを振ると
#           スループットと待ち時間がどう動くか。あわせて、その間に pinning が何件記録されるか。
#
# 🔴 測定設計（意図的な選択）
#   1) 同時実行数を固定してプールだけを振る。プールが制約になっているかを見るため。
#   2) プールを十分大きくしたアーム（64）も置く。「プールが制約になる」と決めて測ると、
#      効かない条件を測らないことになる。効かない側も測って決定表の 1 行にする。
#   3) ラウンドロビン。1 ラウンド = 全プールサイズ。機体の状態を各条件へ均等に乗せる。
#   4) ウォームアップ中の応答は記録しない（負荷生成器が担当）。
#   5) 計測中は JFR を既定設定（jdk.VirtualThreadPinned は閾値 20 ms）で録る。
#      読者が実際に使う設定で何件出るかを示すため。
#   6) 負荷を 2 種類かける。待つだけの問い合わせ（pg_sleep・CPU を使わない）と、
#      データベース側に CPU を使わせる問い合わせ。前者だけだと「プールは大きいほどよい」
#      という結論しか出ず、公式が言う「小さいプールのほうが速い」を検算できない。
#
# ⚠️ クライアント・アプリ・データベースが同一機体で CPU を共有する。絶対値はその前提で読むこと。
#
# 前提: Docker が動いていること。JDK 25 と Maven が使えること。
#
# 使い方:
#   bash scenarios/003-pool-sizing/run.sh
#   bash scenarios/003-pool-sizing/run.sh --rounds 1 --duration-sec 5 --out /tmp/x

set -uo pipefail

SCENARIO="003-pool-sizing"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/results/$SCENARIO"
ROUNDS=3
WARMUP=5
DURATION=10
CONCURRENCY=64
DB_SLEEP_MS=50
DB_CPU_N=100000
POOLS=(2 4 8 16 32 64)
PG_IMAGE="postgres:18.6"
PG_NAME="sbme-pool-pg"
# ホストのポートは実行時に空きを選ぶ（決め打ちだと、その番号が埋まっている機体で
# docker run が daemon のエラーで落ちる）。空いていれば 55432 のままになる。
PG_PORT="$(python3 "$ROOT/tools/free-port.py" 55432)" || {
  echo "PostgreSQL 用の空きポートを確保できません" >&2; exit 3; }
APP_PORT=8080

# JDK の場所は次の順で決める。
#   1) 環境変数 JAVA25_HOME
#   2) SDKMAN の既定の置き場
#   3) JAVA_HOME（CI のように SDKMAN が無い環境向け）
JAVA25_HOME="${JAVA25_HOME:-}"
if [ -z "${JAVA25_HOME}" ]; then
  if [ -x "$HOME/.sdkman/candidates/java/25.0.4-tem/bin/java" ]; then
    JAVA25_HOME="$HOME/.sdkman/candidates/java/25.0.4-tem"
  else
    JAVA25_HOME="${JAVA_HOME:-}"
  fi
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --rounds) ROUNDS="$2"; shift 2 ;;
    --duration-sec) DURATION="$2"; shift 2 ;;
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 3 ;;
  esac
done

WORK="$(mktemp -d)"
APP_PID=""
cleanup() {
  [ -n "${APP_PID}" ] && kill "${APP_PID}" 2>/dev/null
  docker rm -f "${PG_NAME}" >/dev/null 2>&1
  rm -rf "${WORK}"
}
trap cleanup EXIT

mkdir -p "${OUT}"
LOG="${OUT}/run.log"
# 出力先はリポジトリからの相対で見せる（生ログに実行環境の絶対パスを残さない）
rel() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;; *) printf '%s' "$1" ;; esac; }

: > "${LOG}"
log() { echo "$@" | tee -a "${LOG}"; }

# 使ったホストのポートを残す（空きが取れなかった回と取れた回を後から見分けるため）
log "PostgreSQL のホストポート: ${PG_PORT}"

command -v docker >/dev/null 2>&1 || { echo "docker が見つかりません" >&2; exit 3; }
[ -x "${JAVA25_HOME}/bin/java" ] || { echo "JDK 25 が見つかりません: ${JAVA25_HOME}" >&2; exit 3; }

log "=========================================="
log "${SCENARIO}"
log "=========================================="
log "日時: $(date '+%Y-%m-%d %H:%M:%S %z')"
log "OS: $(uname -sr)"
log "アーキテクチャ: $(uname -m)"
log "Java: $("${JAVA25_HOME}/bin/java" -version 2>&1 | head -1)"
log "Docker: $(docker --version)"
log "PostgreSQL イメージ: ${PG_IMAGE}"
log "同時実行数: ${CONCURRENCY} / 待つ問い合わせ: ${DB_SLEEP_MS}ms / CPU を使う問い合わせ: n=${DB_CPU_N}"
log "機体の論理コア数: $(sysctl -n hw.ncpu 2>/dev/null || nproc)"
log "プールサイズ: ${POOLS[*]}"
log "ラウンド数: ${ROUNDS} / ウォームアップ: ${WARMUP}s / 計測: ${DURATION}s"
log ""

log "▶ ビルド"
( cd "${ROOT}" && JAVA_HOME="${JAVA25_HOME}" mvn -q -pl app-db -am clean package -DskipTests ) >> "${LOG}" 2>&1
JAR="${ROOT}/app-db/target/app-db.jar"
[ -f "${JAR}" ] || { echo "app-db.jar が作られませんでした" >&2; exit 1; }
log "   $(ls -l "${JAR}" | awk '{print $5}') バイト"

log "▶ PostgreSQL を起動"
docker rm -f "${PG_NAME}" >/dev/null 2>&1
docker run -d --name "${PG_NAME}" \
  -e POSTGRES_USER=measure -e POSTGRES_PASSWORD=measure -e POSTGRES_DB=measure \
  -p "${PG_PORT}:5432" "${PG_IMAGE}" >> "${LOG}" 2>&1
for i in $(seq 1 60); do
  docker exec "${PG_NAME}" pg_isready -U measure -d measure >/dev/null 2>&1 && break
  sleep 1
done
docker exec "${PG_NAME}" pg_isready -U measure -d measure >/dev/null 2>&1 \
  || { echo "PostgreSQL が起動しませんでした" >&2; exit 1; }
PG_VERSION=$(docker exec "${PG_NAME}" psql -U measure -d measure -tAc "show server_version" 2>/dev/null)
log "   PostgreSQL ${PG_VERSION}"
log ""

# $1=pool $2=round $3=workload(wait|cpu)
measure_pool() {
  local pool="$1" round="$2" wl="$3"
  local jfr="${WORK}/${wl}-${pool}-r${round}.jfr"
  local res="${WORK}/${wl}-${pool}-r${round}.json"
  local url="http://localhost:${APP_PORT}/db?ms=${DB_SLEEP_MS}"
  [ "${wl}" = "cpu" ] && url="http://localhost:${APP_PORT}/dbcpu?n=${DB_CPU_N}"

  POOL_SIZE="${pool}" \
  DB_URL="jdbc:postgresql://localhost:${PG_PORT}/measure" \
  "${JAVA25_HOME}/bin/java" \
    "-XX:StartFlightRecording:settings=default,filename=${jfr},dumponexit=true" \
    -jar "${JAR}" >> "${LOG}" 2>&1 &
  APP_PID=$!

  local i
  for i in $(seq 1 60); do
    curl -sf "http://localhost:${APP_PORT}/hello" >/dev/null 2>&1 && break
    sleep 0.5
  done
  if ! curl -sf "http://localhost:${APP_PORT}/hello" >/dev/null 2>&1; then
    log "   🔴 アプリが起動しませんでした（workload=${wl} pool=${pool} round=${round}）"
    kill "${APP_PID}" 2>/dev/null; APP_PID=""
    return 1
  fi

  "${JAVA25_HOME}/bin/java" "${ROOT}/tools/loadgen/LoadGen.java" \
    --url "${url}" \
    --concurrency "${CONCURRENCY}" --warmup-sec "${WARMUP}" --duration-sec "${DURATION}" \
    --out "${res}" >> "${LOG}" 2>&1

  kill "${APP_PID}" 2>/dev/null
  wait "${APP_PID}" 2>/dev/null
  APP_PID=""

  local n
  n=$("${JAVA25_HOME}/bin/jfr" summary "${jfr}" 2>/dev/null | grep -i "VirtualThreadPinned" | awk '{print $2}')
  echo "${n:-0}" > "${WORK}/pin-${wl}-${pool}-r${round}.txt"
  {
    echo "--- workload=${wl} pool=${pool} round=${round} の JFR 内訳 ---"
    "${JAVA25_HOME}/bin/jfr" print --events jdk.VirtualThreadPinned "${jfr}" 2>/dev/null \
      | grep -E "pinnedReason|blockingOperation" | sort | uniq -c | sort -rn
  } >> "${LOG}" 2>&1
  return 0
}

for r in $(seq 1 "${ROUNDS}"); do
  for wl in wait cpu; do
    log "▶ ラウンド ${r} / 負荷=${wl}"
    for pool in "${POOLS[@]}"; do
      measure_pool "${pool}" "${r}" "${wl}" || continue
      local_json="${WORK}/${wl}-${pool}-r${r}.json"
      tp=$(python3 -c "import json;print(json.load(open('${local_json}'))['throughput_rps'])" 2>/dev/null)
      p99=$(python3 -c "import json;print(json.load(open('${local_json}'))['p99_ms'])" 2>/dev/null)
      p50=$(python3 -c "import json;print(json.load(open('${local_json}'))['p50_ms'])" 2>/dev/null)
      pin=$(cat "${WORK}/pin-${wl}-${pool}-r${r}.txt")
      log "   pool=${pool} → ${tp} req/s / p50 ${p50}ms / p99 ${p99}ms / pinned ${pin} 件"
    done
  done
done

log ""
log "=========================================="
log "結果（${ROUNDS} ラウンドの中央値）"
log "=========================================="

python3 - "${WORK}" "${OUT}" "${ROUNDS}" "${CONCURRENCY}" "${DB_SLEEP_MS}" "${PG_VERSION}" "${PG_IMAGE}" "${DB_CPU_N}" "$(sysctl -n hw.ncpu 2>/dev/null || nproc)" <<'PYEOF' | tee -a "${LOG}"
import json, os, statistics, subprocess, sys

work, out, rounds, conc, sleep_ms, pgver, pgimage, cpu_n, ncpu = sys.argv[1:10]
rounds = int(rounds)
pools = [2, 4, 8, 16, 32, 64]
workloads = ["wait", "cpu"]

vals = {
    "concurrency": int(conc),
    "db_sleep_ms": int(sleep_ms),
    "db_cpu_n": int(cpu_n),
    "cores": int(ncpu),
    "hikari_formula_pool": int(ncpu) * 2 + 1,
    "rounds": rounds,
    "pools": ",".join(str(p) for p in pools),
}

def med(xs):
    return round(statistics.median(xs), 1) if xs else -1.0

for wl in workloads:
    label = "待つ問い合わせ（pg_sleep）" if wl == "wait" else "CPU を使う問い合わせ"
    print(f"\n[{label}]")
    print(f"{'pool':>5} {'req/s':>9} {'p50 ms':>9} {'p99 ms':>9} {'pinned':>7}")
    for p in pools:
        tps, p50s, p99s, pins = [], [], [], []
        for r in range(1, rounds + 1):
            f = os.path.join(work, f"{wl}-{p}-r{r}.json")
            if os.path.isfile(f):
                d = json.load(open(f))
                tps.append(d["throughput_rps"]); p50s.append(d["p50_ms"]); p99s.append(d["p99_ms"])
            pf = os.path.join(work, f"pin-{wl}-{p}-r{r}.txt")
            if os.path.isfile(pf):
                pins.append(int(open(pf).read().strip() or 0))
        vals[f"{wl}_pool{p}_rps"] = med(tps)
        vals[f"{wl}_pool{p}_p50_ms"] = med(p50s)
        vals[f"{wl}_pool{p}_p99_ms"] = med(p99s)
        vals[f"{wl}_pool{p}_pinned"] = int(med(pins)) if pins else -1
        print(f"{p:>5} {vals[f'{wl}_pool{p}_rps']:>9} {vals[f'{wl}_pool{p}_p50_ms']:>9} "
              f"{vals[f'{wl}_pool{p}_p99_ms']:>9} {vals[f'{wl}_pool{p}_pinned']:>7}")
    best = max(pools, key=lambda p: vals[f"{wl}_pool{p}_rps"])
    vals[f"{wl}_best_rps_pool"] = best
    vals[f"{wl}_best_rps"] = vals[f"{wl}_pool{best}_rps"]

vals["pinned_total"] = sum(
    vals[f"{wl}_pool{p}_pinned"] for wl in workloads for p in pools
    if vals[f"{wl}_pool{p}_pinned"] > 0
)

summary = {
    "scenario": "003-pool-sizing",
    "mode": "M2",
    "measures": "仮想スレッドを有効にした Spring Boot アプリで、コネクションプールのサイズを振ったときのスループット・待ち時間・pinning 件数（負荷 2 種）",
    "env": {
        "os": subprocess.run(["uname", "-sr"], capture_output=True, text=True).stdout.strip(),
        "arch": subprocess.run(["uname", "-m"], capture_output=True, text=True).stdout.strip(),
        "postgres": pgver,
        "postgres_image": pgimage,
    },
    "values": vals,
}
with open(os.path.join(out, "summary.json"), "w") as fh:
    json.dump(summary, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
print()
print(f"スループット最大のプールサイズ — 待つ問い合わせ: {vals['wait_best_rps_pool']} / CPU を使う問い合わせ: {vals['cpu_best_rps_pool']}")
print(f"HikariCP 公式の式（コア数 x 2 + 1）: {vals['hikari_formula_pool']}")
print(f"pinning の合計: {vals['pinned_total']} 件（既定閾値 20 ms）")
PYEOF

log ""
log "生ログ: $(rel "${LOG}")"
log "実効値: $(rel "${OUT}/summary.json")"

# 子プロセス（Maven / JVM / Docker）の出力は上の echo を直しても生ログに入るため、
# 書き終えたところで実行環境に固有の情報を落とす（tools/check-neutrality.py が検査する）
python3 "$ROOT/tools/sanitize-log.py" "$OUT"

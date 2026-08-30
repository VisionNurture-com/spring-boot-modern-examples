#!/usr/bin/env bash
# シナリオ: 006-otel-cost
# モード: M2（JDK 25 + Maven + Docker。OTLP コレクタと PostgreSQL をコンテナで立てる）
# 測るもの: spring-boot-starter-opentelemetry を入れたとき、サンプリング率ごとに
#           レイテンシ・スループット・CPU・メモリがどう変わるか。
#
# 🔴 測定設計（意図的な選択）
#   1) 対照は「依存ごと外した jar」。プロパティで無効にするのではなく、Maven の
#      otel プロファイルを外してビルドした jar を使う。無効化と非搭載は別物である。
#      ただし対照にも spring-boot-starter-actuator は入ったままである（app の既存構成）。
#   2) 率 0.0 の腕を置く。記録しないが計装は入っている状態を分離するため。
#      率を下げれば比例して軽くなるのか、判定と伝播のコストが残るのかは、この腕でしか分からない。
#   3) 送信先は受けて捨てるだけのコレクタ（nop エクスポータ）。バックエンドの性能を測らない。
#   4) 検算パスでは debug エクスポータに切り替え、受信スパンを実際に数える。
#      「計装なしが本当に計装なしか」を、コレクタ側の受信 0 で裏を取るためである。
#   5) ラウンドロビン。1 ラウンドで全腕を回し、機体の状態を腕へ均等に乗せる。
#   6) メトリクスのエクスポートは全腕で無効にする。既定の step が 1 分で、
#      短い負荷では送信が数回しか起きず、腕の比較に乗らないためである。
#      本シナリオが測るのはトレースのコストである。
#
# ⚠️ 負荷生成器とサーバが同一機体で CPU を共有する。絶対値はその前提で読むこと。
#    CPU はアプリのプロセス単位で取る（ホスト全体の負荷では判定しない）。
#
# 使い方:
#   bash scenarios/006-otel-cost/run.sh                    # 全フェーズ
#   bash scenarios/006-otel-cost/run.sh --phase app        # 一部だけ回す
#   bash scenarios/006-otel-cost/run.sh --phase aggregate  # 集計だけやり直す

set -euo pipefail

SCENARIO="006-otel-cost"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scenarios/$SCENARIO"
OUT="$ROOT/results/$SCENARIO"
PHASE="all"
ROUNDS=3
ROUND_START=1
WARMUP=8
DURATION=10
CONCURRENCY=8
APP_N=2000
DB_N=20000
ARMS_FILTER=""
PORT=18120
# ホストのポートは実行時に空きを選ぶ（決め打ちだと、その番号が埋まっている機体で
# docker run が daemon のエラーで落ちる。2026-08-30 に CI で 55432 が埋まって落ちた）。
PG_PORT="$(python3 "$ROOT/tools/free-port.py" 55432)" || {
  echo "PostgreSQL 用の空きポートを確保できません" >&2; exit 3; }
OTLP_PORT="$(python3 "$ROOT/tools/free-port.py" 4318)" || {
  echo "OTLP コレクタ用の空きポートを確保できません" >&2; exit 3; }
PG_IMAGE="postgres:18.6"
COL_IMAGE="otel/opentelemetry-collector:0.159.0"
PG_NAME="pg-006"
COL_NAME="otelcol-006"

while [ $# -gt 0 ]; do
  case "$1" in
    --phase)        PHASE="$2"; shift 2 ;;
    --out)          OUT="$2"; shift 2 ;;
    --rounds)       ROUNDS="$2"; shift 2 ;;
    --round-start)  ROUND_START="$2"; shift 2 ;;
    --warmup-sec)   WARMUP="$2"; shift 2 ;;
    --duration-sec) DURATION="$2"; shift 2 ;;
    --concurrency)  CONCURRENCY="$2"; shift 2 ;;
    # 🔴 n 感度チェック（記事 006 の実機確認）で使う。
    #   /work?n=<N> の反復回数を変え、「計装ありと計装なしの比」が n でどう動くかを見る。
    #   素のアプリが n でどう動くかは 002 が既測（計算量 10 倍でスループット -5.4%）なので測り直さない。
    --app-n)        APP_N="$2"; shift 2 ;;
    # 腕を名前の前方一致で絞る（例: --arms A0,A3,A5）。空なら全腕。
    --arms)         ARMS_FILTER="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 3 ;;
  esac
done

case "$PHASE" in build|verify|app|db|queue|drop|aggregate|all) ;; *) echo "不明なフェーズ: $PHASE" >&2; exit 3 ;; esac

command -v docker >/dev/null 2>&1 || { echo "docker が見つかりません" >&2; exit 3; }
docker info >/dev/null 2>&1 || { echo "docker デーモンが動いていません" >&2; exit 3; }

WORK="$OUT/work"
MEAS="$OUT/measurements"
SPANS="$OUT/spans"
mkdir -p "$OUT" "$WORK" "$MEAS" "$SPANS"
LOG="$OUT/run.log"
if [ "$PHASE" = "all" ] || [ "$PHASE" = "build" ]; then : > "$LOG"; fi
log() { echo "$@" | tee -a "$LOG"; }

# 使ったホストのポートを残す（空きが取れなかった回と取れた回を後から見分けるため）
log "ホストポート: PostgreSQL=${PG_PORT} / OTLP コレクタ=${OTLP_PORT}"

APP_PID=""
cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
}
trap cleanup EXIT

OTLP_ENDPOINT="http://localhost:${OTLP_PORT}/v1/traces"
OTLP_ARGS=( -Dmanagement.opentelemetry.tracing.export.otlp.endpoint="$OTLP_ENDPOINT"
            -Dmanagement.otlp.metrics.export.enabled=false )

# ---------------------------------------------------------------- 腕の定義
# 形式: 名前|jar|パス|追加プロパティ（空可）
APP_ARMS=(
  "A0_plain|app-plain|/work?n=${APP_N}|"
  "A1_p000|app-otel|/work?n=${APP_N}|-Dmanagement.tracing.sampling.probability=0.0"
  "A2_p001|app-otel|/work?n=${APP_N}|-Dmanagement.tracing.sampling.probability=0.01"
  "A3_default|app-otel|/work?n=${APP_N}|"
  "A4_p050|app-otel|/work?n=${APP_N}|-Dmanagement.tracing.sampling.probability=0.5"
  "A5_p100|app-otel|/work?n=${APP_N}|-Dmanagement.tracing.sampling.probability=1.0"
)
DB_ARMS=(
  "B0_plain|appdb-plain|/dbcpu?n=${DB_N}|"
  "B1_default|appdb-otel|/dbcpu?n=${DB_N}|"
  "B2_p100|appdb-otel|/dbcpu?n=${DB_N}|-Dmanagement.tracing.sampling.probability=1.0"
)

jar_path() { echo "$WORK/006-$1.jar"; }
is_otel()  { case "$1" in *-otel) return 0 ;; *) return 1 ;; esac; }
is_db()    { case "$1" in appdb-*) return 0 ;; *) return 1 ;; esac; }

start_collector() {  # $1 = count|nop
  docker rm -f "$COL_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$COL_NAME" -p "${OTLP_PORT}:4318" \
    -v "$HERE/collector-$1.yaml:/etc/otelcol/config.yaml:ro" \
    "$COL_IMAGE" --config /etc/otelcol/config.yaml >/dev/null
  for _ in $(seq 1 40); do
    curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d '{}' \
      "$OTLP_ENDPOINT" 2>/dev/null && return 0
    sleep 0.5
  done
  log "🔴 コレクタが応答しません"; return 1
}

start_pg() {
  docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
  docker run -d --name "$PG_NAME" -p "${PG_PORT}:5432" \
    -e POSTGRES_USER=measure -e POSTGRES_PASSWORD=measure -e POSTGRES_DB=measure \
    "$PG_IMAGE" >/dev/null
  for _ in $(seq 1 60); do
    docker exec "$PG_NAME" pg_isready -U measure -d measure >/dev/null 2>&1 && return 0
    sleep 1
  done
  log "🔴 PostgreSQL が起動しません"; return 1
}

start_app() {  # $1 = jarkey  $2 = 追加プロパティ（空可）
  local jarkey=$1 extra=$2 args=()
  args=( -Dserver.port="$PORT" -Dspring.application.name="measure-006" )
  if is_db "$jarkey"; then
    args+=( -DDB_URL="jdbc:postgresql://localhost:${PG_PORT}/measure" )
  fi
  if is_otel "$jarkey"; then
    args+=( "${OTLP_ARGS[@]}" )
  fi
  # shellcheck disable=SC2206
  [ -n "$extra" ] && args+=( $extra )
  java "${args[@]}" -jar "$(jar_path "$jarkey")" > "$WORK/server.log" 2>&1 &
  APP_PID=$!
  for _ in $(seq 1 100); do
    curl -sf "http://localhost:${PORT}/hello" > /dev/null 2>&1 && return 0
    sleep 0.3
  done
  log "🔴 サーバが起動しませんでした（${jarkey} / ${extra}）"
  tail -20 "$WORK/server.log" | tee -a "$LOG"
  return 1
}

stop_app() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
  sleep 1
}

# CPU 秒（累積）を取る。macOS の ps は MM:SS.ss / HH:MM:SS.ss を返す。
cpu_sec() {
  local raw; raw=$(ps -o time= -p "$1" 2>/dev/null | tr -d ' ')
  [ -z "$raw" ] && { echo 0; return; }
  echo "$raw" | awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else if (NF==2) print $1*60+$2; else print $1 }'
}

# ------------------------------------------------------------------ build
phase_build() {
  log "=== シナリオ: ${SCENARIO} / モード: M2 ==="
  log "実行日時: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  log "ラウンド: ${ROUNDS} / ウォームアップ: ${WARMUP}s / 計測: ${DURATION}s / 同時実行: ${CONCURRENCY}"
  log "負荷: app ${APP_N} 反復 / app-db ${DB_N} 行"
  log ""
  log "--- 環境 ---"
  log "os: $(uname -s) $(uname -r)"
  log "arch: $(uname -m)"
  log "cpu: $(sysctl -n hw.ncpu 2>/dev/null || nproc) コア"
  log "java: $(java -version 2>&1 | head -1)"
  log "docker: $(docker --version)"
  log "collector image: ${COL_IMAGE}"
  log "postgres image: ${PG_IMAGE}"
  log ""
  log "--- 4 つの jar を作る（計装あり / なし × app / app-db）---"
  # 🔴 計測専用モジュール（app-otelcost / app-db-otelcost）を使う。app 本体の pom は触らない。
  #    Spring Boot の repackage は META-INF/maven へ pom.xml を埋め込むため、
  #    無効なプロファイルを 1 つ足すだけで app.jar が 253 バイト増え、
  #    002 / 004 が記事に載せている jar のバイト数が再現しなくなる（実測で確認済み）。
  #    計装あり / なしを同じ pom で作り分けるので、jar の差は starter のぶんだけになる。
  ( cd "$ROOT" && mvn -q -B -pl app-otelcost -am clean package -DskipTests )
  cp "$ROOT/app-otelcost/target/app-otelcost.jar" "$(jar_path app-plain)"
  ( cd "$ROOT" && mvn -q -B -Potel -pl app-otelcost clean package -DskipTests )
  cp "$ROOT/app-otelcost/target/app-otelcost.jar" "$(jar_path app-otel)"
  ( cd "$ROOT" && mvn -q -B -pl app-db-otelcost -am clean package -DskipTests )
  cp "$ROOT/app-db-otelcost/target/app-db-otelcost.jar" "$(jar_path appdb-plain)"
  ( cd "$ROOT" && mvn -q -B -Potel -pl app-db-otelcost clean package -DskipTests )
  cp "$ROOT/app-db-otelcost/target/app-db-otelcost.jar" "$(jar_path appdb-otel)"
  for k in app-plain app-otel appdb-plain appdb-otel; do
    log "jar ${k}: $(wc -c < "$(jar_path "$k")" | tr -d ' ') bytes"
  done
  log ""
}

# ----------------------------------------------------------------- verify
# 受信スパンを実際に数える。計装なしが本当に 0 か、既定が本当に 10% かを裏取りする。
phase_verify() {
  log "--- 検算パス（受信スパンを数える）---"
  local reqs=100
  for spec in "${APP_ARMS[@]}" "${DB_ARMS[@]}"; do
    IFS='|' read -r name jarkey path extra <<< "$spec"
    is_db "$jarkey" && start_pg
    start_collector count
    start_app "$jarkey" "$extra"
    start_collector count      # 起動確認の分を数えないため、ここで作り直す
    for _ in $(seq 1 "$reqs"); do curl -s "http://localhost:${PORT}${path}" > /dev/null; done
    sleep 8
    stop_app
    local n; n=$(docker logs "$COL_NAME" 2>&1 | grep -c '^Span #' || true)
    docker logs "$COL_NAME" 2>&1 | grep '^    Name' | sed 's/.*: //' | sort | uniq -c > "$SPANS/$name.txt" || true
    log "検算 ${name}: リクエスト ${reqs} 回 → 受信スパン ${n} 本"
    echo "$n" > "$SPANS/$name.count"
  done
  log ""
}

# ------------------------------------------------------------ measurement
# 腕の spec を引数で受ける（bash 3.2 でも動くよう nameref を使わない）
measure_arms() {
  local arms=( "$@" )
  if [ -n "$ARMS_FILTER" ]; then
    local filtered=() spec name
    for spec in "${arms[@]}"; do
      name="${spec%%|*}"
      case ",$ARMS_FILTER," in *",${name%%_*},"*) filtered+=( "$spec" ) ;; esac
    done
    arms=( "${filtered[@]}" )
    log "腕を絞りました（--arms ${ARMS_FILTER}）: ${#arms[@]} 本"
  fi
  for r in $(seq "$ROUND_START" $((ROUND_START + ROUNDS - 1))); do
    for spec in "${arms[@]}"; do
      IFS='|' read -r name jarkey path extra <<< "$spec"
      start_app "$jarkey" "$extra"
      local c0 rssmax=0
      c0=$(cpu_sec "$APP_PID")
      ( while kill -0 "$APP_PID" 2>/dev/null; do
          ps -o rss= -p "$APP_PID" 2>/dev/null | tr -d ' ' >> "$WORK/rss.tmp"
          sleep 0.5
        done ) &
      local sampler=$!
      : > "$WORK/rss.tmp"
      local f="$MEAS/${name}_${r}.json"
      java "$ROOT/tools/loadgen/LoadGen.java" \
        --url "http://localhost:${PORT}${path}" \
        --concurrency "$CONCURRENCY" --warmup-sec "$WARMUP" --duration-sec "$DURATION" \
        --out "$f" > /dev/null
      local c1; c1=$(cpu_sec "$APP_PID")
      kill "$sampler" 2>/dev/null || true
      rssmax=$(sort -n "$WORK/rss.tmp" 2>/dev/null | tail -1)
      [ -z "$rssmax" ] && rssmax=0
      python3 - "$f" "$c0" "$c1" "$rssmax" <<'PY'
import json,sys
f,c0,c1,rss = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
d=json.load(open(f))
d["cpu_sec"]=round(c1-c0,2)
d["rss_max_kb"]=rss
json.dump(d,open(f,"w"),ensure_ascii=False,indent=2)
PY
      local tp p99 cpu
      tp=$(python3 -c "import json;print(json.load(open('$f'))['throughput_rps'])")
      p99=$(python3 -c "import json;print(json.load(open('$f'))['p99_ms'])")
      cpu=$(python3 -c "import json;print(json.load(open('$f'))['cpu_sec'])")
      log "round ${r} ${name}: ${tp} rps / p99 ${p99} ms / cpu ${cpu} s / rss ${rssmax} KB"
      stop_app
    done
  done
}

phase_app() { log "--- 計測: app（軽い仕事・${APP_N} 反復）---"; start_collector nop; measure_arms "${APP_ARMS[@]}"; log ""; }
phase_db()  { log "--- 計測: app-db（重い仕事・${DB_N} 行）---"; start_pg; start_collector nop; measure_arms "${DB_ARMS[@]}"; log ""; }

# ------------------------------------------------------------------ queue
# 送信先が生きていても、キューが溢れてスパンが捨てられていないかを率ごとに数える。
# 捨てられているなら、その腕は「送る費用」ではなく「捨てる費用」を測っていることになる。
phase_queue() {
  log "--- 検算: キュー溢れ（送信先は生かしたまま）---"
  start_collector nop
  for p in 1.0 0.5 0.1 0.01; do
    start_app app-otel "-Dmanagement.tracing.sampling.probability=$p"
    local f="$WORK/queue_$p.json"
    java "$ROOT/tools/loadgen/LoadGen.java" --url "http://localhost:${PORT}/work?n=${APP_N}" \
      --concurrency "$CONCURRENCY" --warmup-sec "$WARMUP" --duration-sec "$DURATION" --out "$f" > /dev/null
    sleep 3
    stop_app
    local reqs dropped
    reqs=$(python3 -c "import json;print(json.load(open('$f'))['requests'])")
    # awk 単体で数える。grep は 0 件のとき終了コード 1 を返し、set -e で止まってしまう。
    dropped=$(awk '/dropped [0-9]+ span/ { for (i = 1; i <= NF; i++) if ($i == "dropped") s += $(i+1) } END { print s+0 }' "$WORK/server.log")
    echo "$dropped" > "$SPANS/queue_dropped_${p}_r${ROUND_START}.count"
    echo "$reqs" > "$SPANS/queue_requests_${p}_r${ROUND_START}.count"
    log "ラウンド ${ROUND_START} 率 ${p}: 計測リクエスト ${reqs} 件 / キューで捨てられたスパン ${dropped} 本"
  done
  log ""
}

# ------------------------------------------------------------------- drop
# 送信先を測定の途中で止める。キューが埋まったあとアプリがどうなるかを見る。
phase_drop() {
  log "--- 計測: コレクタ停止（C1・率 1.0）---"
  start_collector nop
  start_app app-otel "-Dmanagement.tracing.sampling.probability=1.0"
  local f="$MEAS/C1_before_1.json"
  java "$ROOT/tools/loadgen/LoadGen.java" --url "http://localhost:${PORT}/work?n=${APP_N}" \
    --concurrency "$CONCURRENCY" --warmup-sec "$WARMUP" --duration-sec "$DURATION" --out "$f" > /dev/null
  log "停止前: $(python3 -c "import json;d=json.load(open('$f'));print(d['throughput_rps'],'rps / p99',d['p99_ms'],'ms')")"
  docker stop "$COL_NAME" >/dev/null
  log "コレクタを停止しました"
  local g="$MEAS/C1_after_1.json"
  java "$ROOT/tools/loadgen/LoadGen.java" --url "http://localhost:${PORT}/work?n=${APP_N}" \
    --concurrency "$CONCURRENCY" --warmup-sec "$WARMUP" --duration-sec "$DURATION" --out "$g" > /dev/null
  log "停止後: $(python3 -c "import json;d=json.load(open('$g'));print(d['throughput_rps'],'rps / p99',d['p99_ms'],'ms / errors',d['errors'])")"
  awk '/dropped [0-9]+ span/ { for (i = 1; i <= NF; i++) if ($i == "dropped") s += $(i+1) } END { print s+0 }' \
    "$WORK/server.log" > "$SPANS/C1_dropped_spans.count"
  awk '/Failed to export spans/ { n++ } END { print n+0 }' "$WORK/server.log" > "$SPANS/C1_export_error_lines.count"
  log "停止後のアプリログ: 捨てられたスパン $(cat "$SPANS/C1_dropped_spans.count") 本 / エクスポート失敗 $(cat "$SPANS/C1_export_error_lines.count") 行"
  stop_app
  log ""
}

# -------------------------------------------------------------- aggregate
phase_aggregate() {
  log "--- 集計 ---"
  python3 "$HERE/aggregate.py" "$OUT" "$ROUNDS" "$WARMUP" "$DURATION" "$CONCURRENCY" "$APP_N" "$DB_N" \
          "$COL_IMAGE" "$PG_IMAGE" | tee -a "$LOG"
}

case "$PHASE" in
  build)     phase_build ;;
  verify)    phase_verify ;;
  app)       phase_app ;;
  db)        phase_db ;;
  queue)     phase_queue ;;
  drop)      phase_drop ;;
  aggregate) phase_aggregate ;;
  all)       phase_build; phase_verify; phase_app; phase_db; phase_queue; phase_drop; phase_aggregate ;;
esac

docker rm -f "$COL_NAME" "$PG_NAME" >/dev/null 2>&1 || true
log "=== 完了（フェーズ: ${PHASE}）==="

# 子プロセス（Maven / JVM / Docker）の出力は上の echo を直しても生ログに入るため、
# 書き終えたところで実行環境に固有の情報を落とす（tools/check-neutrality.py が検査する）
python3 "$ROOT/tools/sanitize-log.py" "$OUT"

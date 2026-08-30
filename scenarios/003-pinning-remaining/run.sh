#!/usr/bin/env bash
# シナリオ: 003-pinning-remaining
# モード: M1（JDK 25 + JDK 21。Maven も Docker も不要）
# 測るもの: 仮想スレッドがキャリアスレッドを手放せなくなる経路が、JDK 25 で何件どう記録されるか。
#
# 🔴 測定設計（意図的な選択）
#   1) 閾値を 2 段で録る。jdk.VirtualThreadPinned の既定閾値は 20 ms で、既定のまま録ると
#      それより短い pin は 1 件も現れない。「0 件」が測定値なのか閾値の結果なのかを分けるため、
#      既定（20 ms）と 0 ms の両方で録る。
#   2) 何もしないアーム（noop）を置く。ハーネス自身（CountDownLatch の待ち合わせ）が pin を出すため、
#      対照なしではアームの件数がハーネス由来か題材由来かを分けられない。
#   3) 1 試行 = 1 プロセス。クラスの初期化は 1 プロセスに 1 回しか起きない。
#   4) JDK 21 と対照する。「25 で出ない」ことを言うには「21 では出る」対照が要る。
#   5) 件数だけでなく pinnedReason で分類する。理由の内訳が変われば同じ件数でも別の事象になる。
#   6) 1 セルにつき 5 セット取り中央値で比べる。閾値 0 ms の件数は試行ごとに揺れるため、
#      1 回の値を代表として扱わない。
#
# ⚠️ jdk.tracePinnedThreads は使わない。JDK 24 以降は削除されており、指定しても何も起きない。
#
# 使い方:
#   bash scenarios/003-pinning-remaining/run.sh
#   JAVA25_HOME=/path/to/jdk25 JAVA21_HOME=/path/to/jdk21 bash scenarios/003-pinning-remaining/run.sh
#   bash scenarios/003-pinning-remaining/run.sh --sets 1 --out /tmp/x

set -uo pipefail

SCENARIO="003-pinning-remaining"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/scenarios/$SCENARIO/src"
OUT="$ROOT/results/$SCENARIO"
THREADS=8
BLOCK_MS=100
SETS=5

# JDK の場所は次の順で決める。
#   1) 環境変数 JAVA25_HOME / JAVA21_HOME
#   2) SDKMAN の既定の置き場
#   3) JAVA_HOME（CI のように SDKMAN が無い環境向け。対象版は呼び出し側が用意する）
JAVA25_HOME="${JAVA25_HOME:-}"
if [ -z "${JAVA25_HOME}" ]; then
  if [ -x "$HOME/.sdkman/candidates/java/25.0.4-tem/bin/java" ]; then
    JAVA25_HOME="$HOME/.sdkman/candidates/java/25.0.4-tem"
  else
    JAVA25_HOME="${JAVA_HOME:-}"
  fi
fi
JAVA21_HOME="${JAVA21_HOME:-$HOME/.sdkman/candidates/java/21.0.12+1.1-tem}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --sets) SETS="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 3 ;;
  esac
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT"
LOG="$OUT/run.log"
# 出力先はリポジトリからの相対で見せる（生ログに実行環境の絶対パスを残さない）
rel() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;; *) printf '%s' "$1" ;; esac; }

: > "$LOG"

log() { echo "$@" | tee -a "$LOG"; }

if [ ! -x "$JAVA25_HOME/bin/java" ]; then
  echo "JDK 25 が見つかりません: $JAVA25_HOME" >&2
  exit 3
fi
HAS21=1
[ -x "$JAVA21_HOME/bin/java" ] || HAS21=0

log "=========================================="
log "$SCENARIO"
log "=========================================="
log "日時: $(date '+%Y-%m-%d %H:%M:%S %z')"
log "OS: $(uname -sr)"
log "アーキテクチャ: $(uname -m)"
log "JDK 25: $("$JAVA25_HOME/bin/java" -version 2>&1 | head -1)"
if [ "$HAS21" = "1" ]; then
  log "JDK 21: $("$JAVA21_HOME/bin/java" -version 2>&1 | head -1)"
else
  log "JDK 21: 未検出（対照はスキップ）"
fi
log "スレッド数: $THREADS / ブロック時間: ${BLOCK_MS}ms / セット数: ${SETS}（中央値で比較）"
log ""

# 1 試行を走らせ、jdk.VirtualThreadPinned の件数を標準出力へ返す。
run_once() {
  local jh="$1" arm="$2" th="$3" tag="$4"
  local jfr="$WORK/$tag.jfr"
  local opt="-XX:StartFlightRecording:settings=default,filename=$jfr,dumponexit=true"
  if [ "$th" = "zero" ]; then
    opt="-XX:StartFlightRecording:settings=default,jdk.VirtualThreadPinned#threshold=0ms,filename=$jfr,dumponexit=true"
  fi
  rm -f "$jfr"
  "$jh/bin/java" $opt "$SRC/PinDemo.java" "$arm" "$THREADS" "$BLOCK_MS" >> "$LOG" 2>&1
  local n
  n=$("$jh/bin/jfr" summary "$jfr" 2>/dev/null | grep -i "VirtualThreadPinned" | awk '{print $2}')
  echo "${n:-0}"
}

# 中央値・最小・最大を "median min max" で返す。
stats() {
  printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {
    m = (NR % 2) ? a[(NR+1)/2] : int((a[NR/2] + a[NR/2+1]) / 2 + 0.5)
    print m, a[1], a[NR]
  }'
}

declare -A N

# 1 セルを SETS 回まわす。最後のセットの JFR を $WORK/<key>.jfr に残す。
measure_cell() {
  local jh="$1" arm="$2" th="$3" key="$4" label="$5"
  local -a vals=()
  local i st
  for i in $(seq 1 "$SETS"); do
    vals+=("$(run_once "$jh" "$arm" "$th" "$key")")
  done
  st=$(stats "${vals[@]}")
  N["${key}_med"]=$(echo "$st" | awk '{print $1}')
  N["${key}_min"]=$(echo "$st" | awk '{print $2}')
  N["${key}_max"]=$(echo "$st" | awk '{print $3}')
  log "▶ $label — 中央値 ${N["${key}_med"]} 件（最小 ${N["${key}_min"]} / 最大 ${N["${key}_max"]} / 全 ${vals[*]}）"
  {
    echo "--- $key の内訳（最終セット） ---"
    "$jh/bin/jfr" print --events jdk.VirtualThreadPinned "$WORK/$key.jfr" 2>/dev/null \
      | grep -E "pinnedReason|blockingOperation|  duration" | sort | uniq -c | sort -rn
    echo "--- $key の代表スタック（先頭 1 件） ---"
    "$jh/bin/jfr" print --events jdk.VirtualThreadPinned "$WORK/$key.jfr" 2>/dev/null | head -18
  } >> "$LOG" 2>&1
}

for arm in noop sync clinit; do
  for th in default zero; do
    measure_cell "$JAVA25_HOME" "$arm" "$th" "j25_${arm}_${th}" "JDK 25 / arm=$arm / threshold=$th"
  done
done

if [ "$HAS21" = "1" ]; then
  for arm in noop sync clinit; do
    measure_cell "$JAVA21_HOME" "$arm" "default" "j21_${arm}_default" "JDK 21 / arm=$arm / threshold=default"
  done
else
  for arm in noop sync clinit; do
    N["j21_${arm}_default_med"]=-1; N["j21_${arm}_default_min"]=-1; N["j21_${arm}_default_max"]=-1
  done
fi

# clinit（JDK 25・既定閾値）の理由別内訳を数える（最終セット）
CL_JFR="$WORK/j25_clinit_default.jfr"
REASON_CLINIT=$("$JAVA25_HOME/bin/jfr" print --events jdk.VirtualThreadPinned "$CL_JFR" 2>/dev/null \
  | grep -c 'pinnedReason = "VM call to PinDemo\$SlowInit.<clinit> on stack"')
REASON_WAIT=$("$JAVA25_HOME/bin/jfr" print --events jdk.VirtualThreadPinned "$CL_JFR" 2>/dev/null \
  | grep -c 'pinnedReason = "Waited for initialization of PinDemo\$SlowInit by another thread"')

log ""
log "=========================================="
log "結果"
log "=========================================="
log "JDK 25 / 既定閾値 20ms : noop=${N[j25_noop_default_med]} sync=${N[j25_sync_default_med]} clinit=${N[j25_clinit_default_med]}"
log "JDK 25 / 閾値 0ms      : noop=${N[j25_noop_zero_med]}（${N[j25_noop_zero_min]}〜${N[j25_noop_zero_max]}） sync=${N[j25_sync_zero_med]}（${N[j25_sync_zero_min]}〜${N[j25_sync_zero_max]}） clinit=${N[j25_clinit_zero_med]}（${N[j25_clinit_zero_min]}〜${N[j25_clinit_zero_max]}）"
log "JDK 21 / 既定閾値 20ms : noop=${N[j21_noop_default_med]} sync=${N[j21_sync_default_med]} clinit=${N[j21_clinit_default_med]}"
log "JDK 25 clinit の理由別 : 初期化子の中=${REASON_CLINIT} / 他スレッドの初期化待ち=${REASON_WAIT}（最終セット）"

# json へ入れるため二重引用符を除いた版文字列を作る
JAVA25_LINE="$("$JAVA25_HOME/bin/java" -version 2>&1 | head -1 | tr -d '"')"
JAVA21_LINE="未検出"
[ "$HAS21" = "1" ] && JAVA21_LINE="$("$JAVA21_HOME/bin/java" -version 2>&1 | head -1 | tr -d '"')"

cat > "$OUT/summary.json" <<EOF_JSON
{
  "scenario": "$SCENARIO",
  "mode": "M1",
  "measures": "仮想スレッドがキャリアスレッドを手放せなくなる経路の件数と理由（閾値 2 段 × JDK 2 版 × $SETS セット中央値）",
  "env": {
    "os": "$(uname -sr)",
    "arch": "$(uname -m)",
    "java25": "$JAVA25_LINE",
    "java21": "$JAVA21_LINE"
  },
  "values": {
    "threads": $THREADS,
    "block_ms": $BLOCK_MS,
    "sets": $SETS,
    "default_threshold_ms": 20,
    "j25_noop_default": ${N[j25_noop_default_med]},
    "j25_sync_default": ${N[j25_sync_default_med]},
    "j25_clinit_default": ${N[j25_clinit_default_med]},
    "j25_noop_zero": ${N[j25_noop_zero_med]},
    "j25_noop_zero_min": ${N[j25_noop_zero_min]},
    "j25_noop_zero_max": ${N[j25_noop_zero_max]},
    "j25_sync_zero": ${N[j25_sync_zero_med]},
    "j25_sync_zero_min": ${N[j25_sync_zero_min]},
    "j25_sync_zero_max": ${N[j25_sync_zero_max]},
    "j25_clinit_zero": ${N[j25_clinit_zero_med]},
    "j25_clinit_zero_min": ${N[j25_clinit_zero_min]},
    "j25_clinit_zero_max": ${N[j25_clinit_zero_max]},
    "j21_noop_default": ${N[j21_noop_default_med]},
    "j21_sync_default": ${N[j21_sync_default_med]},
    "j21_clinit_default": ${N[j21_clinit_default_med]},
    "j25_clinit_reason_in_clinit": $REASON_CLINIT,
    "j25_clinit_reason_waited": $REASON_WAIT
  }
}
EOF_JSON

log ""
log "生ログ: $(rel "$LOG")"
log "実効値: $(rel "$OUT/summary.json")"

# 子プロセス（Maven / JVM / Docker）の出力は上の echo を直しても生ログに入るため、
# 書き終えたところで実行環境に固有の情報を落とす（tools/check-neutrality.py が検査する）
python3 "$ROOT/tools/sanitize-log.py" "$OUT"

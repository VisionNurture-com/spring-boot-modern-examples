#!/usr/bin/env bash
# シナリオ: 002-cache-pitfalls
# モード: M1（JDK 25 + Maven。GraalVM も Docker も要らない）
# 測るもの: AOT キャッシュが「効かなくなる」2 つの経路を、出力と時間の両方で観測する。
#
# 🔴 なぜ別シナリオにしたか
#   002-startup-3ways の expected.md は「落とし穴」として次の 2 件を書いていたが、
#   どちらも生ログが results/ に無く、機械照合用 json ブロックにも入っていなかった。
#   手書きで入った記述であり、check-provenance は 1 度も見ていない。
#     (1) 食い違うキャッシュは `Opened AOT cache` と表示されたまま基準より 5.4% 遅い
#     (2) clean を挟まないと jar が 21,983,358 → 22,217,180 バイトに増える
#   本シナリオは 2 件を測り直して results/ にログを残し、突合の射程へ入れる。
#
# 🔴 測って分かったこと（(1) の記述は事実と食い違っていた）
#   - jar が食い違うと、JVM は **既定の出力で warning 1 行 + error 3 行**を出す。静かではない。
#       [warning][aot] This file is not the one used while building the AOT cache: 'app.jar',
#                      timestamp has changed, size has changed
#       [error  ][aot] An error has occurred while processing the AOT cache. ...
#       [error  ][aot] shared class paths mismatch ...
#       [error  ][aot] Unable to map shared spaces
#     プロセスは終了コード 0 で起動する（キャッシュを捨てて素の起動に落ちる）。
#   - `Opened AOT cache` は **-Xlog:aot を付けたときにしか出ない**。しかも検証の *前* に
#     出る行なので、これが出ていることは効いている証拠にならない。
#   - 本当に無言なのは **展開を飛ばした場合**で、aot 関連の行が既定出力に 1 行も出ない。
#     効いていないのではなく「半分しか効いていない」ため、警告の出しようがない。
#
# 腕（3 つ・すべて展開した形で土俵をそろえる）:
#   none    キャッシュなし              ← 基準（展開だけした状態）
#   stale   作った jar と違う jar に当てる ← 食い違い
#   match   同じ jar に当てる            ← 正しく効いた状態
#
# 出力: results/002-cache-pitfalls/run.log と summary.json（--out で変更可）
# 使い方:
#   bash scenarios/002-cache-pitfalls/run.sh            # 既定 5 セット
#   bash scenarios/002-cache-pitfalls/run.sh --sets 3
#   bash scenarios/002-cache-pitfalls/run.sh --out /tmp/x
#
# 🔴 リポジトリの working tree を書き換えない。
#    jar B（コードを 1 行変えたもの）は、モジュールを一時ディレクトリへ複製してから作る。

set -euo pipefail

SCENARIO="002-cache-pitfalls"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/results/$SCENARIO"
SETS=5

while [ $# -gt 0 ]; do
  case "$1" in
    --out)   OUT="$2"; shift 2 ;;
    --sets)  SETS="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 3 ;;
  esac
done

mkdir -p "$OUT"
LOG="$OUT/run.log"
: > "$LOG"
log() { echo "$@" | tee -a "$LOG"; }

log "=== シナリオ: $SCENARIO / モード: M1 ==="
log "実行日時: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log "セット数: ${SETS}（+ 捨て走り 1 セット）"
log ""
log "--- 環境 ---"
log "os: $(uname -s) $(uname -r)"
log "arch: $(uname -m)"
log "java: $(java -version 2>&1 | head -1)"
log "maven: $(mvn -v 2>/dev/null | head -1)"
log ""

# 🔴 作業ディレクトリは /tmp 直下に取る。既定の TMPDIR はユーザー名を含む場所を指すことがあり、
#    その絶対パスが JVM の警告行に載って run.log へ残る（公開時の中立化コストになる）。
WORK="$(TMPDIR=/tmp mktemp -d /tmp/sbme-cache-pitfalls.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# --- モジュールを一時ディレクトリへ複製（リポジトリの target/ を汚さない） ---
SRC_A="$WORK/src-a"
SRC_B="$WORK/src-b"
for d in "$SRC_A" "$SRC_B"; do
  mkdir -p "$d/app"
  # 🔴 複製先には app しか置かないため、親 pom の modules も app だけに絞る。
  #    リポジトリに別のモジュール（計測対象が違うもの）が増えると、
  #    そのままでは複製先に実体が無く reactor が解決できずビルドが落ちる。
  perl -0pe 's{<modules>.*?</modules>}{<modules>\n    <module>app</module>\n  </modules>}s' \
    "$ROOT/pom.xml" > "$d/pom.xml"
  cp "$ROOT/app/pom.xml" "$d/app/pom.xml"
  cp -R "$ROOT/app/src" "$d/app/src"
done

APP_SRC="app/src/main/java/com/example/measure/MeasureApplication.java"
# jar B は「読者がコードを 1 行直して作り直した」状態。戻り値を 1 つ変えるだけ。
if ! grep -q 'return "hello";' "$SRC_B/$APP_SRC"; then
  log "🔴 jar B を作る目印 'return \"hello\";' が見つかりません（ソースの改変が必要）"
  exit 1
fi
perl -pi -e 's/return "hello";/return "hello-v2";/' "$SRC_B/$APP_SRC"

log "--- 経路 1: jar が食い違うとどうなるか ---"

build() {  # $1 = ソースディレクトリ / $2 = ラベル
  ( cd "$1" && mvn -q -B -pl app -am clean package -DskipTests ) >> "$LOG" 2>&1 \
    || { log "🔴 ビルドに失敗しました（$2）"; exit 1; }
}

build "$SRC_A" "jar A"
JAR_A_BYTES=$(wc -c < "$SRC_A/app/target/app.jar" | tr -d ' ')
log "jar A: ${JAR_A_BYTES} bytes"

build "$SRC_B" "jar B"
JAR_B_BYTES=$(wc -c < "$SRC_B/app/target/app.jar" | tr -d ' ')
log "jar B（1 行変えて作り直したもの）: ${JAR_B_BYTES} bytes"

# 展開（Spring Boot 公式の手順）
extract() {  # $1 = jar のパス / $2 = 展開先の親
  mkdir -p "$2"
  cp "$1" "$2/app.jar"
  ( cd "$2" && java -Djarmode=tools -jar app.jar extract --destination application ) >> "$LOG" 2>&1 \
    || { log "🔴 展開に失敗しました: $1"; exit 1; }
}

extract "$SRC_A/app/target/app.jar" "$WORK/stage-a"
extract "$SRC_B/app/target/app.jar" "$WORK/stage-b"

EXT_A="$WORK/stage-a/application"
EXT_B="$WORK/stage-b/application"

# jar A のキャッシュ（あとで jar B に当てて食い違わせる）
( cd "$EXT_A" && java -XX:AOTCacheOutput=app.aot -Dspring.context.exit=onRefresh -jar app.jar ) \
  >> "$LOG" 2>&1 || true
[ -f "$EXT_A/app.aot" ] || { log "🔴 jar A のキャッシュが生成されていません"; exit 1; }

# jar B 自身のキャッシュ（正しく効いた状態）
( cd "$EXT_B" && java -XX:AOTCacheOutput=new.aot -Dspring.context.exit=onRefresh -jar app.jar ) \
  >> "$LOG" 2>&1 || true
[ -f "$EXT_B/new.aot" ] || { log "🔴 jar B のキャッシュが生成されていません"; exit 1; }

cp "$EXT_A/app.aot" "$EXT_B/old.aot"
STALE_CACHE_BYTES=$(wc -c < "$EXT_B/old.aot" | tr -d ' ')
MATCH_CACHE_BYTES=$(wc -c < "$EXT_B/new.aot" | tr -d ' ')
log "jar A のキャッシュ: ${STALE_CACHE_BYTES} bytes / jar B のキャッシュ: ${MATCH_CACHE_BYTES} bytes"
log ""

# --- 既定の出力に何が出るか（-Xlog を付けない素の実行） ---
log "--- 既定の出力（-Xlog を付けずに実行したときに読者が見るもの）---"
set +e
( cd "$EXT_B" && java -XX:AOTCache=old.aot -Dspring.context.exit=onRefresh -jar app.jar ) \
  > "$WORK/stale-default.log" 2>&1
STALE_RC=$?
set -e
STALE_WARN=$(grep -c '\[warning\]\[aot\]' "$WORK/stale-default.log" || true)
STALE_ERR=$(grep -c '\[error *\]\[aot\]' "$WORK/stale-default.log" || true)
log "食い違うキャッシュ: warning ${STALE_WARN} 行 / error ${STALE_ERR} 行 / 終了コード ${STALE_RC}"
grep -E '\[(warning|error) *\]\[aot\]' "$WORK/stale-default.log" | sed 's/^/    /' | tee -a "$LOG" || true

# 展開を飛ばした場合（fat jar のままキャッシュを作って当てる）
( cd "$WORK/stage-b" && java -XX:AOTCacheOutput=fat.aot -Dspring.context.exit=onRefresh -jar app.jar ) \
  >> "$LOG" 2>&1 || true
[ -f "$WORK/stage-b/fat.aot" ] || { log "🔴 展開なしのキャッシュが生成されていません"; exit 1; }
( cd "$WORK/stage-b" && java -XX:AOTCache=fat.aot -Dspring.context.exit=onRefresh -jar app.jar ) \
  > "$WORK/skip-default.log" 2>&1 || true
SKIP_AOT_LINES=$(grep -c '\[aot\]' "$WORK/skip-default.log" || true)
log "展開を飛ばしたキャッシュ: aot 関連の行 ${SKIP_AOT_LINES} 行（0 なら既定では何も出ない）"

# `Opened AOT cache` は -Xlog:aot を付けたときだけ出る。しかも検証の前に出る。
( cd "$EXT_B" && java -Xlog:aot -XX:AOTCache=old.aot -Dspring.context.exit=onRefresh -jar app.jar ) \
  > "$WORK/stale-xlog.log" 2>&1 || true
OPENED_DEFAULT=$(grep -c 'Opened AOT cache' "$WORK/stale-default.log" || true)
OPENED_XLOG=$(grep -c 'Opened AOT cache' "$WORK/stale-xlog.log" || true)
log "「Opened AOT cache」の出現: 既定 ${OPENED_DEFAULT} 行 / -Xlog:aot 付き ${OPENED_XLOG} 行"
log ""

# --- 起動時間（ラウンドロビン・捨て走り 1 セット） ---
log "--- 起動時間（3 腕・ラウンドロビン・捨て走り 1 セット）---"

python3 - "$LOG" "$OUT/summary.json" "$SETS" "$EXT_B" \
         "$JAR_A_BYTES" "$JAR_B_BYTES" "$STALE_CACHE_BYTES" "$MATCH_CACHE_BYTES" \
         "$STALE_WARN" "$STALE_ERR" "$STALE_RC" "$SKIP_AOT_LINES" \
         "$OPENED_DEFAULT" "$OPENED_XLOG" "$WORK" <<'PYEOF'
import json, subprocess, sys, time, statistics, platform

(logpath, outpath, sets, extb, jar_a, jar_b, stale_cache, match_cache,
 stale_warn, stale_err, stale_rc, skip_lines, opened_default, opened_xlog,
 work) = sys.argv[1:16]
sets = int(sets)

EXIT = "-Dspring.context.exit=onRefresh"
CMD = {
    "none":  ["java", EXIT, "-jar", "app.jar"],
    "stale": ["java", "-XX:AOTCache=old.aot", EXIT, "-jar", "app.jar"],
    "match": ["java", "-XX:AOTCache=new.aot", EXIT, "-jar", "app.jar"],
}
ORDER = ("none", "stale", "match")

def once(m):
    t = time.perf_counter()
    r = subprocess.run(CMD[m], cwd=extb, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    d = time.perf_counter() - t
    if r.returncode != 0:
        raise SystemExit(f"🔴 {m} の起動が失敗しました（rc={r.returncode}）")
    return d

lines = []
for m in ORDER:
    lines.append(f"warmup(discard) {m}: {once(m):.3f}s")

samples = {m: [] for m in ORDER}
for s in range(1, sets + 1):
    row = []
    for m in ORDER:
        d = once(m)
        samples[m].append(d)
        row.append(f"{m}={d:.3f}")
    lines.append(f"set {s}: " + "  ".join(row))

values = {
    "sets": sets,
    "arms": ",".join(ORDER),
    "jar_a_bytes": int(jar_a),
    "jar_b_bytes": int(jar_b),
    "stale_cache_bytes": int(stale_cache),
    "match_cache_bytes": int(match_cache),
}
for m in ORDER:
    v = sorted(samples[m])
    values[f"{m}_median_s"] = round(statistics.median(v), 3)
    values[f"{m}_min_s"] = round(v[0], 3)
    values[f"{m}_max_s"] = round(v[-1], 3)

base = values["none_median_s"]
values["stale_vs_none_pct"] = round((values["stale_median_s"] - base) / base * 100, 1)
values["match_vs_none_pct"] = round((values["match_median_s"] - base) / base * 100, 1)

values["stale_default_warning_lines"] = int(stale_warn)
values["stale_default_error_lines"] = int(stale_err)
values["stale_exit_code"] = int(stale_rc)
values["skip_extract_default_aot_lines"] = int(skip_lines)
values["opened_msg_default_lines"] = int(opened_default)
values["opened_msg_xlog_lines"] = int(opened_xlog)

lines.append("")
for m in ORDER:
    tail = "  （基準）" if m == "none" else f"  対 キャッシュなし {values[f'{m}_vs_none_pct']:+.1f}%"
    lines.append(f"{m:6s} median {values[f'{m}_median_s']:.3f}s  "
                 f"min {values[f'{m}_min_s']:.3f}s  max {values[f'{m}_max_s']:.3f}s" + tail)

with open(logpath, "a") as f:
    f.write("\n".join(lines) + "\n")
print("\n".join(lines))

with open(f"{work}/values.json", "w") as f:
    json.dump(values, f, ensure_ascii=False)

summary = {
    "scenario": "002-cache-pitfalls",
    "mode": "M1",
    "measures": "AOT キャッシュが効かなくなる 2 経路（jar の食い違い / clean を挟まない汚染）の出力と時間",
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
PYEOF

log ""
log "--- 経路 2: clean を挟まないと素の jar に何が混ざるか ---"

# 1) clean あり（素の jar）
( cd "$SRC_A" && mvn -q -B -pl app -am clean package -DskipTests ) >> "$LOG" 2>&1
JAR_CLEAN_BYTES=$(wc -c < "$SRC_A/app/target/app.jar" | tr -d ' ')
log "clean あり: ${JAR_CLEAN_BYTES} bytes"

# 2) native プロファイルを走らせる（spring-boot:process-aot が生成クラスを target/classes へ置く）
( cd "$SRC_A" && mvn -q -B -pl app -Pnative package -DskipTests ) >> "$LOG" 2>&1
# 3) clean を挟まずに素の package を打ち直す（読者が普通にやること）
( cd "$SRC_A" && mvn -q -B -pl app -am package -DskipTests ) >> "$LOG" 2>&1
JAR_DIRTY_BYTES=$(wc -c < "$SRC_A/app/target/app.jar" | tr -d ' ')
AOT_CLASSES=$(unzip -l "$SRC_A/app/target/app.jar" \
  | grep -cE 'BOOT-INF/classes/.*(__BeanDefinitions|__BeanFactoryRegistrations|__ApplicationContextInitializer)\.class' || true)
log "clean なし: ${JAR_DIRTY_BYTES} bytes（差 $((JAR_DIRTY_BYTES - JAR_CLEAN_BYTES)) bytes / Spring AOT 生成クラス ${AOT_CLASSES} 件）"

python3 - "$OUT/summary.json" "$WORK/values.json" \
         "$JAR_CLEAN_BYTES" "$JAR_DIRTY_BYTES" "$AOT_CLASSES" <<'PYEOF'
import json, sys
outpath, valuespath, clean_b, dirty_b, classes = sys.argv[1:6]
summary = json.load(open(outpath))
v = summary["values"]
v["jar_clean_bytes"] = int(clean_b)
v["jar_dirty_bytes"] = int(dirty_b)
v["jar_dirty_delta_bytes"] = int(dirty_b) - int(clean_b)
v["aot_generated_classes"] = int(classes)
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

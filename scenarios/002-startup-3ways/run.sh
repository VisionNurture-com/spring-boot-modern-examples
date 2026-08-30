#!/usr/bin/env bash
# シナリオ: 002-startup-3ways
# モード: M3（JDK 25 + Maven + GraalVM。Docker 不要）
# 測るもの: Spring Boot の起動を速くする 3 手段を、同一アプリ・同一機体で比較する。
#           素の JVM / JVM AOT キャッシュ（JEP 483 + JEP 514）/ GraalVM Native Image。
#
# 🔴 AOT キャッシュは「展開した形」で使う（Spring Boot 公式の手順）
#   docs.spring.io は次のとおり明記している。
#     "To use the AOT cache feature, you should first perform a training run on your
#      application in extracted form"
#     "You have to use the cache file with the extracted form of the application,
#      otherwise it has no effect."
#   これは JEP 483 の Non-Goals と整合する。
#     "It is not a goal to cache classes that are loaded by user-defined class loaders.
#      Only classes loaded from the class path, the module path, and the JDK itself,
#      by the JDK's built-in class loaders, can be cached."
#   実行可能 jar はアプリのクラスを独自のクラスローダで読むため、展開しないと
#   アプリのクラスがキャッシュ対象から外れる。
#   実測（各 5 回・中央値）: 素 0.904s / 展開せずにキャッシュ 0.638s（-29.4%）/
#                            展開してキャッシュ 0.422s（-53.3%）。約 1.8 倍の差が出る。
#
# 🔴 測定設計（意図的な選択）
#   1) 基準（素の JVM・実行可能 jar のまま）は本シナリオが唯一持つ。他シナリオで測り直さない。
#   2) ブロック実行（A を N 回 → B を N 回）ではなく **ラウンドロビン**（1 セットで全方式を
#      隣り合わせる）で回す。機体の熱・背景負荷を全方式へ均等に乗せるため。
#   3) 捨て走りを 1 セット行い記録しない。初回のページキャッシュ効果を特定の方式へ
#      乗せないため。
#   4) 展開だけした腕（jvmx）を置く。展開そのものの寄与と、キャッシュの寄与を分けるため。
#   5) 展開せずにキャッシュを当てた腕（aotfat）を置く。手順を飛ばしたときに何が起きるかを
#      読者へ示すため。
#
# 腕（方式）の意味:
#   jvm     素の JVM・実行可能 jar のまま       ← 基準。多くの人の出発点
#   jvmx    素の JVM・展開した形               ← 展開そのものの寄与を見る
#   aotfat  AOT キャッシュ・展開せずに当てる    ← 手順を飛ばした場合
#   aot     AOT キャッシュ・展開した形         ← 公式の手順
#   native  GraalVM Native Image
#
# 出力: results/002-startup-3ways/run.log と summary.json（--out で変更可）
# 使い方:
#   bash scenarios/002-startup-3ways/run.sh                        # 既定 7 セット・5 腕
#   bash scenarios/002-startup-3ways/run.sh --sets 3               # セット数を変える
#   bash scenarios/002-startup-3ways/run.sh --methods jvm,aot      # GraalVM なしで試す
#   bash scenarios/002-startup-3ways/run.sh --out /tmp/x           # 出力先を変える
#
# 🔴 --methods で腕を減らした結果を results/ へ書かないこと。
#    リポジトリにコミットする summary.json は常に全腕そろった全量とする。
#    （部分実行は必ず --out で別ディレクトリへ逃がす）

set -euo pipefail

SCENARIO="002-startup-3ways"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/results/$SCENARIO"
SETS=7
ALL_METHODS="jvm,jvmx,aotfat,aot,native"
METHODS="$ALL_METHODS"
GRAALVM_HOME_ARG="${GRAALVM_HOME:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --out)           OUT="$2"; shift 2 ;;
    --sets)          SETS="$2"; shift 2 ;;
    --methods)       METHODS="$2"; shift 2 ;;
    --graalvm-home)  GRAALVM_HOME_ARG="$2"; shift 2 ;;
    *) echo "不明な引数: $1" >&2; exit 3 ;;
  esac
done

case ",$METHODS," in *,jvm,*)    WANT_JVM=1 ;;    *) WANT_JVM=0 ;; esac
case ",$METHODS," in *,jvmx,*)   WANT_JVMX=1 ;;   *) WANT_JVMX=0 ;; esac
case ",$METHODS," in *,aotfat,*) WANT_AOTFAT=1 ;; *) WANT_AOTFAT=0 ;; esac
case ",$METHODS," in *,aot,*)    WANT_AOT=1 ;;    *) WANT_AOT=0 ;; esac
case ",$METHODS," in *,native,*) WANT_NATIVE=1 ;; *) WANT_NATIVE=0 ;; esac
# 展開が要るのは jvmx / aot
WANT_EXTRACT=0
[ "$WANT_JVMX" = "1" ] && WANT_EXTRACT=1
[ "$WANT_AOT" = "1" ] && WANT_EXTRACT=1

if [ "$OUT" = "$ROOT/results/$SCENARIO" ] && [ "$METHODS" != "$ALL_METHODS" ]; then
  echo "🔴 腕を減らした結果を results/ へ書こうとしています。--out で別ディレクトリを指定してください。" >&2
  exit 3
fi

mkdir -p "$OUT"
LOG="$OUT/run.log"
: > "$LOG"
log() { echo "$@" | tee -a "$LOG"; }

log "=== シナリオ: $SCENARIO / モード: M3 ==="
log "実行日時: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log "腕: $METHODS / セット数: ${SETS}（+ 捨て走り 1 セット）"
log ""
log "--- 環境 ---"
log "os: $(uname -s) $(uname -r)"
log "arch: $(uname -m)"
log "java: $(java -version 2>&1 | head -1)"
log "maven: $(mvn -v 2>/dev/null | head -1)"

# GraalVM の解決（native を測るときのみ必須）
NATIVE_BIN=""
if [ "$WANT_NATIVE" = "1" ]; then
  if [ -z "$GRAALVM_HOME_ARG" ] && [ -d "$HOME/.sdkman/candidates/java/25.0.2-graalce" ]; then
    GRAALVM_HOME_ARG="$HOME/.sdkman/candidates/java/25.0.2-graalce"
  fi
  if [ -z "$GRAALVM_HOME_ARG" ] || [ ! -x "$GRAALVM_HOME_ARG/bin/native-image" ]; then
    log "🔴 GraalVM が見つかりません。--graalvm-home か GRAALVM_HOME を指定するか、--methods jvm,jvmx,aotfat,aot を使ってください。"
    exit 3
  fi
  log "graalvm: $("$GRAALVM_HOME_ARG/bin/native-image" --version 2>&1 | head -1)"
fi
log ""

log "--- 成果物をすべて先に揃える（計測の前にビルドを終わらせる）---"
# 🔴 clean を必ず挟む。挟まないと前回の Native Image ビルドが target/classes へ残した
#    Spring AOT 生成クラスが素の jar に混ざり、実行前の状態で結果が変わる
#    （実測: 素の jar 21,983,846 bytes / 混入した jar 22,217,685 bytes。scenarios/002-cache-pitfalls 参照）。
( cd "$ROOT" && mvn -q -B -pl app -am clean package -DskipTests ) 2>&1 | tee -a "$LOG"
BUILT_JAR="$ROOT/app/target/app.jar"
[ -f "$BUILT_JAR" ] || { log "🔴 jar が生成されていません: $BUILT_JAR"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 🔴 素の jar を退避してから計測に使う。
#    後段の Native Image ビルド（-Pnative package）は spring-boot:process-aot を走らせ
#    target/app.jar を作り直す。退避しないと、AOT キャッシュを作った jar と
#    計測に使う jar が食い違い、**キャッシュが捨てられて付けないときより遅くなる**
#    （既定の出力に warning 1 行 + error 3 行。実測は scenarios/002-cache-pitfalls）。
JAR="$WORK/app.jar"
cp "$BUILT_JAR" "$JAR"
JAR_BYTES=$(wc -c < "$JAR" | tr -d ' ')
log "jar: $JAR ($JAR_BYTES bytes)  ← target から退避した素の jar"

EXT_DIR="$WORK/application"
EXT_BYTES=0
if [ "$WANT_EXTRACT" = "1" ]; then
  log ""
  log "--- 展開（Spring Boot 公式の手順）---"
  ( cd "$WORK" && java -Djarmode=tools -jar app.jar extract --destination application ) > "$WORK/extract.log" 2>&1 || {
    log "🔴 展開に失敗しました"; tail -20 "$WORK/extract.log" | tee -a "$LOG"; exit 1; }
  [ -f "$EXT_DIR/app.jar" ] || { log "🔴 展開後に app.jar がありません"; exit 1; }
  EXT_BYTES=$(find "$EXT_DIR" -type f -exec wc -c {} + | tail -1 | awk '{print $1}')
  log "展開先: ${EXT_DIR} 中身: $(ls "$EXT_DIR" | tr '\n' ' ')/ 合計 ${EXT_BYTES} bytes"
fi

FAT_CACHE="$WORK/fat.aot"
EXT_CACHE="$EXT_DIR/app.aot"
FAT_CACHE_BYTES=0; FAT_AOT_WARNINGS=0
CACHE_BYTES=0;     AOT_WARNINGS=0
AOT_BUILD_SEC=0;   FAT_AOT_BUILD_SEC=0

if [ "$WANT_AOTFAT" = "1" ]; then
  log ""
  log "--- AOT キャッシュ生成・展開せずに当てる（手順を飛ばした場合）---"
  T0=$(date +%s)
  ( cd "$WORK" && java -XX:AOTCacheOutput=fat.aot -Dspring.context.exit=onRefresh -jar app.jar ) > "$WORK/aot-fat-build.log" 2>&1 || true
  FAT_AOT_BUILD_SEC=$(( $(date +%s) - T0 ))
  cat "$WORK/aot-fat-build.log" >> "$LOG"
  [ -f "$FAT_CACHE" ] || { log "🔴 キャッシュが生成されていません（展開なし）"; exit 1; }
  FAT_CACHE_BYTES=$(wc -c < "$FAT_CACHE" | tr -d ' ')
  FAT_AOT_WARNINGS=$(grep -c 'warning..aot' "$WORK/aot-fat-build.log" || true)
  log "cache(展開なし): $FAT_CACHE ($FAT_CACHE_BYTES bytes) / build ${FAT_AOT_BUILD_SEC}s / 警告 ${FAT_AOT_WARNINGS} 件"
fi

if [ "$WANT_AOT" = "1" ]; then
  log ""
  log "--- AOT キャッシュ生成・展開した形（公式の手順）---"
  T0=$(date +%s)
  ( cd "$EXT_DIR" && java -XX:AOTCacheOutput=app.aot -Dspring.context.exit=onRefresh -jar app.jar ) > "$EXT_DIR/aot-build.log" 2>&1 || true
  AOT_BUILD_SEC=$(( $(date +%s) - T0 ))
  cat "$EXT_DIR/aot-build.log" >> "$LOG"
  [ -f "$EXT_CACHE" ] || { log "🔴 キャッシュが生成されていません（展開あり）"; exit 1; }
  CACHE_BYTES=$(wc -c < "$EXT_CACHE" | tr -d ' ')
  AOT_WARNINGS=$(grep -c 'warning..aot' "$EXT_DIR/aot-build.log" || true)
  log "cache(展開あり): $EXT_CACHE ($CACHE_BYTES bytes) / build ${AOT_BUILD_SEC}s / 警告 ${AOT_WARNINGS} 件"
fi

NATIVE_BYTES=0
NATIVE_BUILD_SEC=0
NATIVE_PEAK_GB=0
if [ "$WANT_NATIVE" = "1" ]; then
  log ""
  log "--- Native Image ビルド（GraalVM）---"
  NATIVE_BUILD_START=$(date +%s)
  # 🔴 native プロファイルは add-reachability-metadata しか bind しない。
  #    native:compile-no-fork を明示する（Spring Boot 公式の作法）。
  #    -am を付けると親（pom packaging）にも goal が走り "Image classpath is empty" で落ちる。
  ( cd "$ROOT" && JAVA_HOME="$GRAALVM_HOME_ARG" PATH="$GRAALVM_HOME_ARG/bin:$PATH" \
      mvn -B -Pnative -pl app package native:compile-no-fork -DskipTests ) > "$WORK/native-build.log" 2>&1 || {
        log "🔴 Native Image のビルドに失敗しました"; tail -20 "$WORK/native-build.log" | tee -a "$LOG"; exit 1; }
  NATIVE_BUILD_SEC=$(( $(date +%s) - NATIVE_BUILD_START ))
  NATIVE_BIN="$ROOT/app/target/app"
  [ -x "$NATIVE_BIN" ] || { log "🔴 ネイティブバイナリがありません: $NATIVE_BIN"; exit 1; }
  NATIVE_BYTES=$(wc -c < "$NATIVE_BIN" | tr -d ' ')
  # native-image の各段が報告するピークメモリの最大値（005「CI で回るか」の材料）
  NATIVE_PEAK_GB=$(grep -oE '@ [0-9]+\.[0-9]+GB' "$WORK/native-build.log" \
    | grep -oE '[0-9]+\.[0-9]+' | sort -g | tail -1)
  NATIVE_PEAK_GB=${NATIVE_PEAK_GB:-0}
  log "native: $NATIVE_BIN ($NATIVE_BYTES bytes) / build ${NATIVE_BUILD_SEC}s / peak ${NATIVE_PEAK_GB}GB"
fi

log ""
log "--- 計測（ラウンドロビン・捨て走り 1 セット）---"

python3 - "$LOG" "$OUT/summary.json" "$SETS" "$METHODS" \
         "$WORK" "$EXT_DIR" "${NATIVE_BIN:-}" \
         "$JAR_BYTES" "$EXT_BYTES" "$FAT_CACHE_BYTES" "$CACHE_BYTES" "$NATIVE_BYTES" \
         "$FAT_AOT_BUILD_SEC" "$AOT_BUILD_SEC" "$NATIVE_BUILD_SEC" \
         "$FAT_AOT_WARNINGS" "$AOT_WARNINGS" "$NATIVE_PEAK_GB" <<'PYEOF'
import json, subprocess, sys, time, statistics, platform

(logpath, outpath, sets, methods, work, extdir, native_bin,
 jar_bytes, ext_bytes, fat_cache_bytes, cache_bytes, native_bytes,
 fat_aot_build_sec, aot_build_sec, native_build_sec,
 fat_aot_warnings, aot_warnings, native_peak_gb) = sys.argv[1:19]
sets = int(sets)
ORDER = ("jvm", "jvmx", "aotfat", "aot", "native")
wanted = [m for m in ORDER if m in methods.split(",")]

EXIT = "-Dspring.context.exit=onRefresh"
CMD = {
    "jvm":    (work,   ["java", EXIT, "-jar", "app.jar"]),
    "jvmx":   (extdir, ["java", EXIT, "-jar", "app.jar"]),
    "aotfat": (work,   ["java", "-XX:AOTCache=fat.aot", EXIT, "-jar", "app.jar"]),
    "aot":    (extdir, ["java", "-XX:AOTCache=app.aot", EXIT, "-jar", "app.jar"]),
    "native": (work,   [native_bin, EXIT] if native_bin else None),
}

def once(m):
    cwd, cmd = CMD[m]
    t = time.perf_counter()
    r = subprocess.run(cmd, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    d = time.perf_counter() - t
    if r.returncode != 0:
        raise SystemExit(f"🔴 {m} の起動が失敗しました（rc={r.returncode}）")
    return d

lines = []
for m in wanted:                      # 捨て走り 1 セット（記録しない）
    lines.append(f"warmup(discard) {m}: {once(m):.3f}s")

samples = {m: [] for m in wanted}
for s in range(1, sets + 1):
    row = []
    for m in wanted:                  # ← 同じセット内で全腕が隣り合う
        d = once(m)
        samples[m].append(d)
        row.append(f"{m}={d:.3f}")
    lines.append(f"set {s}: " + "  ".join(row))

values = {"sets": sets, "methods": ",".join(wanted), "jar_bytes": int(jar_bytes)}
for m in wanted:
    v = sorted(samples[m])
    values[f"{m}_median_s"] = round(statistics.median(v), 3)
    values[f"{m}_min_s"] = round(v[0], 3)
    values[f"{m}_max_s"] = round(v[-1], 3)

if "jvm" in wanted:
    base = values["jvm_median_s"]
    for m in wanted:
        if m != "jvm":
            values[f"{m}_reduction_pct"] = round((base - values[f"{m}_median_s"]) / base * 100, 1)

if "jvmx" in wanted:
    values["extracted_total_bytes"] = int(ext_bytes)
if "aotfat" in wanted:
    values["aotfat_cache_bytes"] = int(fat_cache_bytes)
    values["aotfat_build_sec"] = int(fat_aot_build_sec)
    values["aotfat_build_warnings"] = int(fat_aot_warnings)
if "aot" in wanted:
    values["aot_cache_bytes"] = int(cache_bytes)
    values["aot_build_sec"] = int(aot_build_sec)
    values["aot_build_warnings"] = int(aot_warnings)
if "native" in wanted:
    values["native_binary_bytes"] = int(native_bytes)
    values["native_build_sec"] = int(native_build_sec)
    values["native_build_peak_gb"] = float(native_peak_gb)

lines.append("")
for m in wanted:
    lines.append(f"{m:7s} median {values[f'{m}_median_s']:.3f}s  min {values[f'{m}_min_s']:.3f}s  max {values[f'{m}_max_s']:.3f}s"
                 + (f"  短縮 {values[f'{m}_reduction_pct']}%" if f"{m}_reduction_pct" in values else "  （基準）"))

with open(logpath, "a") as f:
    f.write("\n".join(lines) + "\n")
print("\n".join(lines))

summary = {
    "scenario": "002-startup-3ways",
    "mode": "M3",
    "measures": "Spring context refresh までのプロセス実時間（ラウンドロビン・捨て走り 1 セット）",
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

#!/usr/bin/env bash
# シナリオ: 004-image-size
# モード: M2（JDK 25 + Maven + Docker）
# 測るもの: 同じ Spring Boot アプリを「作り方 3 通り × 土台 3 種 = 9 イメージ」で作り、
#           サイズ（圧縮後 / 展開後 / レイヤ内訳）・pull の転送バイト数・起動時間を測る。
#
# 🔴 測定設計（意図的な選択）
#   1) 主指標は「転送バイト数」であって時間ではない。ローカルレジストリは帯域が実質無限で、
#      75 MB と 127 MB が同じ秒数になりうる。時間だけを見ると「サイズは効かない」という
#      結論が測り方の産物になる。バイト数なら帯域あたりの秒数へ読者が換算できる。
#   2) 「サイズ」を 3 通りに分けて出す。
#      - registry_bytes  : レジストリの層 + config の合計（= pull で転送されるバイト数・gzip 済み）
#      - inspect_bytes   : docker image inspect の .Size
#      - expanded_bytes  : docker export した rootfs の tar のバイト数（= 実際に展開される中身）
#      🔴 **inspect_bytes の意味は image store と Docker の版で変わる。**containerd image store では
#      Docker 29.7.2 まで圧縮後にほぼ一致したが（2026-08-29 実測: eclipse-temurin:25-jre は inspect
#      114,740,584 / export 360,823,296）、29.8.0 で unpacked snapshot usage を含むよう直され
#      （moby/moby#53426）、29.8.1 では展開後より大きい値を返す（2026-10-03 実測）。
#      ⚠️ 旧来の graph driver（overlay2）では .Size は展開後を指す。**未検証**（本測定では
#      containerd image store のみ）。数を出すときは必ずどの数かを名前に書く。
#   3) 2 回目の pull を測るときは、対照（1 層も持たない状態）を作ってから測る。
#      持ったまま測ると 0 秒になり、それが速さなのか命中なのか判別できない。
#      🔴 イメージと土台を消しても、docker build が取り込んだ層は**ビルドのキャッシュが持ち続ける**
#      （containerd image store では同じ層を共有する）。そのためビルドは専用の buildx ビルダー
#      （docker-container ドライバ）で行い、キャッシュを手元の image store から切り離す。
#      さらに pull は -q を付けずに打ち、Already exists の層を数える。1 層でも残っていれば
#      その回の秒数は「空からの pull」ではないため status を partial にする。
#   4) 単一アーキで揃える。AOT キャッシュはビルド機のアーキに依存するため、
#      クロスビルドを混ぜると起動時間の比較が壊れる。
#   5) 効かない条件だけでなく効く条件も測れる形にする（土台を 3 種振る）。
#   6) 削除するのは本スクリプトが導入したイメージだけ。実行前から手元にあった
#      イメージには触れない（触れられない場合は当該測定を「未測定」と記録する）。
#
# ⚠️ 起動時間には docker run の起動オーバーヘッドが含まれる。素の JVM 起動だけを見たい場合は
#    scenarios/002-startup-3ways を参照すること。本シナリオが見るのは「土台と作り方を変えても
#    起動が動くか」であって、起動手段の優劣ではない。
#
# 前提: Docker が動いていること。JDK 25 と Maven が使えること。
#
# 使い方:
#   bash scenarios/004-image-size/run.sh
#   bash scenarios/004-image-size/run.sh --starts 1 --out /tmp/x
#   bash scenarios/004-image-size/run.sh --skip-pull       # pull 計測を飛ばす
#   bash scenarios/004-image-size/run.sh --allow-base-removal
#       ↑ 実行前から手元にあった土台も消して「何も持っていない状態」を作る。
#         本シリーズの作業で入れた土台だと操作者が確認したときだけ使う。

set -uo pipefail

SCENARIO="004-image-size"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/results/$SCENARIO"
STARTS=3
REG_PORT=5001
REG_PORT_EXPLICIT=0
REG_NAME="sbme-img-registry"
REG_IMAGE="registry:3"
DO_PULL=1
# 実行前から手元にあった土台を消してよいか。既定は消さない（他の作業を壊さないため）。
# 本シリーズの作業で導入した土台であることを操作者が確認したときだけ 1 にする。
ALLOW_BASE_RM=0

WRAPS=(w1 w2 w3)
BASES=(b1 b2 b3)
base_image() {
  case "$1" in
    b1) echo "eclipse-temurin:25-jre" ;;
    b2) echo "bellsoft/liberica-openjre-debian:25-cds" ;;
    b3) echo "eclipse-temurin:25-jre-alpine" ;;
  esac
}
wrap_label() {
  case "$1" in
    w1) echo "素の jar をそのまま入れる" ;;
    w2) echo "レイヤ抽出（公式の手順）" ;;
    w3) echo "レイヤ抽出 + AOT キャッシュ" ;;
  esac
}

JAVA25_HOME="${JAVA25_HOME:-}"
if [ -z "${JAVA25_HOME}" ]; then
  if [ -x "$HOME/.sdkman/candidates/java/25.0.4-tem/bin/java" ]; then
    JAVA25_HOME="$HOME/.sdkman/candidates/java/25.0.4-tem"
  else
    JAVA25_HOME="${JAVA_HOME:-}"
  fi
fi
MVN_BIN="${MVN_BIN:-}"
if [ -z "${MVN_BIN}" ]; then
  if [ -x "/tmp/apache-maven-3.9.16/bin/mvn" ]; then
    MVN_BIN="/tmp/apache-maven-3.9.16/bin/mvn"
  else
    MVN_BIN="mvn"
  fi
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --starts) STARTS="$2"; shift 2 ;;
    --port) REG_PORT="$2"; REG_PORT_EXPLICIT=1; shift 2 ;;
    --skip-pull) DO_PULL=0; shift ;;
    --allow-base-removal) ALLOW_BASE_RM=1; shift ;;
    *) echo "不明な引数: $1" >&2; exit 3 ;;
  esac
done

mkdir -p "$OUT"
# ホストのポートは既定では実行時に空きを選ぶ（決め打ちだと、その番号が埋まっている
# 機体で docker run が daemon のエラーで落ちる）。空いていれば 5001 のままになる。
# --port で明示されたときは選び直さず、埋まっていれば理由を出して止まる。
if [ "$REG_PORT_EXPLICIT" -eq 1 ]; then
  python3 - "$REG_PORT" <<'PYPORT' || { echo "指定されたポート ${REG_PORT} は使用中です" >&2; exit 3; }
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("0.0.0.0", int(sys.argv[1])))   # tools/free-port.py と同じ理由で 0.0.0.0 を見る
except OSError:
    sys.exit(1)
finally:
    s.close()
PYPORT
else
  REG_PORT="$(python3 "$ROOT/tools/free-port.py" "$REG_PORT")" || {
    echo "ローカルレジストリ用の空きポートを確保できません" >&2; exit 3; }
fi

LOG_FINAL="$OUT/run.log"
# 最後まで通るまでは別名に書き、通ったときだけ run.log を置き換える。
# 途中で止まった回が、前回の生ログ（expected.md の値の出どころ）を消さないようにするため。
LOG="$OUT/run.log.partial"
# 出力先はリポジトリからの相対で見せる（生ログに実行環境の絶対パスを残さない）
rel() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;; *) printf '%s' "$1" ;; esac; }

: > "$LOG"
log() { echo "$@" | tee -a "$LOG"; }
# 途中で止まったら、この回の生ログを run.failed.log へ移して知らせる（run.log は前回のまま）
keep_failed_log() {
  if [ -f "$LOG" ]; then
    mv "$LOG" "$OUT/run.failed.log"
    echo "🔴 途中で止まりました。この回の生ログ: $(rel "$OUT/run.failed.log")（$(rel "$LOG_FINAL") は前回のまま）" >&2
  fi
}
trap keep_failed_log EXIT

command -v docker >/dev/null 2>&1 || { echo "docker が見つかりません" >&2; exit 3; }
docker info >/dev/null 2>&1 || { echo "docker デーモンに接続できません" >&2; exit 3; }
[ -n "${JAVA25_HOME}" ] && [ -x "${JAVA25_HOME}/bin/java" ] || { echo "JDK 25 が見つかりません" >&2; exit 3; }

WORK="$(mktemp -d)"
CTX="$WORK/ctx"
mkdir -p "$CTX"
cleanup() {
  docker rm -f "$REG_NAME" >/dev/null 2>&1
  docker buildx rm "${BUILDER:-sbme004-builder}" >/dev/null 2>&1
  # BuildKit のイメージは、本スクリプトが入れたときだけ消す
  [ "${BUILDKIT_PRE:-1}" = "0" ] && docker image rm "${BUILDKIT_IMAGE}" >/dev/null 2>&1
  rm -rf "$WORK"
  keep_failed_log
}
trap cleanup EXIT

log "=========================================="
log "シナリオ: ${SCENARIO}（M2）"
log "開始: $(date '+%Y-%m-%d %H:%M:%S')"
log "=========================================="
log "OS: $(uname -sr) / $(uname -m)"
log "docker: $(docker version --format '{{.Server.Version}}')"
log "java: $(${JAVA25_HOME}/bin/java -version 2>&1 | head -1)"
log "maven: $(${MVN_BIN} -v 2>/dev/null | head -1)"
log "起動計測の回数: ${STARTS}"

# ---- 1. jar を作る ----------------------------------------------------------
log ""
log "--- jar をビルドする ---"
( cd "$ROOT" && JAVA_HOME="${JAVA25_HOME}" "${MVN_BIN}" -q -B -pl app -am package -DskipTests ) >> "$LOG" 2>&1 \
  || { log "🔴 jar のビルドに失敗しました"; exit 1; }
JAR="$ROOT/app/target/app.jar"
[ -f "$JAR" ] || { log "🔴 jar がありません: $JAR"; exit 1; }
cp "$JAR" "$CTX/app.jar"
JAR_BYTES=$(wc -c < "$CTX/app.jar" | tr -d ' ')
log "jar: ${JAR_BYTES} bytes"

# アプリの層だけを変えた v2 の jar を作る。
# 依存は 1 バイトも変えず、BOOT-INF/classes にファイルを 1 つ足すだけ。
cp "$CTX/app.jar" "$CTX/app-v2.jar"
( cd "$WORK" && mkdir -p BOOT-INF/classes && date +%s > BOOT-INF/classes/build-id.txt \
  && zip -q "$CTX/app-v2.jar" BOOT-INF/classes/build-id.txt ) >> "$LOG" 2>&1 \
  || { log "🔴 v2 の jar を作れませんでした"; exit 1; }
JAR_V2_BYTES=$(wc -c < "$CTX/app-v2.jar" | tr -d ' ')
log "jar(v2・アプリの層だけ変更): ${JAR_V2_BYTES} bytes"

# ---- 2. 土台の版を記録する --------------------------------------------------
log ""
log "--- 土台（ベースイメージ）---"
BASE_INFO="$WORK/base-info.txt"
: > "$BASE_INFO"
for b in "${BASES[@]}"; do
  img="$(base_image "$b")"
  PRE=1
  docker image inspect "$img" >/dev/null 2>&1 || PRE=0
  # 🔴 実行前から手元にある土台は、タグの現在値より古いことがある（2026-10-03 に実際に起きた:
  #    7 日前に取得した eclipse-temurin:25-jre を測り、タグはその後に新しい中身へ進んでいた）。
  #    古い土台を測ると、転送量も起動も「いまタグで引く読者の値」にならない。
  if [ "$PRE" = "1" ]; then
    LOCAL_DG=$(docker image inspect "$img" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' | sed 's/.*@//')
    REMOTE_DG=$(docker buildx imagetools inspect "$img" --format '{{json .Manifest}}' 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("digest",""))' 2>/dev/null)
    if [ -n "$REMOTE_DG" ] && [ "$LOCAL_DG" != "$REMOTE_DG" ]; then
      if [ "$ALLOW_BASE_RM" = "1" ]; then
        log "  ${b} ${img}: 手元のダイジェスト ${LOCAL_DG:-なし} がタグの現在値 ${REMOTE_DG} と違うため、消して取り直します"
        docker image rm "$img" >> "$LOG" 2>&1 || { log "🔴 $img を消せません（使用中のコンテナがないか確かめてください）"; exit 1; }
        PRE=0
      else
        log "🔴 ${b} ${img}: 手元のダイジェスト ${LOCAL_DG:-なし} がタグの現在値 ${REMOTE_DG} と違います"
        log "   古い土台のまま測ると、いまタグで引く読者の値になりません。"
        log "   docker image rm ${img} で消すか、--allow-base-removal を付けて実行してください。"
        exit 3
      fi
    fi
  fi
  if [ "$PRE" = "0" ]; then
    docker pull -q "$img" >> "$LOG" 2>&1 || { log "🔴 $img を pull できません"; exit 1; }
  fi
  dg=$(docker image inspect "$img" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}(digest なし){{end}}')
  sz=$(docker image inspect "$img" --format '{{.Size}}')
  cid=$(docker create "$img" 2>>"$LOG")
  if [ -n "$cid" ]; then
    ex=$(docker export "$cid" | wc -c | tr -d ' ')
    docker rm -f "$cid" >/dev/null 2>&1
  else
    ex=-1
  fi
  echo "$b|$img|$dg|$sz|$PRE|$ex" >> "$BASE_INFO"
  log "  $b $img"
  log "     digest: $dg"
  log "     inspect: ${sz} bytes / 展開後: ${ex} bytes / 実行前から手元にあったか: $([ "$PRE" = 1 ] && echo あり || echo なし)"
done

# ---- 3. ローカルレジストリを立てる ------------------------------------------
log ""
log "--- ローカルレジストリ（${REG_IMAGE}・:${REG_PORT}）---"
docker rm -f "$REG_NAME" >/dev/null 2>&1
docker image inspect "$REG_IMAGE" >/dev/null 2>&1 || docker pull -q "$REG_IMAGE" >> "$LOG" 2>&1
REG_DIGEST=$(docker image inspect "$REG_IMAGE" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}(digest なし){{end}}')
docker run -d --name "$REG_NAME" -p "${REG_PORT}:5000" "$REG_IMAGE" >> "$LOG" 2>&1 \
  || { log "🔴 レジストリを起動できません"; exit 1; }
for _ in $(seq 1 30); do
  curl -fs "http://localhost:${REG_PORT}/v2/" >/dev/null 2>&1 && break
  sleep 1
done
curl -fs "http://localhost:${REG_PORT}/v2/" >/dev/null 2>&1 \
  || { log "🔴 レジストリが応答しません"; exit 1; }
log "  起動しました: $REG_DIGEST"

# ---- 3b. 専用のビルダーを立てる ----------------------------------------------
# 既定のビルダーで作ると、その層がビルドのキャッシュに残り、7 の「何も持っていない状態」を
# 作れない。専用ビルダーのキャッシュはビルダーのコンテナの中にあり、終わったらビルダーごと消す。
# 読者の既定のビルダーとそのキャッシュには触れない。
BUILDER="sbme004-builder"
BUILDKIT_IMAGE="moby/buildkit:v0.33.0"   # Docker 29.8 に同梱の BuildKit と同じ版
BUILDKIT_PRE=0
docker image inspect "$BUILDKIT_IMAGE" >/dev/null 2>&1 && BUILDKIT_PRE=1
log ""
log "--- 専用のビルダー（${BUILDKIT_IMAGE}）---"
docker buildx rm "$BUILDER" >/dev/null 2>&1
# ビルダーの詳細（ワーカーのホスト名・GC の設定など）は生ログに残さず、BuildKit の版だけを記録する
BK_INSPECT="$WORK/buildx-inspect.txt"
docker buildx create --name "$BUILDER" --driver docker-container --driver-opt "image=${BUILDKIT_IMAGE}" >/dev/null 2>"$BK_INSPECT" \
  && docker buildx inspect --bootstrap "$BUILDER" > "$BK_INSPECT" 2>&1 \
  || { cat "$BK_INSPECT" >> "$LOG"; log "🔴 専用のビルダーを作れません"; exit 1; }
log "  作りました: ${BUILDER}（$(grep -m1 'BuildKit version' "$BK_INSPECT" | sed 's/  */ /g')）"

# ---- 4. 9 イメージを作って押す ----------------------------------------------
MEAS="$WORK/measures.txt"
: > "$MEAS"

mk_dockerfile() {   # $1=wrap $2=base image $3=jar file name
  local w="$1" bi="$2" jar="$3"
  case "$w" in
    w1)
      cat <<DF
FROM ${bi}
WORKDIR /application
COPY ${jar} application.jar
ENTRYPOINT ["java", "-jar", "application.jar"]
DF
      ;;
    w2)
      cat <<DF
FROM ${bi} AS builder
WORKDIR /builder
COPY ${jar} application.jar
RUN java -Djarmode=tools -jar application.jar extract --layers --destination extracted

FROM ${bi}
WORKDIR /application
COPY --from=builder /builder/extracted/dependencies/ ./
COPY --from=builder /builder/extracted/spring-boot-loader/ ./
COPY --from=builder /builder/extracted/snapshot-dependencies/ ./
COPY --from=builder /builder/extracted/application/ ./
ENTRYPOINT ["java", "-jar", "application.jar"]
DF
      ;;
    w3)
      cat <<DF
FROM ${bi} AS builder
WORKDIR /builder
COPY ${jar} application.jar
RUN java -Djarmode=tools -jar application.jar extract --layers --destination extracted

FROM ${bi}
WORKDIR /application
COPY --from=builder /builder/extracted/dependencies/ ./
COPY --from=builder /builder/extracted/spring-boot-loader/ ./
COPY --from=builder /builder/extracted/snapshot-dependencies/ ./
COPY --from=builder /builder/extracted/application/ ./
RUN java -XX:AOTCacheOutput=app.aot -Dspring.context.exit=onRefresh -jar application.jar
ENTRYPOINT ["java", "-XX:AOTCache=app.aot", "-jar", "application.jar"]
DF
      ;;
  esac
}

# 🔴 docker push は OCI の index（マニフェストリスト）を押す。tag を引くと index が返り、
#    層は入っていない。さらに index には provenance の添付（attestation）も並ぶため、
#    実行するアーキの image manifest だけを選ぶ。ここを間違えると層 0 件・0 バイトになる。
manifest_bytes() {  # $1=repo $2=tag  -> "compressed_total layer_count"
  python3 "$ROOT/scenarios/004-image-size/manifest.py" "${REG_PORT}" "$1" "$2" bytes
}

log ""
log "--- イメージを作る（作り方 3 × 土台 3）---"
for w in "${WRAPS[@]}"; do
  for b in "${BASES[@]}"; do
    bi="$(base_image "$b")"
    tag="sbme004-${w}-${b}:v1"
    repo="measure/${w}-${b}"
    mk_dockerfile "$w" "$bi" "app.jar" > "$CTX/Dockerfile"
    log ""
    log "[${w}-${b}] $(wrap_label "$w") / ${bi}"
    T0=$(python3 -c 'import time;print(time.perf_counter())')
    ( cd "$CTX" && docker buildx build --builder "$BUILDER" --load -q -t "$tag" -f Dockerfile . ) >> "$LOG" 2>&1
    RC=$?
    T1=$(python3 -c 'import time;print(time.perf_counter())')
    BUILD_S=$(python3 -c "print(round($T1-$T0,1))")
    if [ $RC -ne 0 ]; then
      log "  🔴 ビルドに失敗しました（rc=${RC}）—— 未測定として記録します"
      echo "${w}|${b}|${bi}|-1|-1|-1|-1|${BUILD_S}|FAILED" >> "$MEAS"
      continue
    fi
    UNCOMP=$(docker image inspect "$tag" --format '{{.Size}}')
    # 展開後（実際に展開される rootfs）。inspect の .Size とは別の数。
    CID=$(docker create "$tag" 2>>"$LOG")
    if [ -n "$CID" ]; then
      EXPANDED=$(docker export "$CID" | wc -c | tr -d ' ')
      docker rm -f "$CID" >/dev/null 2>&1
    else
      EXPANDED=-1
    fi
    docker tag "$tag" "localhost:${REG_PORT}/${repo}:v1"
    docker push -q "localhost:${REG_PORT}/${repo}:v1" >> "$LOG" 2>&1 \
      || { log "  🔴 push に失敗しました"; echo "${w}|${b}|${bi}|-1|${UNCOMP}|-1|${BUILD_S}|PUSHFAIL" >> "$MEAS"; continue; }
    read -r COMP LAYERS <<< "$(manifest_bytes "$repo" v1)"
    log "  ビルド ${BUILD_S}s（キャッシュ込み・測定対象ではない） / registry ${COMP} bytes / inspect ${UNCOMP} bytes / 展開後 ${EXPANDED} bytes / 層 ${LAYERS}"
    echo "${w}|${b}|${bi}|${COMP}|${UNCOMP}|${EXPANDED}|${LAYERS}|${BUILD_S}|OK" >> "$MEAS"
  done
done

# ---- 5. 起動を測る ----------------------------------------------------------
log ""
log "--- 起動を測る（docker run のオーバーヘッド込み・${STARTS} 回の中央値）---"
START_FILE="$WORK/starts.txt"
: > "$START_FILE"
# 🔴 終了は JAVA_TOOL_OPTIONS でシステムプロパティとして渡す。
#    プログラム引数（--spring.context.exit=onRefresh）では終了せず、コンテナが起動したまま残る
#    （実測: 10 分たっても終わらなかった）。
# 🔴 python から呼んでハードタイムアウトを掛ける。bash の docker run には上限が無く、
#    1 件ハングすると測定全体が止まる。macOS には timeout コマンドが無い。
python3 - "$MEAS" "$START_FILE" "$STARTS" "$LOG" <<'PYSTART'
import statistics, subprocess, sys, time

meas, outf, starts, logpath = sys.argv[1:5]
starts = int(starts)
TIMEOUT_S = 120
ENV_EXIT = "-Dspring.context.exit=onRefresh"

def once(tag, log):
    cmd = ["docker", "run", "--rm", "-e", f"JAVA_TOOL_OPTIONS={ENV_EXIT}", tag]
    t = time.perf_counter()
    try:
        r = subprocess.run(cmd, stdout=log, stderr=log, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return -1.0
    d = time.perf_counter() - t
    return d if r.returncode == 0 else -1.0

with open(logpath, "a") as log, open(outf, "w") as out:
    for line in open(meas):
        line = line.rstrip("\n")
        if not line:
            continue
        w, b, bi, comp, uncomp, expanded, layers, build, st = line.split("|")
        if st != "OK":
            out.write(f"{w}|{b}|-1\n")
            continue
        tag = f"sbme004-{w}-{b}:v1"
        once(tag, log)                      # 捨て走り（記録しない）
        xs = [once(tag, log) for _ in range(starts)]
        med = -1.0 if -1.0 in xs else round(statistics.median(xs), 3)
        msg = f"  [{w}-{b}] 中央値 {med}s（{' '.join(f'{x:.3f}' if x > 0 else 'NG' for x in xs)}）"
        print(msg)
        log.write(msg + "\n")
        out.write(f"{w}|{b}|{med}\n")
PYSTART

# ---- 6. アプリの層だけ変えたときの再 pull ------------------------------------
log ""
log "--- アプリの層だけ変えて押し直す（土台は b1 固定）---"
INC_FILE="$WORK/incremental.txt"
: > "$INC_FILE"
for w in "${WRAPS[@]}"; do
  bi="$(base_image b1)"
  repo="measure/${w}-b1"
  grep -q "^${w}|b1|.*|OK$" "$MEAS" || { echo "${w}|-1|-1" >> "$INC_FILE"; continue; }
  mk_dockerfile "$w" "$bi" "app-v2.jar" > "$CTX/Dockerfile"
  ( cd "$CTX" && docker buildx build --builder "$BUILDER" --load -q -t "sbme004-${w}-b1:v2" -f Dockerfile . ) >> "$LOG" 2>&1 || {
    log "  🔴 [${w}] v2 のビルドに失敗しました"; echo "${w}|-1|-1" >> "$INC_FILE"; continue; }
  docker tag "sbme004-${w}-b1:v2" "localhost:${REG_PORT}/${repo}:v2"
  docker push -q "localhost:${REG_PORT}/${repo}:v2" >> "$LOG" 2>&1 || {
    log "  🔴 [${w}] v2 の push に失敗しました"; echo "${w}|-1|-1" >> "$INC_FILE"; continue; }
  DELTA=$(python3 "$ROOT/scenarios/004-image-size/manifest.py" "${REG_PORT}" "$repo" v2 delta)
  read -r D T <<< "$DELTA"
  log "  [${w}] v1 を持っている人が v2 を取るとき: ${D} bytes（v2 の全体は ${T} bytes）"
  echo "${w}|${D}|${T}" >> "$INC_FILE"
done

# ---- 7. 何も持っていない状態からの pull -------------------------------------
PULL_FILE="$WORK/pull.txt"
: > "$PULL_FILE"
if [ "$DO_PULL" = "1" ]; then
  log ""
  log "--- 何も持っていない状態から pull する（対照つき）---"
  log "🔴 消すのは本スクリプトが導入したイメージだけです。実行前から手元にあった土台には触れません。"
  # ビルドはここまでで終わっている。専用ビルダーとその BuildKit のイメージ（alpine 製）を先に片付ける。
  # 残すと BuildKit のイメージが alpine の層を共有し、b3 の取り直しで、その層が流れなくなる。
  docker buildx rm "$BUILDER" >/dev/null 2>&1
  [ "$BUILDKIT_PRE" = "0" ] && docker image rm "$BUILDKIT_IMAGE" >/dev/null 2>&1
  # 先に、すべての土台の自作イメージを消す。アプリ側の層（依存・ローダー・アプリ）は土台が違っても
  # 同じ中身になるため、別の土台のイメージが残っていると、その層が流れず「空からの pull」にならない。
  for b in "${BASES[@]}"; do
    for w in "${WRAPS[@]}"; do
      docker image rm -f "sbme004-${w}-${b}:v1" "localhost:${REG_PORT}/measure/${w}-${b}:v1" >/dev/null 2>&1
    done
  done
  for w in "${WRAPS[@]}"; do
    docker image rm -f "sbme004-${w}-b1:v2" "localhost:${REG_PORT}/measure/${w}-b1:v2" >/dev/null 2>&1
  done
  for b in "${BASES[@]}"; do
    line=$(grep "^w2|${b}|" "$MEAS")
    [ -n "$line" ] && [ "${line##*|}" = "OK" ] || { echo "${b}|-1|skip|-1|-1|-1" >> "$PULL_FILE"; continue; }
    PRE=$(grep "^${b}|" "$BASE_INFO" | awk -F'|' '{print $5}')
    if [ "$PRE" = "1" ] && [ "$ALLOW_BASE_RM" != "1" ]; then
      log "  [${b}] ⏸ 未測定 —— 土台が実行前から手元にあり、消せないため対照を作れません"
      log "        （本シリーズの作業で入れた土台だと確認できるなら --allow-base-removal を付ける）"
      echo "${b}|-1|preexisting|-1|-1|-1" >> "$PULL_FILE"
      continue
    fi
    repo="measure/w2-${b}"
    bi="$(base_image "$b")"
    # 我々が導入した土台を消す（自作イメージは上で消してある）
    docker image rm -f "$bi" >/dev/null 2>&1
    PULL_OUT="$WORK/pull-${b}.txt"
    # manifest の層の数（重複を除く）。pull の表示も同じ中身の層を 1 行にまとめるため
    NLAYERS=$(python3 "$ROOT/scenarios/004-image-size/manifest.py" "${REG_PORT}" "$repo" v1 unique)
    T0=$(python3 -c 'import time;print(time.perf_counter())')
    docker pull "localhost:${REG_PORT}/${repo}:v1" > "$PULL_OUT" 2>&1
    rc=$?
    T1=$(python3 -c 'import time;print(time.perf_counter())')
    S=$(python3 -c "print(round($T1-$T0,3))")
    cat "$PULL_OUT" >> "$LOG"
    # 取り直したイメージは、次の土台の取り直しと層を共有するため、すぐに消す
    docker image rm -f "localhost:${REG_PORT}/${repo}:v1" >/dev/null 2>&1
    # 手元に残っていて流れなかった層（Already exists）と、流れた層（Pull complete）を層の ID で数える
    # 4f4fb700ef54 は中身のない層（32 バイト・WORKDIR などで生じる）で、多くのイメージが共有しているため数えない
    REUSED=$(grep -E '^[0-9a-f]{12}: Already exists' "$PULL_OUT" | grep -v '^4f4fb700ef54:' | cut -d: -f1 | sort -u | wc -l | tr -d ' ')
    PULLED=$(grep -E '^[0-9a-f]{12}: Pull complete' "$PULL_OUT" | cut -d: -f1 | sort -u | wc -l | tr -d ' ')
    # 中身のない層が手元にあって Pull complete の行が出なかったときだけ、流れた層として数え合わせる
    if grep -q '^4f4fb700ef54: Already exists' "$PULL_OUT" && ! grep -q '^4f4fb700ef54: Pull complete' "$PULL_OUT"; then
      PULLED=$((PULLED + 1))
    fi
    if [ $rc -ne 0 ]; then
      log "  [${b}] 🔴 pull に失敗しました"
      echo "${b}|-1|failed|-1|-1|-1" >> "$PULL_FILE"
    elif [ "$REUSED" != "0" ] || [ "$PULLED" != "$NLAYERS" ]; then
      # 手元に丸ごと残っている層は、Docker Desktop では Already exists の行すら出ないことがある。
      # そのため「流れた層の数 = manifest の層の数」のときだけ空からの pull と認める。
      log "  [${b}] ${S}s（⚠️ 流れた層 ${PULLED} / manifest の層 ${NLAYERS}・手元に残っていた層 ${REUSED}・空からの pull ではない）"
      echo "${b}|${S}|partial|${REUSED}|${PULLED}|${NLAYERS}" >> "$PULL_FILE"
    else
      log "  [${b}] ${S}s（流れた層 ${PULLED} / manifest の層 ${NLAYERS}・空からの pull・localhost 経由）"
      echo "${b}|${S}|ok|${REUSED}|${PULLED}|${NLAYERS}" >> "$PULL_FILE"
    fi
  done
  # 取り直したイメージも本スクリプトが入れたものなので、残さずに消す
  for b in "${BASES[@]}"; do
    docker image rm -f "localhost:${REG_PORT}/measure/w2-${b}:v1" >/dev/null 2>&1
  done
else
  log ""
  log "--- pull 計測は --skip-pull で飛ばしました ---"
fi

# ---- 8. まとめる ------------------------------------------------------------
log ""
log "--- まとめ ---"
python3 - "$OUT" "$MEAS" "$START_FILE" "$INC_FILE" "$PULL_FILE" "$BASE_INFO" \
         "$JAR_BYTES" "$JAR_V2_BYTES" "$STARTS" "$REG_IMAGE" "$REG_DIGEST" "$MVN_BIN" <<'PYEOF'
import json, os, subprocess, sys

(out, meas, startf, incf, pullf, basef, jar_bytes, jar_v2_bytes,
 starts, reg_image, reg_digest, mvn_bin) = sys.argv[1:13]

def rows(path):
    if not os.path.isfile(path):
        return []
    return [l.rstrip("\n").split("|") for l in open(path) if l.strip()]

vals = {
    "jar_bytes": int(jar_bytes),
    "jar_v2_bytes": int(jar_v2_bytes),
    "starts": int(starts),
}

bases = {}
for b, img, dg, sz, pre, ex in rows(basef):
    bases[b] = {"image": img, "digest": dg, "inspect_bytes": int(sz),
                "expanded_bytes": int(ex), "preexisting": pre == "1"}
    vals[f"base_{b}_inspect_bytes"] = int(sz)
    vals[f"base_{b}_expanded_bytes"] = int(ex)

for w, b, bi, comp, uncomp, expanded, layers, build, st in rows(meas):
    key = f"{w}_{b}"
    vals[f"{key}_registry_bytes"] = int(comp)
    vals[f"{key}_inspect_bytes"] = int(uncomp)
    vals[f"{key}_expanded_bytes"] = int(expanded)
    vals[f"{key}_layers"] = int(layers)
    vals[f"{key}_build_s_cached"] = float(build)
    vals[f"{key}_status"] = st

for w, b, med in rows(startf):
    vals[f"{w}_{b}_startup_s"] = float(med)

for w, d, t in rows(incf):
    vals[f"{w}_b1_repull_delta_bytes"] = int(d)
    vals[f"{w}_b1_v2_total_bytes"] = int(t)

for b, s, st, reused, pulled, unique in rows(pullf):
    vals[f"pull_w2_{b}_s"] = float(s)
    vals[f"pull_w2_{b}_status"] = st
    vals[f"pull_w2_{b}_reused_layers"] = int(reused)
    vals[f"pull_w2_{b}_pulled_layers"] = int(pulled)
    vals[f"pull_w2_{b}_unique_layers"] = int(unique)   # manifest の層（同じ中身の層を 1 つと数える）

ok = [(f"{w}_{b}", int(c)) for w, b, bi, c, u, e, l, bd, st in rows(meas) if st == "OK"]
if ok:
    smallest = min(ok, key=lambda x: x[1])
    largest = max(ok, key=lambda x: x[1])
    vals["smallest_image"] = smallest[0]
    vals["smallest_registry_bytes"] = smallest[1]
    vals["largest_image"] = largest[0]
    vals["largest_registry_bytes"] = largest[1]
    vals["largest_over_smallest_ratio"] = round(largest[1] / smallest[1], 2)

summary = {
    "scenario": "004-image-size",
    "mode": "M2",
    "measures": "同じ Spring Boot アプリを作り方 3 通り × 土台 3 種で作り、圧縮後 / 展開後のサイズ・層の数・pull の転送バイト数・起動時間を測る",
    "size_kinds": {
        "registry_bytes": "ローカルレジストリの manifest が返す層（gzip 済み）と config の合計 = pull で転送されるバイト数",
        "inspect_bytes": "docker image inspect の .Size。🔴 containerd image store では Docker 29.8.0 以降、圧縮後の中身に展開した snapshot の使用量を足した値を返す（moby/moby#53426・29.7.2 までは圧縮後にほぼ一致）。旧来の graph driver では展開後に近い値を指す",
        "expanded_bytes": "docker export した rootfs の tar のバイト数 = 実際に展開される中身",
        "repull_delta_bytes": "v1 を持っている人が v2 を取るときに新たに転送されるバイト数",
        "note_build_s_cached": "build_s_cached はビルドキャッシュが効いた状態の値で、測定対象ではない（ビルド時間は 005 の主題）",
    },
    "env": {
        "os": subprocess.run(["uname", "-sr"], capture_output=True, text=True).stdout.strip(),
        "arch": subprocess.run(["uname", "-m"], capture_output=True, text=True).stdout.strip(),
        "docker": subprocess.run(["docker", "version", "--format", "{{.Server.Version}}"],
                                 capture_output=True, text=True).stdout.strip(),
        "maven": subprocess.run([mvn_bin, "-v"], capture_output=True, text=True).stdout.split("\n")[0],
        "registry_image": reg_image,
        "registry_digest": reg_digest,
        "bases": bases,
    },
    "values": vals,
}
with open(os.path.join(out, "summary.json"), "w") as fh:
    json.dump(summary, fh, ensure_ascii=False, indent=2)
    fh.write("\n")

print(f"最小: {vals.get('smallest_image')} = {vals.get('smallest_registry_bytes')} bytes（転送量）")
print(f"最大: {vals.get('largest_image')} = {vals.get('largest_registry_bytes')} bytes（転送量）")
print(f"最大 / 最小 = {vals.get('largest_over_smallest_ratio')} 倍")
PYEOF

log ""
log "生ログ: $(rel "${LOG_FINAL}")"
log "実効値: $(rel "${OUT}/summary.json")"
log "終了: $(date '+%Y-%m-%d %H:%M:%S')"

# 子プロセス（Maven / JVM / Docker）の出力は上の echo を直しても生ログに入るため、
# 書き終えたところで実行環境に固有の情報を落とす（tools/check-neutrality.py が検査する）
mv "$LOG" "$LOG_FINAL"
rm -f "$OUT/run.failed.log"
python3 "$ROOT/tools/sanitize-log.py" "$OUT"

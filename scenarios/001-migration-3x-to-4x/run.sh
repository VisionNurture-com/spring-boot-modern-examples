#!/usr/bin/env bash
# シナリオ: 001-migration-3x-to-4x
# モード: M1（JDK 25 + Maven）
# 測るもの: 同一ソースの Spring Boot アプリを 3.5.16 から 4.1.1 へ上げたとき、
#           ビルドを止める箇所（N1）と非推奨警告どまりの箇所（N2）が、
#           直しては再ビルドする「波」ごとに何件ずつ出るか。
#           素直に上げた道（naive）と、公式が勧める classic starters の道（classic）を比べる。
#
# 🔴 測定設計（意図的な選択）
#   1) ソースは app/ に 1 部だけ置く。各アームは /tmp のコピーへ書き換えて作る。2 部持つと
#      ソースが黙ってずれ、「同じソースで版だけ違う」という前提が壊れても何も鳴らない。
#   2) 出発点は 3.5 系の GA 最新（3.5.16）。移行ガイド §Before You Start が
#      「make sure to upgrade to the latest available 3.5.x version」と明示している。
#   3) 🔴 波で測る。単発で測ると main のコンパイルで止まり、テストコードの破損に到達しない。
#      1 回のビルドで出る件数は原理的に過少である（2026-08-29 の初回計測で実際に踏んだ）。
#   4) 各波で当てる修正は公式移行ガイドの該当節に従う。実装は run.sh に書き込むため、
#      修正手順そのものが検証対象になる（記事の手順と 1 行ずつ突き合わせる）。
#   5) アームを 2 本置く。naive = 親の版だけ上げる。classic = 公式 §Migration Strategy が勧める
#      中間状態（spring-boot-starter-classic / -test-classic）を最初から入れる。
#   6) 数え方を先に決める。N1 = コンパイルを止めた一意の「ファイル:行」、
#      N2 = 非推奨警告の一意の「ファイル:行」。合算しない。
#   7) 判定は生ログの [ERROR] / [WARNING] 行から機械的に行う。メッセージ文では判定しない。
#   8) 毎回 clean を挟む。前の波の target/ が残ると件数が変わる。
#
# 波の内容（累積・公式移行ガイドの節に対応）
#   W0: 出発点（3.5.16）のまま。基準。
#   W1: 親を 4.1.1 へ上げる。                                   §Upgrade to Spring Boot 4
#   W2: W1 + Jackson 3 へ移す。                                 §Upgrading Jackson
#       com.fasterxml.jackson.databind.ObjectMapper → tools.jackson.databind.ObjectMapper
#       JsonProcessingException は Jackson 3 に無い。JacksonException は非検査例外のため
#       throws 節を落とす（javap で確認: extends java.lang.RuntimeException）。
#   W3: W2 + テストを移す。                                     §Upgrading Testing Features
#       @MockBean → @MockitoBean（org.springframework.test.context.bean.override.mockito）
#       @WebMvcTest のパッケージ移動（org.springframework.boot.webmvc.test.autoconfigure）
#       naive のみ spring-boot-starter-webmvc-test を足す（classic は test-classic が含む）
#
# ⚠️ 件数はこの題材アプリの構成に強く依存する。ソース 6 ファイル・直接依存 3 個という規模で
#    読むこと。規模を書かずに件数だけを読むと、自分のプロジェクトへ当てはめられない。
#
# 前提: JDK 25 と Maven が使えること。Maven Central へ到達できること。
#
# 使い方:
#   bash scenarios/001-migration-3x-to-4x/run.sh
#   bash scenarios/001-migration-3x-to-4x/run.sh --out /tmp/x

set -uo pipefail

SCENARIO="001-migration-3x-to-4x"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/results/$SCENARIO"
BEFORE_VERSION="3.5.16"
AFTER_VERSION="4.1.1"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) echo "✗ 使い方エラー: 不明な引数 $1" >&2; exit 3 ;;
  esac
done

command -v mvn >/dev/null 2>&1 || { echo "✗ mvn がありません" >&2; exit 3; }
command -v java >/dev/null 2>&1 || { echo "✗ java がありません" >&2; exit 3; }

mkdir -p "$OUT"
LOG="$OUT/run.log"
# 出力先はリポジトリからの相対で見せる（生ログに実行環境の絶対パスを残さない）
rel() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;; *) printf '%s' "$1" ;; esac; }

: > "$LOG"

WORK="$(TMPDIR=/tmp mktemp -d /tmp/sbme-migration.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

say() { echo "$@" | tee -a "$LOG"; }

say "=========================================="
say "${SCENARIO}（M1・移行の波ごとに壊れた箇所を数える）"
say "=========================================="
say "出発点: Spring Boot ${BEFORE_VERSION} / 到達点: Spring Boot ${AFTER_VERSION}"
say "作業ディレクトリ: $WORK"
say ""

# アーム × 波の組み合わせを作る（波は累積）
for spec in "base:w0:none" "naive:w1:naive" "naive:w2:naive" "naive:w3:naive" \
            "classic:w1:classic" "classic:w2:classic" "classic:w3:classic"; do
  track="${spec%%:*}"; rest="${spec#*:}"; wave="${rest%%:*}"; kind="${rest##*:}"
  d="$WORK/${track}-${wave}"
  cp -R "$ROOT/scenarios/$SCENARIO/app" "$d"
  # 🔴 書き換えの失敗を握り潰さない。当たっていない書き換えのまま測ると、
  #    「直したつもり」の状態を直した後として数えることになる（2026-08-29 に実際に踏んだ）。
  if ! python3 "$ROOT/scenarios/$SCENARIO/apply-wave.py" "$d" "$wave" "$kind" "$AFTER_VERSION" >> "$LOG" 2>&1; then
    echo "✗ 書き換えに失敗しました: ${track}-${wave}（詳細は $LOG）" >&2
    exit 1
  fi
done

for spec in "base w0" "naive w1" "naive w2" "naive w3" "classic w1" "classic w2" "classic w3"; do
  set -- $spec; track="$1"; wave="$2"
  d="$WORK/${track}-${wave}"
  say "------------------------------------------"
  say "アーム: ${track} / 波: ${wave}"
  say "------------------------------------------"
  ( cd "$d" && mvn -B -Dmaven.compiler.showDeprecation=true clean test ) > "$d.build.log" 2>&1
  say "終了コード: $?"
  cat "$d.build.log" >> "$LOG"
done

python3 "$ROOT/scenarios/$SCENARIO/tally.py" "$WORK" "$OUT" "$SCENARIO" "$BEFORE_VERSION" "$AFTER_VERSION" | tee -a "$LOG"

say ""
say "summary: $(rel "$OUT/summary.json")"
say "生ログ: $(rel "$LOG")"

# 子プロセス（Maven / JVM / Docker）の出力は上の echo を直しても生ログに入るため、
# 書き終えたところで実行環境に固有の情報を落とす（tools/check-neutrality.py が検査する）
python3 "$ROOT/tools/sanitize-log.py" "$OUT"

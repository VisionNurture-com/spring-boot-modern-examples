#!/usr/bin/env python3
"""追跡ファイルに実行環境固有の情報が残っていないかを検査する。

このリポジトリの内容は、公開用リポジトリへ「移管時点の作業ツリーのスナップショット」
として出る。したがって公開面に出るかどうかを決めるのは作業ツリーであり、
ここが唯一の防波堤になる。

見るのは次の 4 つで、いずれも検出したら FAIL とする。

  1. ホームディレクトリの絶対パス（/Users/<name> ・ /home/<name>）
  2. プロセスの起動行（`started by <name>`）
  3. メールアドレス
  4. `*.local` のホスト名（macOS の Bonjour 名）

1 と 2 の <name> は user / runner / root を中立とみなす。CI の runner と
コンテナの root は環境ではなく役割の名前で、読者が読んでも誰のものか分からない。

内部の符丁（カード名・セッション番号・内部リポジトリ名）は本ゲートの対象外で、
移管の直前に手で走査する。機械検査で拾えるのは環境固有の情報だけである。

使い方: python3 tools/check-neutrality.py
終了コード: 0 = PASS / 1 = FAIL
"""
import re
import subprocess
import sys

NEUTRAL_NAMES = {"user", "runner", "root"}

# 公開用 identity のアドレスだけは通す。公開リポジトリの全コミットの author 欄に
# 出る値で、隠せるものではない（.github/workflows/verify.yml の identity ジョブが
# この値と突き合わせて、規約外の identity を止める）。
ALLOWED_EMAILS = {"blog@techbizplusd.com"}

CHECKS = [
    ("ホームディレクトリの絶対パス", re.compile(r"(?:/Users/|/home/)([A-Za-z0-9._-]+)"), True),
    ("プロセスの起動行", re.compile(r"started by ([A-Za-z0-9._-]+)"), True),
    ("メールアドレス", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), False),
    ("ホスト名（.local）", re.compile(r"\b[A-Za-z0-9-]+\.local\b"), False),
]


def tracked_files():
    out = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True)
    return [p for p in out.stdout.decode().split("\0") if p]


def main():
    findings = []
    for path in tracked_files():
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue  # バイナリと消えたパスは対象外
        for lineno, line in enumerate(lines, 1):
            for label, pattern, name_aware in CHECKS:
                for m in pattern.finditer(line):
                    if name_aware and m.group(1) in NEUTRAL_NAMES:
                        continue
                    if label == "メールアドレス" and m.group(0) in ALLOWED_EMAILS:
                        continue
                    findings.append((path, lineno, label, m.group(0)))

    if findings:
        print("=" * 42)
        for path, lineno, label, hit in findings:
            print("  FAIL %s:%d  %s → %s" % (path, lineno, label, hit))
        print("=" * 42)
        print("✗ FAIL [check-neutrality]: 環境固有の情報 %d 件" % len(findings))
        print("  生ログは python3 tools/sanitize-log.py <file> で中立化する")
        return 1

    print("=" * 42)
    print("サマリー [check-neutrality]: FAIL 0 / 検査 %d ファイル" % len(tracked_files()))
    print("=" * 42)
    return 0


if __name__ == "__main__":
    sys.exit(main())

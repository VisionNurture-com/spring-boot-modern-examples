#!/usr/bin/env python3
"""生ログから実行環境に固有の情報を取り除く。

run.sh の echo を直しても、Maven / JVM / Docker の出力は `>> "$LOG" 2>&1` で
そのまま流れ込む。Spring Boot の起動行（`started by <user> in <dir>`）や
Java agent の警告（`~/.m2/repository/...` の絶対パス）がこの経路で入るため、
書き終えたログを最後にここへ通す。

置換は「実行ユーザー名」と「ホームディレクトリの絶対パス」の 2 つだけで、
測定値には触れない。CI の runner のように名前がすでに中立なら何もしない。

引数にはファイルとディレクトリのどちらも渡せる。ディレクトリは配下を再帰的にたどる
（シナリオの出力先を丸ごと渡せば raw/ の取り込みログまで届く）。

使い方: python3 tools/sanitize-log.py <file|dir>...
終了コード: 0 = 完了（置換 0 件を含む） / 3 = 使い方エラー
"""
import os
import pwd
import re
import sys

NEUTRAL = {"user", "runner", "root"}
PLACEHOLDER = "user"


def sanitize(text, user, home):
    n = 0
    if home:
        parent = os.path.dirname(home)  # /Users または /home
        replacement = os.path.join(parent, PLACEHOLDER) if parent else "/" + PLACEHOLDER
        text, c = re.subn(re.escape(home), replacement, text)
        n += c
    if user:
        # 🔴 ハイフンは境界に含める。`-Users-<user>-work-...` のようにハイフンで挟まれた形は
        #    ホーム形のパス（/Users/<user>）とは別経路で出てくるため、ここで落とさないと残る
        #    （2026-08-30 に clean clone の実走で検出。出力先をリポジトリ外へ指定したときに出た）。
        text, c = re.subn(r"(?<![A-Za-z0-9._])%s(?![A-Za-z0-9._])" % re.escape(user),
                          PLACEHOLDER, text)
        n += c
    return text, n


def main(argv):
    if not argv:
        print("使い方: python3 tools/sanitize-log.py <file>...", file=sys.stderr)
        return 3
    try:
        user = pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        user = os.environ.get("USER", "")
    home = os.environ.get("HOME", "").rstrip("/")
    if user in NEUTRAL and (not home or os.path.basename(home) in NEUTRAL):
        return 0  # すでに中立な環境（CI の runner 等）では何もしない

    targets = []
    for arg in argv:
        if os.path.isdir(arg):
            for dirpath, _, filenames in os.walk(arg):
                targets.extend(os.path.join(dirpath, f) for f in sorted(filenames))
        elif os.path.isfile(arg):
            targets.append(arg)

    total = 0
    for path in targets:
        try:
            with open(path, encoding="utf-8", errors="surrogateescape") as f:
                before = f.read()
        except (OSError, UnicodeDecodeError):
            continue  # 読めないファイル（バイナリ等）は触らない
        after, n = sanitize(before, user, home)
        if n:
            with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(after)
            total += n
            print("中立化: %s（%d 箇所）" % (path, n))
    if total:
        print("中立化の合計: %d 箇所" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

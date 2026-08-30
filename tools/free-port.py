#!/usr/bin/env python3
"""ホストで使える TCP ポート番号を 1 つ返す。

計測ハーネスは PostgreSQL・OTLP コレクタ・ローカルレジストリをコンテナで立て、
ホストのポートに束ねる。番号を決め打ちにすると、その番号が埋まっている機体では
`docker run` が daemon のエラーで落ちる（2026-08-30 に CI で発生:
`failed to bind host port for 0.0.0.0:55432 ... address already in use`）。

引数に希望の番号を渡すと、空いていればそれを返す（ログに出る番号が普段は変わらない）。
埋まっていれば OS に空きを 1 つ選ばせる。どちらも取れなければ、何が起きたかを書いて
終了コード 1 で落ちる。

⚠️ 返した直後に別のプロセスがその番号を取る可能性は残る（bind して閉じるまでの隙間）。
   本ツールが減らせるのは「最初から埋まっている」場合の失敗であって、競合そのものを
   なくすものではない。

使い方: python3 tools/free-port.py [希望のポート番号]
終了コード: 0 = 番号を 1 行で出力 / 1 = 取得できず / 3 = 使い方エラー
"""
import socket
import sys


def is_free(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def any_free():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main(argv):
    if len(argv) > 1:
        print("使い方: python3 tools/free-port.py [希望のポート番号]", file=sys.stderr)
        return 3
    if argv:
        try:
            preferred = int(argv[0])
        except ValueError:
            print("ポート番号は整数で指定してください: %s" % argv[0], file=sys.stderr)
            return 3
        if is_free(preferred):
            print(preferred)
            return 0
        print("希望のポート %d は使用中のため、空きを選び直します" % preferred, file=sys.stderr)
    try:
        print(any_free())
    except OSError as e:
        print("空きポートを取得できませんでした: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

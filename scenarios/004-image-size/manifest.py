#!/usr/bin/env python3
"""ローカルレジストリの manifest から転送バイト数を出す。

docker push が押すのは OCI の index（マニフェストリスト）で、tag を引くと index が返る。
index には実行アーキの image manifest に加えて provenance の添付（attestation）も並ぶ。
層のバイト数を数えるには、**実行するアーキの image manifest だけ**を選ぶ必要がある。

使い方:
  manifest.py <port> <repo> <tag> bytes   -> "圧縮後合計 層の数"
  manifest.py <port> <repo> <tag> delta   -> "v1 を持つ人が当該 tag を取るときの差分 全体"

終了コード: 0 = 正常 / 1 = マニフェストを解決できない
"""
import json
import platform
import sys
import urllib.request

ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])

ARCH = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "amd64", "amd64": "amd64"}.get(
    platform.machine(), platform.machine()
)


def fetch(port, repo, ref):
    req = urllib.request.Request(
        f"http://localhost:{port}/v2/{repo}/manifests/{ref}", headers={"Accept": ACCEPT}
    )
    return json.load(urllib.request.urlopen(req))


def image_manifest(port, repo, tag):
    """index なら実行アーキの image manifest まで降りる（attestation は除く）。"""
    m = fetch(port, repo, tag)
    if "manifests" not in m:
        return m
    for entry in m["manifests"]:
        if entry.get("annotations", {}).get("vnd.docker.reference.type"):
            continue  # attestation（provenance / sbom）は pull されない
        p = entry.get("platform", {})
        if p.get("architecture") == ARCH and p.get("os") == "linux":
            return fetch(port, repo, entry["digest"])
    raise SystemExit(f"🔴 {repo}:{tag} に {ARCH}/linux の manifest がありません")


def main() -> int:
    port, repo, tag, mode = sys.argv[1:5]
    m = image_manifest(port, repo, tag)
    layers = m.get("layers", [])
    if mode == "bytes":
        total = sum(l["size"] for l in layers) + m.get("config", {}).get("size", 0)
        print(total, len(layers))
    elif mode == "delta":
        base = image_manifest(port, repo, "v1")
        have = {l["digest"] for l in base.get("layers", [])}
        delta = sum(l["size"] for l in layers if l["digest"] not in have)
        print(delta, sum(l["size"] for l in layers))
    else:
        raise SystemExit(f"🔴 未知のモード: {mode}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

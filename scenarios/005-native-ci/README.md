# 005-native-ci — CI 上での Native Image のビルドコストを測る

`native-image` のビルドが **GitHub Actions のパブリック runner で何分かかり、メモリを
どれだけ使い、どこで落ちるか**を測る。測定の主体は runner であって手元の機械ではない。

## なぜ別リポジトリで測るか

パブリックリポジトリの標準 runner は **4 vCPU / 16 GB**、プライベートは **2 vCPU / 8 GB**
である（[docs.github.com](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)）。
検証用リポジトリは PRIVATE のため、そこで回すと 8 GB 側しか測れない。測定は
**[`VisionNurture-com/spring-boot-modern-examples`](https://github.com/VisionNurture-com/spring-boot-modern-examples)**（公開サンプル）で回し、
その結果を本シナリオへ取り込む。`measure.yml` と `measure-oom.yml` を同居させてある。

## アーム

| アーム | 内容 |
|---|---|
| `jvm-package` | 対照。`mvn package`（JVM 用の jar）|
| `native-nocache` | Native ビルド。Maven キャッシュなし |
| `native-cache` | Native ビルド。`setup-graalvm` の `cache: 'maven'` あり |
| `native-xmx-limited` | `-J-Xmx2g` に絞って落ちるかどうか |
| `graalvm-version-probe` | `setup-graalvm` の版指定で実際に何が入るか |

`native-nocache` には、正典のコマンド `mvn -Pnative package` **だけ**で
ネイティブバイナリができるかを確かめるステップも入っている。

## 値の出所

`native-image` が `-H:BuildOutputJSONFile` で出す**機械可読なビルド出力**だけを使う。
テキストログの見た目から拾うと、書式が変わったときに黙って空になる。

3 ラウンドまわして中央値を取る。生ログと各ラウンドの JSON は `results/005-native-ci/raw/`
に残してある。

## 落ちるアームを別ワークフローにしている理由

GitHub Actions の既定シェルは `bash -e` である。`pipefail` と併せると、`mvn` が
非ゼロで終わった時点でステップごと中断し、**集計に到達しない**。落ちることが期待値の
アームだけは `set +e` を明示したワークフロー（`measure-oom.yml`）で回す。

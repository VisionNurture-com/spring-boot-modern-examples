#!/usr/bin/env python3
"""腕 × 波の書き換えを 1 ディレクトリへ当てる。

run.sh から呼ばれる。波は累積で、W2 は W1 を含み、W3 は W2 を含む。
各波が当てる修正は Spring Boot 4.0 Migration Guide の該当節に対応する。

使い方: apply-wave.py <dir> <w0|w1|w2|w3> <none|naive|classic> <after_version>
終了コード: 0 = 正常 / 3 = 使い方エラー
"""
import pathlib
import sys

CLASSIC_DEP = """    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-classic</artifactId>
    </dependency>
"""
WEBMVC_TEST_DEP = """    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-webmvc-test</artifactId>
      <scope>test</scope>
    </dependency>
"""


def sub(path: pathlib.Path, old: str, new: str, expect: int = 1) -> None:
    """置換が意図した件数だけ当たったことを確かめてから書き戻す。

    件数を確かめないと、書き換えが当たっていないまま「当てたつもり」で測ることになる。
    """
    text = path.read_text(encoding="utf-8")
    got = text.count(old)
    if got != expect:
        raise SystemExit(f"🔴 {path.name}: 置換対象が {got} 件（期待 {expect}）: {old[:60]!r}")
    path.write_text(text.replace(old, new), encoding="utf-8")


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 3
    d, wave, kind, after = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
    pom = d / "pom.xml"
    ctrl = d / "src/main/java/com/example/migration/TaskController.java"
    test = d / "src/test/java/com/example/migration/TaskControllerTest.java"

    if wave == "w0":
        print(f"[apply-wave] {d.name}: 出発点のまま（書き換えなし）")
        return 0

    # --- W1: 親の版を上げる（+ classic なら中間状態の starter を足す）---
    sub(pom, "<version>3.5.16</version>", f"<version>{after}</version>")
    if kind == "classic":
        sub(pom, "<artifactId>spring-boot-starter-test</artifactId>",
            "<artifactId>spring-boot-starter-test-classic</artifactId>")
        sub(pom, CLASSIC_DEP.replace("spring-boot-starter-classic", "spring-boot-starter-actuator"),
            CLASSIC_DEP.replace("spring-boot-starter-classic", "spring-boot-starter-actuator") + CLASSIC_DEP)

    # --- W2: Jackson 3 へ移す（§Upgrading Jackson）---
    if wave in ("w2", "w3"):
        sub(ctrl,
            "import com.fasterxml.jackson.core.JsonProcessingException;\n"
            "import com.fasterxml.jackson.databind.ObjectMapper;",
            "import tools.jackson.databind.ObjectMapper;")
        # JsonProcessingException は Jackson 3 に無い。JacksonException は非検査例外のため
        # throws 節そのものを落とす（javap で RuntimeException 継承を確認済み）。
        sub(ctrl, " throws JsonProcessingException", "")

    # --- W3: テストを移す（§Upgrading Testing Features）---
    if wave == "w3":
        sub(test,
            "import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;",
            "import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;")
        sub(test,
            "import org.springframework.boot.test.mock.mockito.MockBean;",
            "import org.springframework.test.context.bean.override.mockito.MockitoBean;")
        # 🔴 "@MockBean" だけを指すと javadoc の {@code @MockBean} にも当たり 2 件になる。
        #    宣言そのもの（注釈 + フィールド）を指して 1 件に絞る。
        sub(test,
            "    @MockBean\n    private TaskService service;",
            "    @MockitoBean\n    private TaskService service;")
        if kind == "naive":
            # classic は spring-boot-starter-test-classic が webmvc-test を含むため足さない。
            sub(pom,
                "    <dependency>\n"
                "      <groupId>org.springframework.boot</groupId>\n"
                "      <artifactId>spring-boot-starter-test</artifactId>\n"
                "      <scope>test</scope>\n"
                "    </dependency>\n",
                "    <dependency>\n"
                "      <groupId>org.springframework.boot</groupId>\n"
                "      <artifactId>spring-boot-starter-test</artifactId>\n"
                "      <scope>test</scope>\n"
                "    </dependency>\n" + WEBMVC_TEST_DEP)

    print(f"[apply-wave] {d.name}: {wave} / {kind} を適用")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

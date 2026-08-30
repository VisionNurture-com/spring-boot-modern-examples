package com.example.migration;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * 移行対象アプリケーション。
 *
 * 3.5 系から 4 系へ上げたときに何が壊れるかを数えるための題材である。
 * 壊れ方の型が実際に当たるよう、次の構成を意図的に含めている。
 *
 * <ul>
 *   <li>{@code spring-boot-starter-web}（4 系で非推奨になる starter）</li>
 *   <li>Jackson の明示利用（{@code com.fasterxml.jackson} を import する）</li>
 *   <li>{@code @WebMvcTest} + {@code @MockBean} を使うテスト（4 系で削除される API）</li>
 *   <li>フレームワークに依存しない素の JUnit テスト（版を上げても通るはずの対照）</li>
 * </ul>
 */
@SpringBootApplication
public class MigrationApplication {

    public static void main(String[] args) {
        SpringApplication.run(MigrationApplication.class, args);
    }
}

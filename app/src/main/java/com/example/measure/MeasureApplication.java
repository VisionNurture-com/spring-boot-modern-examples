package com.example.measure;

import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 計測対象アプリケーション。
 *
 * 起動時間・スループット・イメージサイズ・計装コストの計測に共通で使う。
 * 記事に載せる値はすべて scenarios/&lt;id&gt;/expected.md を出典とする。
 */
@SpringBootApplication
@RestController
public class MeasureApplication {

    public static void main(String[] args) {
        SpringApplication.run(MeasureApplication.class, args);
    }

    /** 起動確認用。処理は持たない。 */
    @GetMapping("/hello")
    public String hello() {
        return "hello";
    }

    /**
     * 定常状態の計測用エンドポイント。
     *
     * <p>決定的な数値計算と JSON シリアライズを行う。計算を挟むのは、JIT が最適化できる
     * ホットパスを作るためである。フレームワークの往復だけを測ると、
     * JIT（実行時最適化）と AOT（ビルド時最適化）の差が現れない。
     *
     * @param n 反復回数。負荷の大きさを決める
     */
    @GetMapping("/work")
    public Map<String, Object> work(@RequestParam(defaultValue = "2000") int n) {
        long acc = 0;
        for (int i = 1; i <= n; i++) {
            acc += (long) (Math.sqrt(i) * 1000.0);
            acc ^= (acc << 13);
            acc ^= (acc >>> 7);
            acc ^= (acc << 17);
        }
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("n", n);
        out.put("acc", acc);
        return out;
    }
}

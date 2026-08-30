package com.example.measure.db;

import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * コネクションプールの計測対象アプリケーション。
 *
 * <p>仮想スレッドを有効にしたうえで、1 リクエストにつき 1 本の接続を占有し、
 * データベース側で待つ。プールのサイズが同時実行の上限になる状態を作るためである。
 */
@SpringBootApplication
@RestController
public class MeasureDbApplication {

    private final JdbcTemplate jdbc;

    public MeasureDbApplication(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public static void main(String[] args) {
        SpringApplication.run(MeasureDbApplication.class, args);
    }

    /** 疎通確認用。データベースへは触れない。 */
    @GetMapping("/hello")
    public String hello() {
        return "hello";
    }

    /**
     * データベース側で指定ミリ秒だけ待つ。
     *
     * <p>接続を保持したままブロックするため、同時実行数がプールのサイズを超えると
     * 超えたぶんはプールの待ち行列に並ぶ。
     *
     * @param ms データベース側で待つミリ秒
     */
    @GetMapping("/db")
    public Map<String, Object> db(@RequestParam(defaultValue = "50") int ms) {
        Integer one = jdbc.queryForObject("SELECT 1 FROM pg_sleep(?)", Integer.class, ms / 1000.0);
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("ms", ms);
        out.put("ok", one != null && one == 1);
        return out;
    }

    /**
     * データベース側に CPU を使わせる。
     *
     * <p>{@code /db} は待つだけで CPU を使わないため、接続を増やせば増やしただけ通る。
     * 実運用の問い合わせは CPU を使うので、そちらも測らないと
     * 「プールは大きいほどよい」という誤った結論になる。
     *
     * @param n 走査する行数。負荷の大きさを決める
     */
    @GetMapping("/dbcpu")
    public Map<String, Object> dbCpu(@RequestParam(defaultValue = "100000") int n) {
        Long count = jdbc.queryForObject(
                "SELECT count(*) FROM generate_series(1, ?) s WHERE md5(s::text) < 'f'",
                Long.class, n);
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("n", n);
        out.put("count", count);
        return out;
    }
}

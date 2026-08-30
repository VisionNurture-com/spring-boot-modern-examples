import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * 定常状態の計測用 負荷生成器。
 *
 * JDK だけで動く（single-file source launch）。読者が追加のインストールなしで
 * 同じ計測を再現できるようにするための選択である。
 *
 * ウォームアップ中の応答は記録しない。JIT が最適化を終える前の値を混ぜないため。
 *
 * 使い方:
 *   java tools/loadgen/LoadGen.java --url http://localhost:8080/work?n=2000 \
 *        --concurrency 32 --warmup-sec 10 --duration-sec 15 --out result.json
 */
public class LoadGen {

    public static void main(String[] args) throws Exception {
        String url = "http://localhost:8080/work?n=2000";
        int concurrency = 32;
        int warmupSec = 10;
        int durationSec = 15;
        String out = null;

        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--url" -> url = args[++i];
                case "--concurrency" -> concurrency = Integer.parseInt(args[++i]);
                case "--warmup-sec" -> warmupSec = Integer.parseInt(args[++i]);
                case "--duration-sec" -> durationSec = Integer.parseInt(args[++i]);
                case "--out" -> out = args[++i];
                default -> {
                    System.err.println("不明な引数: " + args[i]);
                    System.exit(3);
                }
            }
        }

        HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .version(HttpClient.Version.HTTP_1_1)
                .build();
        HttpRequest req = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(10))
                .GET()
                .build();

        // 接続確認（失敗したらここで止める）
        HttpResponse<String> probe = client.send(req, HttpResponse.BodyHandlers.ofString());
        if (probe.statusCode() != 200) {
            System.err.println("🔴 プローブが 200 を返しません: " + probe.statusCode());
            System.exit(1);
        }

        AtomicBoolean recording = new AtomicBoolean(false);
        AtomicBoolean running = new AtomicBoolean(true);
        AtomicLong errors = new AtomicLong();
        List<Long> latencies = Collections.synchronizedList(new ArrayList<>(1 << 20));

        try (ExecutorService ex = Executors.newVirtualThreadPerTaskExecutor()) {
            for (int i = 0; i < concurrency; i++) {
                ex.submit(() -> {
                    while (running.get()) {
                        long t0 = System.nanoTime();
                        try {
                            HttpResponse<String> r = client.send(req, HttpResponse.BodyHandlers.ofString());
                            long d = System.nanoTime() - t0;
                            if (r.statusCode() != 200) {
                                errors.incrementAndGet();
                            } else if (recording.get()) {
                                latencies.add(d);
                            }
                        } catch (IOException | InterruptedException e) {
                            errors.incrementAndGet();
                        }
                    }
                });
            }

            TimeUnit.SECONDS.sleep(warmupSec);   // ← ここまでは記録しない
            recording.set(true);
            long start = System.nanoTime();
            TimeUnit.SECONDS.sleep(durationSec);
            recording.set(false);
            long elapsedNs = System.nanoTime() - start;
            running.set(false);

            List<Long> sorted;
            synchronized (latencies) {
                sorted = new ArrayList<>(latencies);
            }
            Collections.sort(sorted);

            long n = sorted.size();
            double elapsedSec = elapsedNs / 1e9;
            double throughput = n / elapsedSec;

            String json = """
                    {
                      "url": "%s",
                      "concurrency": %d,
                      "warmup_sec": %d,
                      "duration_sec": %d,
                      "requests": %d,
                      "errors": %d,
                      "throughput_rps": %.1f,
                      "p50_ms": %.2f,
                      "p95_ms": %.2f,
                      "p99_ms": %.2f,
                      "max_ms": %.2f
                    }
                    """.formatted(url, concurrency, warmupSec, durationSec, n, errors.get(),
                    throughput, pct(sorted, 50), pct(sorted, 95), pct(sorted, 99), pct(sorted, 100));

            System.out.print(json);
            if (out != null) {
                Files.writeString(Path.of(out), json);
            }
        }
    }

    /** ソート済みリストから百分位を取る（ミリ秒）。 */
    private static double pct(List<Long> sorted, int p) {
        if (sorted.isEmpty()) {
            return 0.0;
        }
        int idx = (int) Math.ceil(p / 100.0 * sorted.size()) - 1;
        idx = Math.max(0, Math.min(idx, sorted.size() - 1));
        return sorted.get(idx) / 1e6;
    }
}

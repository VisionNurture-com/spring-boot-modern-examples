import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 仮想スレッドがキャリアスレッドを手放せなくなる経路を、腕ごとに 1 プロセスで再現する。
 *
 * <p>腕:
 * <ul>
 *   <li>{@code noop}        —— 何もしない。ハーネス自身が出すイベントを測るための対照</li>
 *   <li>{@code sync}        —— synchronized ブロックの中でブロックする</li>
 *   <li>{@code clinit}      —— クラス初期化子の中でブロックし、他スレッドがその初期化を待つ</li>
 * </ul>
 *
 * <p>クラスの初期化は 1 プロセスにつき 1 回しか起きない。同じ JVM で繰り返すと 2 回目以降は
 * 初期化済みになり再現しないため、1 試行 = 1 プロセスとして起動し直すこと。
 *
 * <p>使い方: {@code java PinDemo.java <arm> <threads> <blockMillis>}
 */
public class PinDemo {

    static final Object MONITOR = new Object();
    static volatile int blockMillis = 100;

    public static void main(String[] args) throws Exception {
        String arm = args.length > 0 ? args[0] : "sync";
        int threads = args.length > 1 ? Integer.parseInt(args[1]) : 8;
        blockMillis = args.length > 2 ? Integer.parseInt(args[2]) : 100;

        System.out.println("arm=" + arm + " threads=" + threads + " blockMillis=" + blockMillis);
        System.out.println("java.version=" + System.getProperty("java.version"));

        CountDownLatch ready = new CountDownLatch(threads);
        CountDownLatch go = new CountDownLatch(1);

        try (ExecutorService es = Executors.newVirtualThreadPerTaskExecutor()) {
            for (int i = 0; i < threads; i++) {
                es.submit(() -> {
                    ready.countDown();
                    go.await();
                    switch (arm) {
                        case "noop" -> { }
                        case "sync" -> syncWork();
                        case "clinit" -> SlowInit.touch();
                        default -> throw new IllegalArgumentException("unknown arm: " + arm);
                    }
                    return null;
                });
            }
            ready.await();
            go.countDown();
        }
        System.out.println("done");
    }

    /** モニタを保持したままブロックする。 */
    static void syncWork() throws InterruptedException {
        synchronized (MONITOR) {
            Thread.sleep(blockMillis);
        }
    }

    /** 初期化に時間のかかるクラス。最初に触れた 1 スレッドが初期化子の中でブロックする。 */
    static class SlowInit {
        static final long VALUE;

        static {
            try {
                Thread.sleep(blockMillis);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            VALUE = System.nanoTime();
        }

        static long touch() {
            return VALUE;
        }
    }
}

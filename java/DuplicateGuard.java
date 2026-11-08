import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.HashSet;
import java.util.Set;
import java.util.random.RandomGenerator;

/**
 * Catches a payment submitted twice within a time window, without keeping
 * every idempotency key in memory.
 *
 * <p>The window is split into generations, each a Bloom filter. A key is
 * written to the newest generation and looked up in all of them; when the
 * newest generation's slice of time is over, the oldest filter is dropped
 * and a fresh one becomes the newest. Memory is therefore fixed at
 * {@code generations * bits}, and a key is remembered for between
 * {@code (generations - 1) * slice} and {@code generations * slice}.
 *
 * <p>A Bloom filter can say "seen" for a key it never saw, never the reverse.
 * Here that means an occasional honest payment is sent to the slow, exact
 * check in the ledger; it never means a real duplicate gets through.
 */
public final class DuplicateGuard {

    /** One fixed-size Bloom filter, sized for a target false-positive rate. */
    static final class Bloom {
        private final long[] words;
        private final int bits;
        private final int hashes;

        Bloom(int expectedKeys, double falsePositiveRate) {
            // m = -n ln p / (ln 2)^2, k = (m / n) ln 2: the textbook optimum.
            double m = -expectedKeys * Math.log(falsePositiveRate) / (Math.log(2) * Math.log(2));
            this.bits = Math.max(64, (int) Math.ceil(m / 64) * 64);
            this.hashes = Math.max(1, (int) Math.round((double) bits / expectedKeys * Math.log(2)));
            this.words = new long[bits / 64];
        }

        void add(long h1, long h2) {
            for (int i = 0; i < hashes; i++) {
                int bit = index(h1, h2, i);
                words[bit >>> 6] |= 1L << bit;
            }
        }

        boolean mightContain(long h1, long h2) {
            for (int i = 0; i < hashes; i++) {
                int bit = index(h1, h2, i);
                if ((words[bit >>> 6] & (1L << bit)) == 0) {
                    return false;
                }
            }
            return true;
        }

        // Kirsch-Mitzenmacher: k hash functions from two, g_i = h1 + i * h2.
        private int index(long h1, long h2, int i) {
            return (int) Long.remainderUnsigned(h1 + i * h2, bits);
        }

        int bitCount() {
            int n = 0;
            for (long w : words) {
                n += Long.bitCount(w);
            }
            return n;
        }

        int size() { return bits; }
        int hashCount() { return hashes; }
    }

    private final Deque<Bloom> generations = new ArrayDeque<>();
    private final int generationCount;
    private final long sliceMillis;
    private final int keysPerSlice;
    private final double fpRate;
    private long sliceStartedAt;

    public DuplicateGuard(long windowMillis, int generationCount, int keysPerSlice, double fpRate) {
        if (generationCount < 2) {
            throw new IllegalArgumentException("need at least two generations");
        }
        this.generationCount = generationCount;
        this.sliceMillis = windowMillis / (generationCount - 1);
        this.keysPerSlice = keysPerSlice;
        this.fpRate = fpRate;
        this.generations.addFirst(new Bloom(keysPerSlice, fpRate));
    }

    /**
     * Records {@code key} and reports whether it may have been seen in the
     * window. {@code nowMillis} must not go backwards.
     */
    public boolean checkAndAdd(String key, long nowMillis) {
        rotate(nowMillis);

        byte[] bytes = key.getBytes(StandardCharsets.UTF_8);
        long h1 = hash(bytes, 0x9E3779B97F4A7C15L);
        long h2 = hash(bytes, 0xC2B2AE3D27D4EB4FL) | 1; // odd, so all k probes differ

        boolean seen = false;
        for (Bloom b : generations) {
            if (b.mightContain(h1, h2)) {
                seen = true;
                break;
            }
        }
        generations.peekFirst().add(h1, h2);
        return seen;
    }

    private void rotate(long now) {
        if (sliceStartedAt == 0) {
            sliceStartedAt = now;
        }
        while (now - sliceStartedAt >= sliceMillis) {
            generations.addFirst(new Bloom(keysPerSlice, fpRate));
            if (generations.size() > generationCount) {
                generations.removeLast();
            }
            sliceStartedAt += sliceMillis;
        }
    }

    /** A small 64-bit hash: FNV-style absorption, then a strong final mix. */
    static long hash(byte[] data, long seed) {
        long h = seed ^ (data.length * 0xFF51AFD7ED558CCDL);
        for (byte b : data) {
            h = (h ^ (b & 0xFF)) * 0x100000001B3L;
            h = Long.rotateLeft(h, 23);
        }
        h ^= h >>> 33;
        h *= 0xFF51AFD7ED558CCDL;
        h ^= h >>> 33;
        h *= 0xC4CEB9FE1A85EC53L;
        h ^= h >>> 33;
        return h;
    }

    public static void main(String[] args) {
        long window = 10 * 60_000L;          // ten minutes
        var guard = new DuplicateGuard(window, 5, 20_000, 0.001);
        var bloom = guard.generations.peekFirst();
        System.out.printf("each generation: %,d bits, %d hashes, %.1f KiB%n",
                bloom.size(), bloom.hashCount(), bloom.size() / 8.0 / 1024);

        RandomGenerator rng = RandomGenerator.of("L64X128MixRandom");
        Set<String> exact = new HashSet<>();
        Deque<String> recent = new ArrayDeque<>();
        int realDuplicates = 0, caught = 0, falseAlarms = 0;

        long now = 1_773_398_400_000L; // a fixed start time
        for (int i = 0; i < 60_000; i++) {
            now += 1 + rng.nextInt(20);
            String key;
            if (!recent.isEmpty() && rng.nextInt(100) < 2) {
                // A client retrying a request it already sent a moment ago.
                key = recent.peekLast();
                realDuplicates++;
            } else {
                key = "idem_%016x".formatted(rng.nextLong());
            }
            recent.addLast(key);
            if (recent.size() > 50) {
                recent.removeFirst();
            }

            boolean flagged = guard.checkAndAdd(key, now);
            boolean dup = !exact.add(key);
            if (dup && flagged) caught++;
            if (!dup && flagged) falseAlarms++;
            if (dup && !flagged) {
                throw new AssertionError("a duplicate inside the window got through: " + key);
            }
        }

        System.out.printf("duplicates sent: %d, caught: %d, false alarms: %d (%.3f%%)%n",
                realDuplicates, caught, falseAlarms, 100.0 * falseAlarms / (60_000 - realDuplicates));
        System.out.printf("newest generation is %.1f%% full%n",
                100.0 * guard.generations.peekFirst().bitCount() / bloom.size());
    }
}

/*
 * ring_buffer.c -- a lock-free single-producer / single-consumer byte ring.
 *
 * The capacity is always a power of two, so wrapping an index is a mask
 * instead of a modulo, and the head and tail counters are allowed to run
 * freely: their difference is the fill level even after they overflow.
 *
 * Build and run the self-test:
 *
 *     cc -std=c11 -O2 -Wall -Wextra -pthread ring_buffer.c -o ring && ./ring
 */

#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CACHE_LINE 64

typedef struct ring {
    /* The producer owns `head`, the consumer owns `tail`. Keeping them on
     * separate cache lines stops the two cores from fighting over one line. */
    _Alignas(CACHE_LINE) _Atomic size_t head;
    _Alignas(CACHE_LINE) _Atomic size_t tail;
    _Alignas(CACHE_LINE) size_t mask;
    uint8_t *data;
} ring_t;

static bool is_power_of_two(size_t n)
{
    return n != 0 && (n & (n - 1)) == 0;
}

static size_t min_size(size_t a, size_t b)
{
    return a < b ? a : b;
}

int ring_init(ring_t *r, size_t capacity)
{
    if (!is_power_of_two(capacity)) {
        return -1;
    }
    r->data = malloc(capacity);
    if (r->data == NULL) {
        return -1;
    }
    r->mask = capacity - 1;
    atomic_init(&r->head, 0);
    atomic_init(&r->tail, 0);
    return 0;
}

void ring_free(ring_t *r)
{
    free(r->data);
    r->data = NULL;
}

size_t ring_capacity(const ring_t *r)
{
    return r->mask + 1;
}

/* Bytes currently readable. Safe to call from either side. */
size_t ring_used(ring_t *r)
{
    size_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    size_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    return head - tail;
}

/*
 * Copy up to `len` bytes in. Returns how many were written; a short write
 * means the ring was full. Producer side only.
 */
size_t ring_write(ring_t *r, const void *src, size_t len)
{
    size_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    size_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    size_t space = ring_capacity(r) - (head - tail);
    size_t n = min_size(len, space);
    if (n == 0) {
        return 0;
    }

    size_t at = head & r->mask;
    size_t first = min_size(n, ring_capacity(r) - at);
    memcpy(r->data + at, src, first);
    memcpy(r->data, (const uint8_t *)src + first, n - first);

    /* Publish the bytes before the new head becomes visible. */
    atomic_store_explicit(&r->head, head + n, memory_order_release);
    return n;
}

/* Copy up to `len` bytes out. Consumer side only. */
size_t ring_read(ring_t *r, void *dst, size_t len)
{
    size_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    size_t n = min_size(len, head - tail);
    if (n == 0) {
        return 0;
    }

    size_t at = tail & r->mask;
    size_t first = min_size(n, ring_capacity(r) - at);
    memcpy(dst, r->data + at, first);
    memcpy((uint8_t *)dst + first, r->data, n - first);

    atomic_store_explicit(&r->tail, tail + n, memory_order_release);
    return n;
}

/* Look at the next `len` bytes without consuming them. */
size_t ring_peek(ring_t *r, void *dst, size_t len)
{
    size_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    size_t n = min_size(len, head - tail);
    size_t at = tail & r->mask;
    size_t first = min_size(n, ring_capacity(r) - at);
    memcpy(dst, r->data + at, first);
    memcpy((uint8_t *)dst + first, r->data, n - first);
    return n;
}

/* ------------------------------------------------------------------ */
/* Self-test: a producer thread streams a checksummed sequence and    */
/* the consumer verifies every byte arrives once, in order.           */
/* ------------------------------------------------------------------ */

enum { TOTAL_BYTES = 8 * 1024 * 1024, CHUNK = 173 };

static uint8_t pattern_at(size_t i)
{
    /* A cheap sequence that never repeats with period 2^k. */
    return (uint8_t)((i * 2654435761u) >> 13);
}

static void *producer(void *arg)
{
    ring_t *r = arg;
    uint8_t buf[CHUNK];
    size_t sent = 0;

    while (sent < TOTAL_BYTES) {
        size_t want = min_size(CHUNK, TOTAL_BYTES - sent);
        for (size_t i = 0; i < want; i++) {
            buf[i] = pattern_at(sent + i);
        }
        size_t off = 0;
        while (off < want) {
            off += ring_write(r, buf + off, want - off);
        }
        sent += want;
    }
    return NULL;
}

static void unit_tests(void)
{
    ring_t r;
    assert(ring_init(&r, 12) == -1);
    assert(ring_init(&r, 8) == 0);

    char out[8] = {0};
    assert(ring_write(&r, "abcdef", 6) == 6);
    assert(ring_read(&r, out, 4) == 4 && memcmp(out, "abcd", 4) == 0);

    /* This write wraps around the end of the storage. */
    assert(ring_write(&r, "ghijkl", 6) == 6);
    assert(ring_used(&r) == 8);
    assert(ring_write(&r, "x", 1) == 0);

    assert(ring_peek(&r, out, 3) == 3 && memcmp(out, "efg", 3) == 0);
    assert(ring_read(&r, out, 8) == 8 && memcmp(out, "efghijkl", 8) == 0);
    assert(ring_used(&r) == 0);

    ring_free(&r);
}

int main(void)
{
    unit_tests();

    ring_t r;
    if (ring_init(&r, 4096) != 0) {
        fputs("ring_init failed\n", stderr);
        return EXIT_FAILURE;
    }

    pthread_t thread;
    pthread_create(&thread, NULL, producer, &r);

    uint8_t buf[512];
    size_t received = 0;
    size_t errors = 0;
    while (received < TOTAL_BYTES) {
        size_t n = ring_read(&r, buf, sizeof buf);
        for (size_t i = 0; i < n; i++) {
            if (buf[i] != pattern_at(received + i)) {
                errors++;
            }
        }
        received += n;
    }

    pthread_join(thread, NULL);
    ring_free(&r);

    printf("streamed %zu bytes through a %d-byte ring, %zu mismatches\n",
           received, 4096, errors);
    return errors == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

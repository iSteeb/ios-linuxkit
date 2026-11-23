/*
 * Crypto vector driver: exercises TBL/TBX/PMULL/PMULL2/EOR3 (and an AESE
 * canary) with explicit-register asm routines, checks them against plain-C
 * references, and prints a deterministic log. The same source builds two
 * ways: natively (oracle) and as a freestanding static Linux ELF (guest).
 *
 * Output contract (checked by run.sh):
 *   crypto-vector-ok cases=<N> failures=0
 * plus one "<case> <32-hex>" line per case for the native-vs-guest diff.
 */
#include <stdint.h>
#include <stddef.h>
#if defined(__linux__)
/* Freestanding guest build: no libc. */
static void *memcpy(void *d, const void *s, size_t n) {
    for (size_t i = 0; i < n; i++)
        ((uint8_t *)d)[i] = ((const uint8_t *)s)[i];
    return d;
}
static int memcmp(const void *a, const void *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (((const uint8_t *)a)[i] != ((const uint8_t *)b)[i])
            return ((const uint8_t *)a)[i] - ((const uint8_t *)b)[i];
    }
    return 0;
}
#else
#include <string.h>
#endif

#if defined(__linux__)
/* Freestanding guest build: raw syscalls. */
static long sys3(long n, long a, long b, long c) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    __asm__ volatile("svc #0"
                     : "+r"(x0)
                     : "r"(x1), "r"(x2), "r"(x8)
                     : "memory");
    return x0;
}
#define W(fd, buf, len) sys3(64, (fd), (long)(buf), (long)(len))
#define EXIT(code)      sys3(93, (code), 0, 0)
#else
/* Native oracle build: hosted. */
#include <unistd.h>
#define W(fd, buf, len) write((fd), (buf), (len))
#define EXIT(code)      _exit(code)
#endif

void t_tbl16_wrap4(uint8_t *, const uint8_t *, const uint8_t *);
void t_tbl16_1(uint8_t *, const uint8_t *, const uint8_t *);
void t_tbl16_2(uint8_t *, const uint8_t *, const uint8_t *);
void t_tbl16_3(uint8_t *, const uint8_t *, const uint8_t *);
void t_tbl8_wrap4(uint8_t *, const uint8_t *, const uint8_t *);
void t_tbl8_2(uint8_t *, const uint8_t *, const uint8_t *);
void t_tbx16_wrap4(uint8_t *, const uint8_t *, const uint8_t *, const uint8_t *);
void t_tbx16_3(uint8_t *, const uint8_t *, const uint8_t *, const uint8_t *);
void t_tbx8_2(uint8_t *, const uint8_t *, const uint8_t *, const uint8_t *);
void t_pmull8h(uint8_t *, const uint8_t *, const uint8_t *);
void t_pmull2_8h(uint8_t *, const uint8_t *, const uint8_t *);
void t_pmull1q(uint8_t *, const uint8_t *, const uint8_t *);
void t_pmull2_1q(uint8_t *, const uint8_t *, const uint8_t *);
void t_eor3(uint8_t *, const uint8_t *, const uint8_t *, const uint8_t *);
void t_aese(uint8_t *, const uint8_t *, const uint8_t *);

static char outbuf[1 << 16];
static size_t outlen;
static int failures, cases;

static void puts_(const char *s) {
    while (*s && outlen < sizeof(outbuf) - 1)
        outbuf[outlen++] = *s++;
}
static void puthex(const uint8_t *p, size_t n) {
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        outbuf[outlen++] = hex[p[i] >> 4];
        outbuf[outlen++] = hex[p[i] & 15];
    }
}
static void flushout(void) {
    outbuf[outlen++] = '\n';
    size_t off = 0;
    while (off < outlen) {
        long n = W(1, outbuf + off, outlen - off);
        if (n <= 0)
            EXIT(101);
        off += n;
    }
    outlen = 0;
}

/* Deterministic pseudo-random vectors. */
static uint32_t rng_state = 0x12345678;
static uint32_t rng(void) {
    rng_state = rng_state * 1664525u + 1013904223u;
    return rng_state;
}
static void fill(uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i += 4) {
        uint32_t r = rng();
        for (size_t j = 0; j < 4 && i + j < n; j++)
            p[i + j] = (uint8_t)(r >> (8 * j));
    }
}

static void report(const char *name, const uint8_t *got, const uint8_t *ref) {
    cases++;
    if (memcmp(got, ref, 16) != 0)
        failures++;
    puts_(name);
    puts_(" ");
    puthex(got, 16);
    if (memcmp(got, ref, 16) != 0) {
        puts_(" FAIL ref=");
        puthex(ref, 16);
    }
    flushout();
}

/* C references. */
static void ref_tbl(uint8_t *out, const uint8_t *table, unsigned tbytes,
                    const uint8_t *idx, unsigned lanes, int is_tbx,
                    const uint8_t *orig) {
    for (unsigned i = 0; i < 16; i++) {
        unsigned ix = i < lanes ? idx[i] : 0;
        if (i < lanes && ix < tbytes)
            out[i] = table[ix];
        else if (is_tbx && i < lanes)
            out[i] = orig ? orig[i] : 0;   /* TBX keeps orig only in-lanes */
        else
            out[i] = 0;   /* TBL zero-fills; both ops zero the unused upper half */
    }
}

static uint16_t clmul8(uint8_t a, uint8_t b) {
    uint16_t r = 0;
    for (int bit = 0; bit < 8; bit++)
        if ((a >> bit) & 1)
            r ^= (uint16_t)((uint16_t)b << bit);
    return r;
}
typedef unsigned __int128 u128;
static u128 clmul64(uint64_t a, uint64_t b) {
    u128 r = 0;
    for (int bit = 0; bit < 64; bit++)
        if ((a >> bit) & 1)
            r ^= (u128)b << bit;
    return r;
}
static void ref_pmull8h(uint8_t *out, const uint8_t *a, const uint8_t *b,
                        unsigned off) {
    for (unsigned i = 0; i < 8; i++) {
        uint16_t r = clmul8(a[off + i], b[off + i]);
        out[2 * i] = (uint8_t)r;
        out[2 * i + 1] = (uint8_t)(r >> 8);
    }
}
static void ref_pmull1q(uint8_t *out, const uint8_t *a, const uint8_t *b,
                        unsigned off) {
    uint64_t x, y;
    memcpy(&x, a + off, 8);
    memcpy(&y, b + off, 8);
    u128 r = clmul64(x, y);
    memcpy(out, &r, 16);
}

int run(void);

int run(void) {
    uint8_t tbl[64], idx[16], orig[16], a[16], b[16], c[16];
    uint8_t got[16], ref[16];

    for (int iter = 0; iter < 4; iter++) {
        fill(tbl, sizeof tbl);
        fill(idx, sizeof idx);
        fill(orig, sizeof orig);
        fill(a, sizeof a);
        fill(b, sizeof b);
        fill(c, sizeof c);
        /* Bias some indices out of range and some near the wrap boundary. */
        idx[0] = 63; idx[1] = 64; idx[2] = 255; idx[3] = 31; idx[4] = 32;

        t_tbl16_wrap4(got, tbl, idx);
        ref_tbl(ref, tbl, 64, idx, 16, 0, NULL);
        report("tbl16-wrap4", got, ref);

        t_tbl16_1(got, tbl, idx);
        ref_tbl(ref, tbl, 16, idx, 16, 0, NULL);
        report("tbl16-1", got, ref);

        t_tbl16_2(got, tbl, idx);
        ref_tbl(ref, tbl, 32, idx, 16, 0, NULL);
        report("tbl16-2", got, ref);

        t_tbl16_3(got, tbl, idx);
        ref_tbl(ref, tbl, 48, idx, 16, 0, NULL);
        report("tbl16-3", got, ref);

        t_tbl8_wrap4(got, tbl, idx);
        ref_tbl(ref, tbl, 64, idx, 8, 0, NULL);
        report("tbl8-wrap4", got, ref);

        t_tbl8_2(got, tbl, idx);
        ref_tbl(ref, tbl, 32, idx, 8, 0, NULL);
        report("tbl8-2", got, ref);

        t_tbx16_wrap4(got, tbl, idx, orig);
        ref_tbl(ref, tbl, 64, idx, 16, 1, orig);
        report("tbx16-wrap4", got, ref);

        t_tbx16_3(got, tbl, idx, orig);
        ref_tbl(ref, tbl, 48, idx, 16, 1, orig);
        report("tbx16-3", got, ref);

        t_tbx8_2(got, tbl, idx, orig);
        ref_tbl(ref, tbl, 32, idx, 8, 1, orig);
        report("tbx8-2", got, ref);

        t_pmull8h(got, a, b);
        ref_pmull8h(ref, a, b, 0);
        report("pmull8h", got, ref);

        t_pmull2_8h(got, a, b);
        ref_pmull8h(ref, a, b, 8);
        report("pmull2-8h", got, ref);

        t_pmull1q(got, a, b);
        ref_pmull1q(ref, a, b, 0);
        report("pmull1q", got, ref);

        t_pmull2_1q(got, a, b);
        ref_pmull1q(ref, a, b, 8);
        report("pmull2-1q", got, ref);

        t_eor3(got, a, b, c);
        for (int i = 0; i < 16; i++)
            ref[i] = a[i] ^ b[i] ^ c[i];
        report("eor3", got, ref);

        t_aese(got, a, b);
        report("aese", got, got);   /* hardware oracle only: native==guest */
    }

    puts_("crypto-vector-ok cases=");
    char nbuf[12];
    int pos = 0;
    if (cases == 0)
        nbuf[pos++] = '0';
    for (int d = 1000000000; d > 0; d /= 10) {
        if (cases / d > 0 || pos > 0)
            nbuf[pos++] = '0' + (cases / d) % 10;
    }
    for (int i = 0; i < pos; i++)
        outbuf[outlen++] = nbuf[i];
    puts_(" failures=");
    outbuf[outlen++] = '0' + (failures < 10 ? failures : 9);
    flushout();
    return failures;
}

#if defined(__linux__)
void _start(void) {
    EXIT(run());
}
#else
int main(void) {
    return run();
}
#endif

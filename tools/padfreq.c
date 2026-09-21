/*
 * padfreq.c - estimate the toggle frequency of a Qualcomm SM8450 TLMM GPIO
 * pad by polling its GPIO_IN_OUT register through /dev/mem as fast as
 * possible.
 *
 * Replaces tools/padsample.py for single-pin, high-rate sampling: the Python
 * version's per-read struct.unpack + list overhead caps it far below what
 * the register can actually be sampled at. This does the same mmap, but in
 * a tight C loop with a volatile pointer, so the sample rate is limited by
 * /dev/mem access latency rather than interpreter overhead.
 *
 * Register layout (TLMM base 0xf100000):
 *   pin N lives at base + N*0x1000
 *   GPIO_CFG    at offset 0x0
 *   GPIO_IN_OUT at offset 0x4, input level is bit 0
 *
 * WARNING: pins 36-39 and 210 must NEVER be read on this board (gts8pwifi) -
 * touching those TLMM registers hangs the SoC. This program refuses them
 * (and anything outside 0..210) at runtime; do not remove that check.
 *
 * Usage: padfreq PIN [SECONDS]     (SECONDS default 2)
 *
 * Build: cc -O2 -static -o padfreq padfreq.c
 */

#define _POSIX_C_SOURCE 199309L

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <time.h>

#define TLMM_BASE   0xf100000UL
#define PIN_STRIDE  0x1000UL
#define GPIO_CFG_OFF    0x0
#define GPIO_IN_OUT_OFF 0x4
#define MAP_LEN     0x1000UL

#define PIN_MIN 0
#define PIN_MAX 210

#define CLOCK_CHECK_INTERVAL 4096

static int pin_is_forbidden(int pin)
{
    if (pin >= 36 && pin <= 39)
        return 1;
    if (pin == 210)
        return 1;
    return 0;
}

static double timespec_diff(const struct timespec *end, const struct timespec *start)
{
    double sec = (double)(end->tv_sec - start->tv_sec);
    double nsec = (double)(end->tv_nsec - start->tv_nsec);
    return sec + nsec / 1e9;
}

int main(int argc, char **argv)
{
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: %s PIN [SECONDS]\n", argv[0]);
        return 2;
    }

    char *endp = NULL;
    long pin = strtol(argv[1], &endp, 10);
    if (endp == argv[1] || *endp != '\0') {
        fprintf(stderr, "padfreq: PIN must be an integer\n");
        return 2;
    }

    double seconds = 2.0;
    if (argc == 3) {
        endp = NULL;
        seconds = strtod(argv[2], &endp);
        if (endp == argv[2] || *endp != '\0' || seconds <= 0.0) {
            fprintf(stderr, "padfreq: SECONDS must be a positive number\n");
            return 2;
        }
    }

    if (pin < PIN_MIN || pin > PIN_MAX) {
        fprintf(stderr, "padfreq: pin %ld out of range 0..%d, refusing\n",
                pin, PIN_MAX);
        return 1;
    }
    if (pin_is_forbidden((int)pin)) {
        fprintf(stderr,
                "padfreq: pin %ld is on the forbidden list (36-39, 210) - "
                "reading it hangs the SoC on this board. Refusing.\n", pin);
        return 1;
    }

    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "padfreq: open /dev/mem: %s\n", strerror(errno));
        return 1;
    }

    off_t base = (off_t)TLMM_BASE + (off_t)pin * (off_t)PIN_STRIDE;
    void *map = mmap(NULL, MAP_LEN, PROT_READ, MAP_SHARED, fd, base);
    if (map == MAP_FAILED) {
        fprintf(stderr, "padfreq: mmap: %s\n", strerror(errno));
        close(fd);
        return 1;
    }

    volatile uint32_t *cfg_reg = (volatile uint32_t *)((char *)map + GPIO_CFG_OFF);
    volatile uint32_t *in_out_reg = (volatile uint32_t *)((char *)map + GPIO_IN_OUT_OFF);

    uint32_t ctl = *cfg_reg;

    unsigned long reads = 0;
    unsigned long transitions = 0;
    unsigned long hist[2] = {0, 0};
    int last = -1;

    struct timespec t_start, t_now;
    clock_gettime(CLOCK_MONOTONIC, &t_start);
    double elapsed = 0.0;

    for (;;) {
        unsigned long batch = 0;
        while (batch < CLOCK_CHECK_INTERVAL) {
            uint32_t v = (*in_out_reg) & 1u;
            hist[v]++;
            if (last != -1 && (int)v != last)
                transitions++;
            last = (int)v;
            reads++;
            batch++;
        }
        clock_gettime(CLOCK_MONOTONIC, &t_now);
        elapsed = timespec_diff(&t_now, &t_start);
        if (elapsed >= seconds)
            break;
    }

    munmap(map, MAP_LEN);
    close(fd);

    double reads_per_sec = elapsed > 0.0 ? (double)reads / elapsed : 0.0;
    double est_freq_hz = (double)transitions / 2.0 / elapsed;
    double transitions_per_read = reads > 0 ? (double)transitions / (double)reads : 0.0;

    printf("pin=%ld ctl=0x%08x reads=%lu elapsed=%.3fs reads/s=%.1f\n",
           pin, ctl, reads, elapsed, reads_per_sec);
    printf("transitions=%lu est_freq=%.2f Hz (transitions / 2 / seconds)\n",
           transitions, est_freq_hz);
    printf("high=%lu low=%lu\n", hist[1], hist[0]);
    if (transitions_per_read > 0.4)
        printf("note: transitions/read=%.3f is near 0.5 - the pad is toggling "
               "faster than this sampler resolves; the estimate above is only "
               "a lower bound.\n", transitions_per_read);

    return 0;
}

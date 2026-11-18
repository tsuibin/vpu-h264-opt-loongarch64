/*
 * memlog.c - LD_PRELOAD interceptor that logs large memset/memmove calls.
 *
 * Build:  gcc -shared -fPIC -o memlog.so memlog.c -ldl
 * Use:    LD_PRELOAD=$PWD/tools/memlog.so ffmpeg ... 2>&1 | grep '\[MEM'
 *
 * Only allocations/copies over 1 MiB are printed, so normal runtime noise
 * stays quiet. This file is a diagnostic aid; it does not modify the driver.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stddef.h>

static void *(*real_memmove)(void *, const void *, size_t);
static void *(*real_memset)(void *, int, size_t);
#define THRESHOLD (1u << 20)

void *memmove(void *dst, const void *src, size_t n)
{
    if (!real_memmove)
        real_memmove = dlsym(RTLD_NEXT, "memmove");
    if (n > THRESHOLD)
        fprintf(stderr, "[MEMMOVE] %zu\n", n);
    return real_memmove(dst, src, n);
}

void *memset(void *dst, int c, size_t n)
{
    if (!real_memset)
        real_memset = dlsym(RTLD_NEXT, "memset");
    if (n > THRESHOLD)
        fprintf(stderr, "[MEMSET] %zu\n", n);
    return real_memset(dst, c, n);
}

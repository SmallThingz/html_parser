#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((uint64_t)ts.tv_sec * 1000000000ULL) + (uint64_t)ts.tv_nsec;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <html-file> <iterations>\n", argv[0]);
        return 2;
    }

    const char *path = argv[1];
    const size_t iterations = (size_t)strtoull(argv[2], NULL, 10);

    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        perror("fopen");
        return 1;
    }

    if (fseek(f, 0, SEEK_END) != 0) {
        perror("fseek");
        fclose(f);
        return 1;
    }
    const long fsize = ftell(f);
    if (fsize < 0) {
        perror("ftell");
        fclose(f);
        return 1;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        perror("fseek");
        fclose(f);
        return 1;
    }

    const size_t size = (size_t)fsize;
    char *buf = (char *)malloc(size + 1);
    if (buf == NULL) {
        perror("malloc");
        fclose(f);
        return 1;
    }

    if (size > 0 && fread(buf, 1, size, f) != size) {
        perror("fread");
        free(buf);
        fclose(f);
        return 1;
    }
    fclose(f);
    buf[size] = '\0';

    volatile size_t sink = 0;
    const uint64_t start = now_ns();
    for (size_t i = 0; i < iterations; i++) {
        sink += strlen(buf);
    }
    const uint64_t end = now_ns();

    if (sink == (size_t)-1) {
        fprintf(stderr, "unreachable\n");
    }

    printf("%llu\n", (unsigned long long)(end - start));
    free(buf);
    return 0;
}

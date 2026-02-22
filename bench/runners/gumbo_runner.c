#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "gumbo.h"

typedef struct {
    void **ptrs;
    size_t len;
    size_t cap;
} reset_alloc_t;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return NULL;
    }
    long sz = ftell(f);
    if (sz < 0) {
        fclose(f);
        return NULL;
    }
    rewind(f);

    char *buf = (char *)malloc((size_t)sz);
    if (!buf) {
        fclose(f);
        return NULL;
    }

    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *out_len = (size_t)sz;
    return buf;
}

static int reset_alloc_push(reset_alloc_t *a, void *ptr) {
    if (a->len == a->cap) {
        size_t new_cap = (a->cap == 0) ? 1024 : a->cap * 2;
        void **next = (void **)realloc(a->ptrs, new_cap * sizeof(void *));
        if (!next) return 0;
        a->ptrs = next;
        a->cap = new_cap;
    }
    a->ptrs[a->len++] = ptr;
    return 1;
}

static void *reset_alloc_fn(void *userdata, size_t size) {
    reset_alloc_t *a = (reset_alloc_t *)userdata;
    if (size == 0) size = 1;
    void *ptr = malloc(size);
    if (!ptr) return NULL;
    if (!reset_alloc_push(a, ptr)) {
        free(ptr);
        return NULL;
    }
    return ptr;
}

static void reset_dealloc_fn(void *userdata, void *ptr) {
    (void)userdata;
    (void)ptr;
    // No-op. We free everything in bulk on reset.
}

static void reset_alloc_reset(reset_alloc_t *a) {
    for (size_t i = 0; i < a->len; i++) {
        free(a->ptrs[i]);
    }
    a->len = 0;
}

static void reset_alloc_destroy(reset_alloc_t *a) {
    reset_alloc_reset(a);
    free(a->ptrs);
    a->ptrs = NULL;
    a->cap = 0;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <html-file> <iterations>\n", argv[0]);
        return 2;
    }

    size_t len = 0;
    char *input = read_file(argv[1], &len);
    if (!input) {
        fprintf(stderr, "failed to read file: %s\n", argv[1]);
        return 1;
    }

    size_t iterations = (size_t)strtoull(argv[2], NULL, 10);
    reset_alloc_t arena = {0};

    GumboOptions options = kGumboDefaultOptions;
    options.allocator = reset_alloc_fn;
    options.deallocator = reset_dealloc_fn;
    options.userdata = &arena;

    uint64_t start = now_ns();

    for (size_t i = 0; i < iterations; i++) {
        GumboOutput *out = gumbo_parse_with_options(&options, input, len);
        if (out == NULL) {
            reset_alloc_destroy(&arena);
            free(input);
            return 1;
        }
        (void)out;
        reset_alloc_reset(&arena);
    }

    uint64_t end = now_ns();
    printf("%llu\n", (unsigned long long)(end - start));
    reset_alloc_destroy(&arena);
    free(input);
    return 0;
}

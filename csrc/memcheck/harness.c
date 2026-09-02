/* Drives `litedoc4_md_events` over files, under whatever sanitizer the build
 * turned on. `tools/md-memory-gate.sh` is what builds and runs it.
 *
 * What is asserted here is nothing: a wrong event stream is
 * `test/Litedoc4Test/MdParse.lean`'s subject and a wrong `<p>` is
 * `MdOracle.lean`'s. This file exists so that md4c and `md_events.c` execute
 * with their allocations watched, and the judgement is the sanitizer's.
 *
 * usage: harness <md4c-flag-word> <file>...
 */
#include <lean/lean.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

lean_obj_res litedoc4_md_events(b_lean_obj_arg input, uint32_t flags);

struct lean_object {
    unsigned char *payload;
    size_t size;
};

static void *xmalloc(size_t n) {
    void *p = malloc(n);
    if (p == NULL) {
        fprintf(stderr, "harness: out of memory asking for %zu byte(s)\n", n);
        exit(70);
    }
    return p;
}

size_t lean_string_size(b_lean_obj_arg s) { return s->size; }

char const *lean_string_cstr(b_lean_obj_arg s) { return (char const *)s->payload; }

lean_obj_res lean_alloc_sarray(unsigned elem_size, size_t size, size_t capacity) {
    size_t bytes = (size_t)elem_size * capacity;
    lean_object *o = (lean_object *)xmalloc(sizeof *o);
    o->payload = bytes ? (unsigned char *)xmalloc(bytes) : NULL;
    o->size = size;
    return o;
}

uint8_t *lean_sarray_cptr(lean_object *o) { return o->payload; }

static void lean_object_free(lean_object *o) {
    free(o->payload);
    free(o);
}

/* Lean counts the NUL terminator in a string's size and `md_events.c` subtracts
 * it back off, so standing in for `lean_string_size` means standing in for that
 * convention too. */
static lean_object *lean_string_of(const unsigned char *data, size_t len) {
    lean_object *o = (lean_object *)xmalloc(sizeof *o);
    o->payload = (unsigned char *)xmalloc(len + 1);
    if (len != 0) {
        memcpy(o->payload, data, len);
    }
    o->payload[len] = 0;
    o->size = len + 1;
    return o;
}

static unsigned char *read_whole_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        fprintf(stderr, "harness: cannot open %s\n", path);
        return NULL;
    }
    size_t cap = 65536;
    size_t used = 0;
    unsigned char *buf = (unsigned char *)xmalloc(cap);
    for (;;) {
        if (used == cap) {
            cap *= 2;
            unsigned char *grown = (unsigned char *)realloc(buf, cap);
            if (grown == NULL) {
                free(buf);
                fclose(f);
                fprintf(stderr, "harness: out of memory reading %s\n", path);
                return NULL;
            }
            buf = grown;
        }
        size_t got = fread(buf + used, 1, cap - used, f);
        used += got;
        if (got == 0) {
            break;
        }
    }
    int bad = ferror(f);
    fclose(f);
    if (bad) {
        free(buf);
        fprintf(stderr, "harness: read error on %s\n", path);
        return NULL;
    }
    *len = used;
    return buf;
}

/* A conservative leak scanner reads the whole thread stack, and a dead frame
 * still holding the pointer `md_events.c` last had makes a leak look reachable.
 * Overwriting the region those frames used is what lets a green leak report be
 * believed. What would falsify it: a scanner that only reads live frames, which
 * would make this dead weight rather than wrong. */
static void scrub_stack(void) {
    volatile unsigned char pad[262144];
    for (size_t i = 0; i < sizeof pad; i++) {
        pad[i] = 0xA5;
    }
}

/* Summed rather than ignored: a loop whose result nothing reads is a loop the
 * compiler may drop, and the point of the loop is to touch every byte of the
 * buffer `md_events.c` sized. */
static int run_file(const char *path, uint32_t flags, unsigned long long *total) {
    size_t len = 0;
    unsigned char *bytes = read_whole_file(path, &len);
    if (bytes == NULL) {
        return 1;
    }
    lean_object *input = lean_string_of(bytes, len);
    free(bytes);

    lean_obj_res out = litedoc4_md_events(input, flags);
    size_t n = out->size;
    unsigned long long checksum = 0;
    const uint8_t *p = lean_sarray_cptr(out);
    for (size_t i = 0; i < n; i++) {
        checksum += p[i];
    }
    printf("harness: %s  in %zu  out %zu  checksum %llu\n", path, len, n, checksum);
    lean_object_free(out);
    lean_object_free(input);
    *total += (unsigned long long)n;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: harness <md4c-flag-word> <file>...\n");
        return 2;
    }
    char *end = NULL;
    unsigned long flags = strtoul(argv[1], &end, 0);
    if (end == argv[1] || *end != '\0') {
        fprintf(stderr, "harness: %s is not a flag word\n", argv[1]);
        return 2;
    }
    unsigned long long total = 0;
    int files = 0;
    for (int i = 2; i < argc; i++) {
        if (run_file(argv[i], (uint32_t)flags, &total) != 0) {
            return 1;
        }
        scrub_stack();
        files++;
    }
    printf("harness: %d file(s), flags 0x%lX, %llu event byte(s)\n", files, flags, total);
    return 0;
}

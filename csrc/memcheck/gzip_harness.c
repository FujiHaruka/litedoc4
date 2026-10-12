/* Drives `csrc/gzip.c` over gzip members, whole and cut in two at every byte,
 * for `tools/gzip-memory-gate.sh`; the judgement is the sanitizer's.
 *
 * usage: gzip_harness <member>...
 */
#include <lean/lean.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

lean_obj_res litedoc4_gzip_inflate_member(b_lean_obj_arg input);
lean_obj_res litedoc4_gzip_reader_new(size_t member_bytes);
lean_obj_res litedoc4_gzip_reader_pull(b_lean_obj_arg reader, b_lean_obj_arg input, size_t pos,
                                       lean_obj_arg dest, size_t want, uint8_t to_line_end);

enum kind { SARRAY, CTOR, EXTERNAL };

struct lean_object {
    int rc;
    enum kind kind;
    unsigned char *payload;
    size_t size;
    size_t capacity;
    unsigned tag;
    unsigned num_objs;
    lean_object **fields;
    lean_external_class *cls;
    void *data;
};

static void *xmalloc(size_t n) {
    void *p = malloc(n);
    if (p == NULL) {
        fprintf(stderr, "harness: out of memory asking for %zu byte(s)\n", n);
        exit(70);
    }
    return p;
}

static int is_scalar(lean_object *o) { return ((size_t)o & 1) != 0; }

static size_t unbox(lean_object *o) { return (size_t)o >> 1; }

static lean_object *new_object(enum kind kind) {
    lean_object *o = (lean_object *)xmalloc(sizeof *o);
    memset(o, 0, sizeof *o);
    o->rc = 1;
    o->kind = kind;
    return o;
}

lean_obj_res lean_alloc_sarray(unsigned elem_size, size_t size, size_t capacity) {
    size_t bytes = (size_t)elem_size * capacity;
    lean_object *o = new_object(SARRAY);
    o->payload = bytes ? (unsigned char *)xmalloc(bytes) : NULL;
    o->size = size;
    o->capacity = capacity;
    return o;
}

uint8_t *lean_sarray_cptr(lean_object *o) { return o->payload; }

size_t lean_sarray_size(b_lean_obj_arg o) { return o->size; }

size_t lean_sarray_capacity(lean_object *o) { return o->capacity; }

void lean_sarray_set_size(lean_obj_arg o, size_t size) {
    if (size > o->capacity) {
        fprintf(stderr, "harness: size %zu set past capacity %zu\n", size, o->capacity);
        abort();
    }
    o->size = size;
}

bool lean_is_exclusive(lean_object *o) { return !is_scalar(o) && o->rc == 1; }

void lean_dec_ref(lean_object *o) {
    if (is_scalar(o) || --o->rc > 0) {
        return;
    }
    if (o->kind == SARRAY) {
        free(o->payload);
    } else if (o->kind == CTOR) {
        for (unsigned i = 0; i < o->num_objs; i++) {
            lean_dec_ref(o->fields[i]);
        }
        free(o->fields);
    } else {
        o->cls->m_finalize(o->data);
    }
    free(o);
}

lean_obj_res lean_box(size_t n) { return (lean_object *)((n << 1) | 1); }

lean_obj_res lean_usize_to_nat(size_t n) { return lean_box(n); }

lean_obj_res lean_alloc_ctor(unsigned tag, unsigned num_objs, unsigned scalar_sz) {
    (void)scalar_sz;
    lean_object *o = new_object(CTOR);
    o->tag = tag;
    o->num_objs = num_objs;
    o->fields = (lean_object **)xmalloc(num_objs * sizeof *o->fields);
    for (unsigned i = 0; i < num_objs; i++) {
        o->fields[i] = lean_box(0);
    }
    return o;
}

void lean_ctor_set(b_lean_obj_arg o, unsigned i, lean_obj_arg v) { o->fields[i] = v; }

static lean_external_class the_class;

lean_external_class *lean_register_external_class(lean_external_finalize_proc finalize,
                                                  lean_external_foreach_proc foreach) {
    the_class.m_finalize = finalize;
    the_class.m_foreach = foreach;
    return &the_class;
}

lean_obj_res lean_alloc_external(lean_external_class *cls, void *data) {
    lean_object *o = new_object(EXTERNAL);
    o->cls = cls;
    o->data = data;
    return o;
}

void *lean_get_external_data(lean_object *o) { return o->data; }

_Noreturn void lean_internal_panic_out_of_memory(void) {
    fprintf(stderr, "harness: the C under test reported out of memory\n");
    exit(70);
}

static lean_object *steal(lean_object *ctor, unsigned i) {
    lean_object *v = ctor->fields[i];
    ctor->fields[i] = lean_box(0);
    return v;
}

static lean_object *bytes_of(const unsigned char *p, size_t n) {
    lean_object *o = lean_alloc_sarray(1, n, n);
    if (n != 0) {
        memcpy(o->payload, p, n);
    }
    return o;
}

static unsigned long long sum_of(lean_object *bytes) {
    unsigned long long sum = 0;
    for (size_t i = 0; i < bytes->size; i++) {
        sum += bytes->payload[i];
    }
    return sum;
}

struct tally {
    unsigned long long reads;
    unsigned long long unanswered;
    unsigned long long inflated;
    unsigned long long sum;
};

static void read_whole(const unsigned char *m, size_t n, struct tally *t) {
    lean_object *input = bytes_of(m, n);
    lean_object *r = litedoc4_gzip_inflate_member(input);
    if (r->tag == 1) {
        t->inflated += r->fields[0]->size;
        t->sum += sum_of(r->fields[0]);
    }
    lean_dec_ref(r);
    lean_dec_ref(input);
    t->reads++;
}

static const size_t wants[] = {0, 7, 0, 1, 4096, 0, (size_t)1 << 20};

static void read_split(const unsigned char *m, size_t n, size_t cut, struct tally *t) {
    size_t ends[2] = {cut, n};
    unsigned piece = (cut == 0 || cut >= n) ? 1 : 0;
    lean_object *reader = litedoc4_gzip_reader_new(n);
    lean_object *input = bytes_of(m, ends[piece]);
    size_t pos = 0;
    lean_object *dest = lean_alloc_sarray(1, 0, 0);
    unsigned step = 0;
    for (;;) {
        size_t want = wants[step % (sizeof wants / sizeof wants[0])];
        lean_object *r = litedoc4_gzip_reader_pull(reader, input, pos, dest,
                                                   want == 0 ? SIZE_MAX : want, want == 0);
        dest = steal(r, 0);
        pos = unbox(r->fields[1]);
        lean_object *outcome = steal(r, 2);
        lean_dec_ref(r);
        size_t answer = unbox(outcome->fields[0]);
        unsigned refused = outcome->tag == 0;
        lean_dec_ref(outcome);
        if (refused) {
            break;
        }
        if (answer == 0 && piece == 1) {
            t->unanswered++;
            break;
        }
        if (answer == 0) {
            lean_dec_ref(input);
            piece = 1;
            input = bytes_of(m + cut, n - cut);
            pos = 0;
            continue;
        }
        t->inflated += dest->size;
        t->sum += sum_of(dest);
        lean_dec_ref(dest);
        dest = lean_alloc_sarray(1, 0, 0);
        step++;
        if (answer == 2) {
            break;
        }
    }
    lean_dec_ref(dest);
    lean_dec_ref(input);
    lean_dec_ref(reader);
    t->reads++;
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

/* Not skipped: a dead frame still holding the reader would make its leak look reachable. */
static void scrub_stack(void) {
    volatile unsigned char pad[262144];
    for (size_t i = 0; i < sizeof pad; i++) {
        pad[i] = 0xA5;
    }
}

#define EVERY_CUT_UP_TO 4096

static int run_member(const char *path, struct tally *t) {
    size_t n = 0;
    unsigned char *m = read_whole_file(path, &n);
    if (m == NULL) {
        return 1;
    }
    unsigned long long before = t->reads;
    read_whole(m, n, t);
    for (size_t cut = 0; cut < n; cut++) {
        if (n <= EVERY_CUT_UP_TO || cut < 64 || n - cut <= 64 || cut % 4093 == 0) {
            read_split(m, n, cut, t);
            scrub_stack();
        }
    }
    printf("harness: %s  bytes %zu  reads %llu\n", path, n, t->reads - before);
    free(m);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: gzip_harness <member>...\n");
        return 2;
    }
    struct tally t = {0, 0, 0, 0};
    for (int i = 1; i < argc; i++) {
        if (run_member(argv[i], &t) != 0) {
            return 1;
        }
    }
    printf("harness: %d member(s), %llu read(s), %llu unanswered, %llu byte(s) inflated, "
           "checksum %llu\n",
           argc - 1, t.reads, t.unanswered, t.inflated, t.sum);
    return 0;
}

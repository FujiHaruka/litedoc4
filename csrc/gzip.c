/* Frames miniz's raw deflate as a gzip member (RFC 1952). miniz is MIT,
 * Copyright 2013-2014 RAD Game Tools and Valve Software and Copyright 2010-2014
 * Rich Geldreich and Tenacious Software LLC; it is `vendor/miniz/miniz.c`,
 * unmodified. See this repository's NOTICE and `vendor/miniz/PROVENANCE.md`.
 */

#include <lean/lean.h>

#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "miniz.h"

#define GZ_HEADER_SIZE 10
#define GZ_TRAILER_SIZE 8
#define GZ_ID1 0x1f
#define GZ_ID2 0x8b
#define GZ_CM_DEFLATE 8
#define GZ_OS_UNKNOWN 255

#define GZ_FHCRC 0x02
#define GZ_FEXTRA 0x04
#define GZ_FNAME 0x08
#define GZ_FCOMMENT 0x10
#define GZ_FRESERVED 0xe0

#define RAW_DEFLATE_WINDOW_BITS (-15)
#define DEFLATE_MAX_EXPANSION 1032
#define DEFLATE_WINDOW TINFL_LZ_DICT_SIZE
#define OUTPUT_SIZE (4 * DEFLATE_WINDOW)

#define FIRST_PIECE ((size_t)1 << 20)
#define FIRST_LINE ((size_t)64)

enum refusal {
    SHORTER_THAN_A_MEMBER,
    NOT_GZIP,
    NOT_DEFLATE,
    RESERVED_FLAG_SET,
    HEADER_RUNS_INTO_TRAILER,
    HEADER_CHECKSUM_MISMATCH,
    TRAILER_CLAIMS_MORE_THAN_DEFLATE_CAN_HOLD,
    CORRUPT_DEFLATE,
    TRUNCATED_DEFLATE,
    BYTES_BETWEEN_DEFLATE_AND_TRAILER,
    LONGER_THAN_ITS_TRAILER_SAYS,
    SHORTER_THAN_ITS_TRAILER_SAYS,
    CHECKSUM_MISMATCH
};

enum pulled { NEEDS_INPUT, FILLED, ENDED, REFUSED };

enum header_step { FIXED, XLEN, EXTRA, NAME, COMMENT, HCRC, BODY };

struct gz_member {
    tinfl_decompressor inflator;
    size_t size;
    size_t received;
    size_t trailer_at;
    size_t body_at;
    enum header_step step;
    uint8_t flags;
    size_t field_left;
    uint8_t field[2];
    uint32_t header_crc;
    int refused;
    int inflating;
    tinfl_status status;
    size_t produced;
    uint32_t crc;
    size_t past_deflate;
    uint8_t trailer[GZ_TRAILER_SIZE];
    size_t out_at;
    size_t out_end;
    uint8_t out[OUTPUT_SIZE];
};

static void put_le32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static uint32_t get_le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static uint32_t crc32_of(const uint8_t *p, size_t n) {
    return (uint32_t)mz_crc32(MZ_CRC32_INIT, p, n);
}

lean_obj_res litedoc4_gzip_compress(uint8_t level, b_lean_obj_arg input) {
    const uint8_t *src = lean_sarray_cptr(input);
    size_t n = lean_sarray_size(input);
    int flags = (int)tdefl_create_comp_flags_from_zip_params(
        (int)level, RAW_DEFLATE_WINDOW_BITS, MZ_DEFAULT_STRATEGY);
    size_t body_len = 0;
    void *body = tdefl_compress_mem_to_heap(src, n, &body_len, flags);
    if (body == NULL) {
        lean_internal_panic_out_of_memory();
    }

    size_t total = GZ_HEADER_SIZE + body_len + GZ_TRAILER_SIZE;
    lean_obj_res out = lean_alloc_sarray(1, total, total);
    uint8_t *dst = lean_sarray_cptr(out);
    static const uint8_t header[GZ_HEADER_SIZE] = {
        GZ_ID1, GZ_ID2, GZ_CM_DEFLATE, 0, 0, 0, 0, 0, 0, GZ_OS_UNKNOWN};
    memcpy(dst, header, GZ_HEADER_SIZE);
    memcpy(dst + GZ_HEADER_SIZE, body, body_len);
    free(body);
    put_le32(dst + GZ_HEADER_SIZE + body_len, crc32_of(src, n));
    put_le32(dst + GZ_HEADER_SIZE + body_len + 4, (uint32_t)n);
    return out;
}

static lean_obj_res refused(int why) {
    lean_obj_res r = lean_alloc_ctor(0, 1, 0);
    lean_ctor_set(r, 0, lean_box((size_t)why));
    return r;
}

static lean_obj_res accepted(lean_obj_res value) {
    lean_obj_res r = lean_alloc_ctor(1, 1, 0);
    lean_ctor_set(r, 0, value);
    return r;
}

static void member_init(struct gz_member *m, size_t size) {
    tinfl_init(&m->inflator);
    m->size = size;
    m->received = 0;
    m->trailer_at = size < GZ_HEADER_SIZE + GZ_TRAILER_SIZE ? size : size - GZ_TRAILER_SIZE;
    m->body_at = 0;
    m->step = FIXED;
    m->flags = 0;
    m->field_left = 0;
    m->header_crc = MZ_CRC32_INIT;
    m->refused = size < GZ_HEADER_SIZE + GZ_TRAILER_SIZE ? SHORTER_THAN_A_MEMBER : -1;
    m->inflating = 0;
    m->status = TINFL_STATUS_NEEDS_MORE_INPUT;
    m->produced = 0;
    m->crc = MZ_CRC32_INIT;
    m->past_deflate = 0;
    m->out_at = 0;
    m->out_end = 0;
}

static void refuse(struct gz_member *m, enum refusal why) {
    if (m->refused < 0) {
        m->refused = (int)why;
    }
}

static void enter(struct gz_member *m, enum header_step step) {
    for (;;) {
        if (step == XLEN && !(m->flags & GZ_FEXTRA)) {
            step = NAME;
        } else if (step == XLEN) {
            m->field_left = 2;
            break;
        } else if (step == EXTRA && m->field_left == 0) {
            step = NAME;
        } else if (step == NAME && !(m->flags & GZ_FNAME)) {
            step = COMMENT;
        } else if (step == COMMENT && !(m->flags & GZ_FCOMMENT)) {
            step = HCRC;
        } else if (step == HCRC && !(m->flags & GZ_FHCRC)) {
            step = BODY;
        } else if (step == HCRC) {
            m->field_left = 2;
            break;
        } else {
            break;
        }
    }
    m->step = step;
    if (step == BODY) {
        m->body_at = m->received;
        m->inflating = 1;
    }
}

static void take_header_byte(struct gz_member *m, uint8_t b) {
    size_t at = m->received;
    enum header_step next = m->step;
    if (m->step != HCRC) {
        m->header_crc = (uint32_t)mz_crc32(m->header_crc, &b, 1);
    }
    switch (m->step) {
    case FIXED:
        if ((at == 0 && b != GZ_ID1) || (at == 1 && b != GZ_ID2)) {
            refuse(m, NOT_GZIP);
        } else if (at == 2 && b != GZ_CM_DEFLATE) {
            refuse(m, NOT_DEFLATE);
        } else if (at == 3 && (b & GZ_FRESERVED)) {
            refuse(m, RESERVED_FLAG_SET);
        } else if (at == 3) {
            m->flags = b;
        }
        if (at == GZ_HEADER_SIZE - 1) {
            next = XLEN;
        }
        break;
    case XLEN:
        m->field[2 - m->field_left] = b;
        if (--m->field_left == 0) {
            m->field_left = (size_t)m->field[0] | ((size_t)m->field[1] << 8);
            next = EXTRA;
        }
        break;
    case EXTRA:
        if (--m->field_left == 0) {
            next = NAME;
        }
        break;
    case NAME:
        if (b == 0) {
            next = COMMENT;
        }
        break;
    case COMMENT:
        if (b == 0) {
            next = HCRC;
        }
        break;
    case HCRC:
        m->field[2 - m->field_left] = b;
        if (--m->field_left == 0) {
            uint32_t want = (uint32_t)m->field[0] | ((uint32_t)m->field[1] << 8);
            if ((m->header_crc & 0xffff) != want) {
                refuse(m, HEADER_CHECKSUM_MISMATCH);
            }
            next = BODY;
        }
        break;
    case BODY:
        break;
    }
    m->received++;
    if (next != m->step && m->refused < 0) {
        enter(m, next);
    }
}

static void take_framing(struct gz_member *m, const uint8_t *in, size_t len, size_t *pos) {
    while (*pos < len && m->received < m->size) {
        if (m->refused >= 0) {
            size_t n = len - *pos;
            if (n > m->size - m->received) {
                n = m->size - m->received;
            }
            *pos += n;
            m->received += n;
        } else if (m->received >= m->trailer_at && m->step != BODY) {
            refuse(m, HEADER_RUNS_INTO_TRAILER);
        } else if (m->received >= m->trailer_at) {
            m->trailer[m->received - m->trailer_at] = in[*pos];
            (*pos)++;
            m->received++;
        } else if (m->step != BODY) {
            take_header_byte(m, in[(*pos)++]);
        } else if (m->inflating) {
            return;
        } else {
            size_t n = len - *pos;
            if (n > m->trailer_at - m->received) {
                n = m->trailer_at - m->received;
            }
            if (m->status == TINFL_STATUS_DONE) {
                m->past_deflate += n;
            }
            *pos += n;
            m->received += n;
        }
    }
}

static void inflate_some(struct gz_member *m, const uint8_t *in, size_t len, size_t *pos) {
    if (m->out_end == OUTPUT_SIZE) {
        memmove(m->out, m->out + OUTPUT_SIZE - DEFLATE_WINDOW, DEFLATE_WINDOW);
        m->inflator.m_dist_from_out_buf_start -= OUTPUT_SIZE - DEFLATE_WINDOW;
        m->out_at = DEFLATE_WINDOW;
        m->out_end = DEFLATE_WINDOW;
    }
    size_t in_n = 0;
    if (m->received < m->trailer_at) {
        in_n = len - *pos;
        if (in_n > m->trailer_at - m->received) {
            in_n = m->trailer_at - m->received;
        }
    }
    size_t out_n = OUTPUT_SIZE - m->out_end;
    /* Not a wrapping 32 KiB ring: tinfl checks a distance against the output only when NON_WRAPPING. */
    m->status = tinfl_decompress(&m->inflator, in + *pos, &in_n, m->out, m->out + m->out_end,
                                 &out_n,
                                 TINFL_FLAG_HAS_MORE_INPUT |
                                     TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);
    *pos += in_n;
    m->received += in_n;
    m->crc = (uint32_t)mz_crc32(m->crc, m->out + m->out_end, out_n);
    m->produced += out_n;
    m->out_end += out_n;
    if (m->status == TINFL_STATUS_DONE || m->status < 0 ||
        (m->status == TINFL_STATUS_NEEDS_MORE_INPUT && m->received >= m->trailer_at)) {
        m->inflating = 0;
    }
}

static int verdict(const struct gz_member *m) {
    if (m->refused >= 0) {
        return m->refused;
    }
    uint32_t want_crc = get_le32(m->trailer);
    size_t want_len = get_le32(m->trailer + 4);
    if (m->trailer_at - m->body_at < want_len / DEFLATE_MAX_EXPANSION) {
        return TRAILER_CLAIMS_MORE_THAN_DEFLATE_CAN_HOLD;
    }
    if (m->produced > want_len) {
        return LONGER_THAN_ITS_TRAILER_SAYS;
    }
    if (m->status == TINFL_STATUS_DONE && m->past_deflate != 0) {
        return BYTES_BETWEEN_DEFLATE_AND_TRAILER;
    }
    if (m->status == TINFL_STATUS_DONE && m->produced != want_len) {
        return SHORTER_THAN_ITS_TRAILER_SAYS;
    }
    if (m->status == TINFL_STATUS_DONE && m->crc != want_crc) {
        return CHECKSUM_MISMATCH;
    }
    if (m->status == TINFL_STATUS_DONE) {
        return -1;
    }
    if (m->status == TINFL_STATUS_NEEDS_MORE_INPUT) {
        return TRUNCATED_DEFLATE;
    }
    return CORRUPT_DEFLATE;
}

static enum pulled member_pull(struct gz_member *m, const uint8_t *in, size_t len, size_t *pos,
                               uint8_t *dst, size_t room, size_t *wrote, int to_line_end,
                               int *line_ended, int *why) {
    *wrote = 0;
    *line_ended = 0;
    for (;;) {
        if (m->out_at < m->out_end) {
            if (*wrote == room) {
                return FILLED;
            }
            size_t n = m->out_end - m->out_at;
            if (n > room - *wrote) {
                n = room - *wrote;
            }
            const uint8_t *from = m->out + m->out_at;
            size_t keep = n;
            if (to_line_end) {
                for (size_t i = 0; i < n; i++) {
                    if (from[i] == '\n') {
                        keep = i;
                        *line_ended = 1;
                        break;
                    }
                }
            }
            memcpy(dst + *wrote, from, keep);
            *wrote += keep;
            m->out_at += keep + (size_t)*line_ended;
            if (*line_ended) {
                return FILLED;
            }
            continue;
        }
        take_framing(m, in, len, pos);
        if (m->inflating && m->refused < 0) {
            inflate_some(m, in, len, pos);
            if (m->inflating && m->status == TINFL_STATUS_NEEDS_MORE_INPUT &&
                m->out_at == m->out_end) {
                return NEEDS_INPUT;
            }
            continue;
        }
        if (m->received < m->size) {
            if (*pos == len) {
                return NEEDS_INPUT;
            }
            continue;
        }
        *why = verdict(m);
        return *why < 0 ? ENDED : REFUSED;
    }
}

static lean_obj_res grown(lean_obj_arg dest, size_t want, int to_line_end) {
    size_t have = lean_sarray_size(dest);
    size_t cap = lean_sarray_capacity(dest);
    size_t first = to_line_end ? FIRST_LINE : FIRST_PIECE;
    size_t next = cap < first / 2 ? first : 2 * cap;
    if (!to_line_end && next > want) {
        next = want;
    }
    if (next <= have) {
        next = have + 1;
    }
    lean_obj_res out = lean_alloc_sarray(1, have, next);
    if (have != 0) {
        memcpy(lean_sarray_cptr(out), lean_sarray_cptr(dest), have);
    }
    lean_dec_ref(dest);
    return out;
}

static enum pulled pull_into(struct gz_member *m, const uint8_t *in, size_t len, size_t *pos,
                             lean_obj_res *dest, size_t want, int to_line_end, int *why) {
    for (;;) {
        size_t have = lean_sarray_size(*dest);
        if (!to_line_end && have >= want) {
            return FILLED;
        }
        if (!lean_is_exclusive(*dest)) {
            *dest = grown(*dest, want, to_line_end);
        }
        size_t room = lean_sarray_capacity(*dest) - have;
        if (!to_line_end && room > want - have) {
            room = want - have;
        }
        size_t wrote;
        int line_ended;
        enum pulled p = member_pull(m, in, len, pos, lean_sarray_cptr(*dest) + have, room, &wrote,
                                    to_line_end, &line_ended, why);
        lean_sarray_set_size(*dest, have + wrote);
        if (p != FILLED || line_ended || (!to_line_end && have + wrote == want)) {
            return p;
        }
        if (room == 0) {
            *dest = grown(*dest, want, to_line_end);
        }
    }
}

lean_obj_res litedoc4_gzip_inflate_member(b_lean_obj_arg input) {
    const uint8_t *src = lean_sarray_cptr(input);
    size_t n = lean_sarray_size(input);
    struct gz_member *m = (struct gz_member *)malloc(sizeof *m);
    if (m == NULL) {
        lean_internal_panic_out_of_memory();
    }
    member_init(m, n);
    size_t claimed = n < GZ_HEADER_SIZE + GZ_TRAILER_SIZE ? 0 : get_le32(src + n - 4);
    size_t capacity =
        claimed / DEFLATE_MAX_EXPANSION <= n - GZ_HEADER_SIZE - GZ_TRAILER_SIZE ? claimed : 0;
    lean_obj_res out = lean_alloc_sarray(1, 0, capacity);
    size_t pos = 0;
    int why = TRUNCATED_DEFLATE;
    enum pulled p = pull_into(m, src, n, &pos, &out, SIZE_MAX, 0, &why);
    free(m);
    if (p == ENDED) {
        return accepted(out);
    }
    lean_dec_ref(out);
    return refused(why);
}

static void reader_finalize(void *m) { free(m); }

static void reader_foreach(void *m, b_lean_obj_arg f) {
    (void)m;
    (void)f;
}

static _Atomic(lean_external_class *) reader_class;

static lean_external_class *the_reader_class(void) {
    lean_external_class *known = atomic_load(&reader_class);
    if (known == NULL) {
        lean_external_class *mine = lean_register_external_class(reader_finalize, reader_foreach);
        known = atomic_compare_exchange_strong(&reader_class, &known, mine) ? mine : known;
    }
    return known;
}

lean_obj_res litedoc4_gzip_reader_new(size_t member_bytes) {
    struct gz_member *m = (struct gz_member *)malloc(sizeof *m);
    if (m == NULL) {
        lean_internal_panic_out_of_memory();
    }
    member_init(m, member_bytes);
    return lean_alloc_external(the_reader_class(), m);
}

lean_obj_res litedoc4_gzip_reader_pull(b_lean_obj_arg reader, b_lean_obj_arg input, size_t pos,
                                       lean_obj_arg dest, size_t want, uint8_t to_line_end) {
    struct gz_member *m = (struct gz_member *)lean_get_external_data(reader);
    size_t len = lean_sarray_size(input);
    if (pos > len) {
        pos = len;
    }
    int why = -1;
    enum pulled p =
        pull_into(m, lean_sarray_cptr(input), len, &pos, &dest, want, to_line_end, &why);
    lean_obj_res r = lean_alloc_ctor(0, 3, 0);
    lean_ctor_set(r, 0, dest);
    lean_ctor_set(r, 1, lean_usize_to_nat(pos));
    lean_ctor_set(r, 2, p == REFUSED ? refused(why) : accepted(lean_box((size_t)p)));
    return r;
}

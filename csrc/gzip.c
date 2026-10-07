/* Frames miniz's raw deflate as a gzip member (RFC 1952). miniz is MIT,
 * Copyright 2013-2014 RAD Game Tools and Valve Software and Copyright 2010-2014
 * Rich Geldreich and Tenacious Software LLC; it is `vendor/miniz/miniz.c`,
 * unmodified. See this repository's NOTICE and `vendor/miniz/PROVENANCE.md`.
 */

#include <lean/lean.h>

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

static lean_obj_res refused(enum refusal why) {
    lean_obj_res r = lean_alloc_ctor(0, 1, 0);
    lean_ctor_set(r, 0, lean_box((size_t)why));
    return r;
}

static lean_obj_res accepted(lean_obj_res bytes) {
    lean_obj_res r = lean_alloc_ctor(1, 1, 0);
    lean_ctor_set(r, 0, bytes);
    return r;
}

static size_t skip_zero_terminated(const uint8_t *src, size_t pos, size_t end) {
    while (pos < end && src[pos] != 0) {
        pos++;
    }
    return pos;
}

static int skip_header(const uint8_t *src, size_t trailer_at, size_t *body_at,
                       enum refusal *why) {
    if (src[0] != GZ_ID1 || src[1] != GZ_ID2) {
        *why = NOT_GZIP;
        return 0;
    }
    if (src[2] != GZ_CM_DEFLATE) {
        *why = NOT_DEFLATE;
        return 0;
    }
    uint8_t flg = src[3];
    if (flg & GZ_FRESERVED) {
        *why = RESERVED_FLAG_SET;
        return 0;
    }
    *why = HEADER_RUNS_INTO_TRAILER;
    size_t pos = GZ_HEADER_SIZE;
    if (flg & GZ_FEXTRA) {
        if (trailer_at - pos < 2) {
            return 0;
        }
        size_t xlen = (size_t)src[pos] | ((size_t)src[pos + 1] << 8);
        pos += 2;
        if (trailer_at - pos < xlen) {
            return 0;
        }
        pos += xlen;
    }
    for (uint8_t field = GZ_FNAME; field <= GZ_FCOMMENT; field <<= 1) {
        if (flg & field) {
            pos = skip_zero_terminated(src, pos, trailer_at);
            if (pos == trailer_at) {
                return 0;
            }
            pos++;
        }
    }
    if (flg & GZ_FHCRC) {
        if (trailer_at - pos < 2) {
            return 0;
        }
        uint32_t want = (uint32_t)src[pos] | ((uint32_t)src[pos + 1] << 8);
        if ((crc32_of(src, pos) & 0xffff) != want) {
            *why = HEADER_CHECKSUM_MISMATCH;
            return 0;
        }
        pos += 2;
    }
    *body_at = pos;
    return 1;
}

lean_obj_res litedoc4_gzip_inflate_member(b_lean_obj_arg input) {
    const uint8_t *src = lean_sarray_cptr(input);
    size_t n = lean_sarray_size(input);
    if (n < GZ_HEADER_SIZE + GZ_TRAILER_SIZE) {
        return refused(SHORTER_THAN_A_MEMBER);
    }
    size_t trailer_at = n - GZ_TRAILER_SIZE;
    enum refusal why;
    size_t body_at;
    if (!skip_header(src, trailer_at, &body_at, &why)) {
        return refused(why);
    }
    size_t body_len = trailer_at - body_at;
    uint32_t want_crc = get_le32(src + trailer_at);
    size_t want_len = get_le32(src + trailer_at + 4);
    if (body_len < want_len / DEFLATE_MAX_EXPANSION) {
        return refused(TRAILER_CLAIMS_MORE_THAN_DEFLATE_CAN_HOLD);
    }

    lean_obj_res out = lean_alloc_sarray(1, want_len, want_len);
    uint8_t *dst = lean_sarray_cptr(out);
    tinfl_decompressor inflator;
    tinfl_init(&inflator);
    size_t consumed = body_len;
    size_t produced = want_len;
    tinfl_status status = tinfl_decompress(
        &inflator, src + body_at, &consumed, dst, dst, &produced,
        TINFL_FLAG_HAS_MORE_INPUT | TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);

    if (status == TINFL_STATUS_DONE && consumed != body_len) {
        why = BYTES_BETWEEN_DEFLATE_AND_TRAILER;
    } else if (status == TINFL_STATUS_DONE && produced != want_len) {
        why = SHORTER_THAN_ITS_TRAILER_SAYS;
    } else if (status == TINFL_STATUS_DONE && crc32_of(dst, produced) != want_crc) {
        why = CHECKSUM_MISMATCH;
    } else if (status == TINFL_STATUS_DONE) {
        return accepted(out);
    } else if (status == TINFL_STATUS_NEEDS_MORE_INPUT) {
        why = TRUNCATED_DEFLATE;
    } else if (status == TINFL_STATUS_HAS_MORE_OUTPUT) {
        why = LONGER_THAN_ITS_TRAILER_SAYS;
    } else {
        why = CORRUPT_DEFLATE;
    }
    lean_dec_ref(out);
    return refused(why);
}

extern void mi_collect(_Bool force);
extern void mi_process_info(size_t *elapsed_msecs, size_t *user_msecs, size_t *system_msecs,
                            size_t *current_rss, size_t *peak_rss, size_t *current_commit,
                            size_t *peak_commit, size_t *page_faults);

lean_obj_res litedoc4_exp_mi_collect(lean_obj_arg w) {
    (void)w;
    mi_collect(1);
    return lean_io_result_mk_ok(lean_box(0));
}

lean_obj_res litedoc4_exp_commit(lean_obj_arg w) {
    (void)w;
    size_t a, b, c, rss, prss, commit, pcommit, pf;
    mi_process_info(&a, &b, &c, &rss, &prss, &commit, &pcommit, &pf);
    return lean_io_result_mk_ok(lean_box_usize(commit));
}

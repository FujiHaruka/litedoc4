/* md4c's callback stream, flattened into one byte buffer.
 *
 * WHY A BYTE STREAM AND NOT LEAN OBJECTS
 *   The straightforward wrapper builds the tree in C, calling `@[export]`ed
 *   Lean constructors from the callbacks. That is what MD4Lean does, and it
 *   costs 581 lines of C that has to be right about reference counting in a
 *   place where being wrong is a leak or a double free rather than a wrong
 *   answer. Emitting md4c's events verbatim and rebuilding the tree in Lean
 *   moves every allocation decision to the side that already has a garbage
 *   collector, and leaves this file with no Lean type in it but the one
 *   ByteArray it returns.
 *   The premise that makes it cheap: Markdown is 3.4% of a render
 *   (purelean-markdown-2026-08-30.txt), so one extra copy of the docstrings is
 *   not measurable. If Markdown ever dominates a run, the straightforward
 *   wrapper is worth its 581 lines.
 *
 * THE FORMAT
 *   Lengths and numbers are little-endian u32. `Md.lean` is the only reader.
 *
 *     0x01 <u8 blocktype> <detail: UL, OL, H>          enter_block
 *     0x02 <u8 blocktype> <detail: LI, CODE>           leave_block
 *     0x03 <u8 spantype>                               enter_span
 *     0x04 <u8 spantype>  <detail: A, IMG, WIKILINK>   leave_span
 *     0x05 <u8 texttype> <u32 len> <len bytes>
 *
 *   WHICH END CARRIES THE DETAIL is not a choice. md4c hands a detail to both
 *   ends, and the two are not interchangeable: a list item's task fields and a
 *   code block's info string are the ones given at `leave`, and every span's
 *   are too, while UL / OL / H must be read at `enter` because by `leave` the
 *   detail no longer describes the block that is closing. The Rust half
 *   (`crates/litedoc4-md/src/parse.rs`) settles this the same way, and its
 *   output is the reference these bytes have to reproduce.
 *
 *   An attribute is <u32 count> then count * (<u8 texttype> <u32 len> <bytes>).
 *   An empty buffer means md4c refused the input; a parse that succeeds always
 *   emits at least the document's own enter and leave.
 */

#include <lean/lean.h>

#include <stdlib.h>
#include <string.h>

#include "md4c.h"

#define EV_ENTER_BLOCK 0x01
#define EV_LEAVE_BLOCK 0x02
#define EV_ENTER_SPAN 0x03
#define EV_LEAVE_SPAN 0x04
#define EV_TEXT 0x05

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
    int failed;
} buf_t;

static void buf_reserve(buf_t *b, size_t extra) {
    if (b->failed) {
        return;
    }
    if (b->len + extra <= b->cap) {
        return;
    }
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < b->len + extra) {
        cap *= 2;
    }
    uint8_t *p = (uint8_t *)realloc(b->data, cap);
    if (p == NULL) {
        b->failed = 1;
        return;
    }
    b->data = p;
    b->cap = cap;
}

static void buf_u8(buf_t *b, uint8_t v) {
    buf_reserve(b, 1);
    if (b->failed) {
        return;
    }
    b->data[b->len++] = v;
}

static void buf_u32(buf_t *b, uint32_t v) {
    buf_reserve(b, 4);
    if (b->failed) {
        return;
    }
    b->data[b->len++] = (uint8_t)(v & 0xFFu);
    b->data[b->len++] = (uint8_t)((v >> 8) & 0xFFu);
    b->data[b->len++] = (uint8_t)((v >> 16) & 0xFFu);
    b->data[b->len++] = (uint8_t)((v >> 24) & 0xFFu);
}

static void buf_bytes(buf_t *b, const void *p, size_t n) {
    if (n == 0) {
        return;
    }
    buf_reserve(b, n);
    if (b->failed) {
        return;
    }
    memcpy(b->data + b->len, p, n);
    b->len += n;
}

/* MD_CHAR is `char`, whose signedness belongs to the platform. Take the byte,
 * not the sign — the same reason `mark_char` in the Rust half spells it
 * `to_ne_bytes()[0]` rather than `as u8`. */
static uint8_t md_byte(MD_CHAR c) {
    unsigned char raw;
    memcpy(&raw, &c, 1);
    return raw;
}

static void emit_attr(buf_t *b, const MD_ATTRIBUTE *a) {
    if (a->size == 0 || a->text == NULL || a->substr_offsets == NULL ||
        a->substr_types == NULL) {
        buf_u32(b, 0);
        return;
    }
    uint32_t n = 0;
    while (a->substr_offsets[n] < a->size) {
        n++;
    }
    buf_u32(b, n);
    for (uint32_t i = 0; i < n; i++) {
        MD_OFFSET start = a->substr_offsets[i];
        MD_OFFSET end = a->substr_offsets[i + 1];
        if (end < start || end > a->size) {
            b->failed = 1;
            return;
        }
        buf_u8(b, (uint8_t)a->substr_types[i]);
        buf_u32(b, (uint32_t)(end - start));
        buf_bytes(b, a->text + start, (size_t)(end - start));
    }
}

static int enter_block(MD_BLOCKTYPE type, void *detail, void *userdata) {
    buf_t *b = (buf_t *)userdata;
    buf_u8(b, EV_ENTER_BLOCK);
    buf_u8(b, (uint8_t)type);
    switch (type) {
        case MD_BLOCK_UL: {
            MD_BLOCK_UL_DETAIL *d = (MD_BLOCK_UL_DETAIL *)detail;
            buf_u8(b, d->is_tight ? 1 : 0);
            buf_u8(b, md_byte(d->mark));
            break;
        }
        case MD_BLOCK_OL: {
            MD_BLOCK_OL_DETAIL *d = (MD_BLOCK_OL_DETAIL *)detail;
            buf_u32(b, d->start);
            buf_u8(b, d->is_tight ? 1 : 0);
            buf_u8(b, md_byte(d->mark_delimiter));
            break;
        }
        case MD_BLOCK_H: {
            MD_BLOCK_H_DETAIL *d = (MD_BLOCK_H_DETAIL *)detail;
            buf_u32(b, d->level);
            break;
        }
        default:
            break;
    }
    return b->failed;
}

static int leave_block(MD_BLOCKTYPE type, void *detail, void *userdata) {
    buf_t *b = (buf_t *)userdata;
    buf_u8(b, EV_LEAVE_BLOCK);
    buf_u8(b, (uint8_t)type);
    switch (type) {
        case MD_BLOCK_LI: {
            MD_BLOCK_LI_DETAIL *d = (MD_BLOCK_LI_DETAIL *)detail;
            buf_u8(b, d->is_task ? 1 : 0);
            buf_u8(b, d->is_task ? md_byte(d->task_mark) : 0);
            buf_u32(b, d->is_task ? d->task_mark_offset : 0);
            break;
        }
        case MD_BLOCK_CODE: {
            MD_BLOCK_CODE_DETAIL *d = (MD_BLOCK_CODE_DETAIL *)detail;
            emit_attr(b, &d->info);
            emit_attr(b, &d->lang);
            buf_u8(b, md_byte(d->fence_char));
            break;
        }
        default:
            break;
    }
    return b->failed;
}

static int enter_span(MD_SPANTYPE type, void *detail, void *userdata) {
    buf_t *b = (buf_t *)userdata;
    (void)detail;
    buf_u8(b, EV_ENTER_SPAN);
    buf_u8(b, (uint8_t)type);
    return b->failed;
}

static int leave_span(MD_SPANTYPE type, void *detail, void *userdata) {
    buf_t *b = (buf_t *)userdata;
    buf_u8(b, EV_LEAVE_SPAN);
    buf_u8(b, (uint8_t)type);
    switch (type) {
        case MD_SPAN_A: {
            MD_SPAN_A_DETAIL *d = (MD_SPAN_A_DETAIL *)detail;
            emit_attr(b, &d->href);
            emit_attr(b, &d->title);
            buf_u8(b, d->is_autolink ? 1 : 0);
            break;
        }
        case MD_SPAN_IMG: {
            MD_SPAN_IMG_DETAIL *d = (MD_SPAN_IMG_DETAIL *)detail;
            emit_attr(b, &d->src);
            emit_attr(b, &d->title);
            break;
        }
        case MD_SPAN_WIKILINK: {
            MD_SPAN_WIKILINK_DETAIL *d = (MD_SPAN_WIKILINK_DETAIL *)detail;
            emit_attr(b, &d->target);
            break;
        }
        default:
            break;
    }
    return b->failed;
}

static int on_text(MD_TEXTTYPE type, const MD_CHAR *text, MD_SIZE size,
                   void *userdata) {
    buf_t *b = (buf_t *)userdata;
    buf_u8(b, EV_TEXT);
    buf_u8(b, (uint8_t)type);
    buf_u32(b, (uint32_t)size);
    buf_bytes(b, text, (size_t)size);
    return b->failed;
}

lean_obj_res litedoc4_md_events(b_lean_obj_arg input, uint32_t flags) {
    buf_t b = {NULL, 0, 0, 0};

    MD_PARSER parser;
    memset(&parser, 0, sizeof(parser));
    parser.abi_version = 0;
    parser.flags = flags;
    parser.enter_block = enter_block;
    parser.leave_block = leave_block;
    parser.enter_span = enter_span;
    parser.leave_span = leave_span;
    parser.text = on_text;

    /* `lean_string_size` counts the NUL terminator Lean keeps; md4c wants the
     * bytes without it. */
    size_t size = lean_string_size(input) - 1;
    int code = md_parse(lean_string_cstr(input), (MD_SIZE)size, &parser, &b);

    if (code != 0 || b.failed) {
        free(b.data);
        return lean_alloc_sarray(1, 0, 0);
    }

    lean_obj_res out = lean_alloc_sarray(1, b.len, b.len);
    if (b.len != 0) {
        memcpy(lean_sarray_cptr(out), b.data, b.len);
    }
    free(b.data);
    return out;
}

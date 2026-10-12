/* Stand-ins for the Lean runtime functions `csrc/md_events.c` and
 * `csrc/gzip.c` call, so that `tools/md-memory-gate.sh` and
 * `tools/gzip-memory-gate.sh` can build and run those files with no Lean
 * toolchain anywhere on the machine. `csrc/memcheck/harness.c` implements the
 * four `md_events.c` calls and `csrc/memcheck/gzip_harness.c` all of them.
 *
 * WHY NOT THE REAL `lean/lean.h`
 *   Not availability — an elan toolchain has one, and two CI jobs already
 *   install elan. The reason is what linking the real runtime would do to the
 *   answer: every allocation Lean's own allocator makes would stand in front of
 *   LeakSanitizer, and a report would then be about Lean rather than about md4c.
 *   With these stand-ins the only allocations in the process are the C under
 *   test's and its harness's, so a leak report has one possible author. What
 *   would falsify it: a defect that only appears against Lean's allocator.
 *   Neither file calls any other part of the runtime, and neither keeps a Lean
 *   object past the call that was handed it, so there is nowhere for one to sit.
 *
 * The payload of each object is a separate exact-sized allocation, which is
 * *stricter* than the runtime being stood in for: Lean lays a string's bytes
 * out after an inline header and rounds the whole object up to an allocator
 * size class, so a one-byte overrun lands in slack and nothing sees it. Here it
 * lands in a sanitizer redzone.
 */
#ifndef LITEDOC4_MEMCHECK_LEAN_H
#define LITEDOC4_MEMCHECK_LEAN_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct lean_object lean_object;
typedef lean_object *lean_obj_res;
typedef lean_object *lean_obj_arg;
typedef lean_object *b_lean_obj_arg;

typedef void (*lean_external_finalize_proc)(void *);
typedef void (*lean_external_foreach_proc)(void *, b_lean_obj_arg);

typedef struct {
    lean_external_finalize_proc m_finalize;
    lean_external_foreach_proc m_foreach;
} lean_external_class;

size_t lean_string_size(b_lean_obj_arg s);
char const *lean_string_cstr(b_lean_obj_arg s);
lean_obj_res lean_alloc_sarray(unsigned elem_size, size_t size, size_t capacity);
uint8_t *lean_sarray_cptr(lean_object *o);

size_t lean_sarray_size(b_lean_obj_arg o);
size_t lean_sarray_capacity(lean_object *o);
void lean_sarray_set_size(lean_obj_arg o, size_t size);
bool lean_is_exclusive(lean_object *o);
void lean_dec_ref(lean_object *o);
lean_obj_res lean_box(size_t n);
lean_obj_res lean_usize_to_nat(size_t n);
lean_obj_res lean_alloc_ctor(unsigned tag, unsigned num_objs, unsigned scalar_sz);
void lean_ctor_set(b_lean_obj_arg o, unsigned i, lean_obj_arg v);
lean_external_class *lean_register_external_class(lean_external_finalize_proc finalize,
                                                  lean_external_foreach_proc foreach);
lean_obj_res lean_alloc_external(lean_external_class *cls, void *data);
void *lean_get_external_data(lean_object *o);
_Noreturn void lean_internal_panic_out_of_memory(void);

#endif

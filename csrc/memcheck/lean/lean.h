/* Stand-ins for the four Lean runtime functions `csrc/md_events.c` calls, so
 * that `tools/md-memory-gate.sh` can build and run that file with no Lean
 * toolchain anywhere on the machine. `csrc/memcheck/harness.c` implements them.
 *
 * WHY NOT THE REAL `lean/lean.h`
 *   Not availability — an elan toolchain has one, and two CI jobs already
 *   install elan. The reason is what linking the real runtime would do to the
 *   answer: every allocation Lean's own allocator makes would stand in front of
 *   LeakSanitizer, and a report would then be about Lean rather than about md4c.
 *   With these stand-ins the only allocations in the process are md4c's,
 *   `md_events.c`'s and this harness's, so a leak report has one possible
 *   author. What would falsify it: a defect that only appears against Lean's
 *   allocator. `md_events.c` calls no other part of the runtime and holds no
 *   Lean object across a call, so there is nowhere for one to sit.
 *
 * The payload of each object is a separate exact-sized allocation, which is
 * *stricter* than the runtime being stood in for: Lean lays a string's bytes
 * out after an inline header and rounds the whole object up to an allocator
 * size class, so a one-byte overrun lands in slack and nothing sees it. Here it
 * lands in a sanitizer redzone.
 */
#ifndef LITEDOC4_MEMCHECK_LEAN_H
#define LITEDOC4_MEMCHECK_LEAN_H

#include <stddef.h>
#include <stdint.h>

typedef struct lean_object lean_object;
typedef lean_object *lean_obj_res;
typedef lean_object *b_lean_obj_arg;

size_t lean_string_size(b_lean_obj_arg s);
char const *lean_string_cstr(b_lean_obj_arg s);
lean_obj_res lean_alloc_sarray(unsigned elem_size, size_t size, size_t capacity);
uint8_t *lean_sarray_cptr(lean_object *o);

#endif

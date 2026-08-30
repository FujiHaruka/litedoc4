/* Does `csrc/libc` agree with the platform's real libc?
 *
 * WHY THE 422-PAGE COMPARISON IS NOT THIS CHECK
 *   It was tried and it does not work. Swapping `memset`'s second and third
 *   parameters — `(void*, size_t, int)` for `(void*, int, size_t)` — compiles,
 *   renders, and produces all 422 pages byte-identical, because the call sites
 *   pass 0 and the length in the same two registers either way
 *   (measured 2026-08-30 on arm64 macOS). A declaration can be wrong in a way
 *   no output reveals, so the output cannot be what guards it.
 *
 * WHAT THIS DOES INSTEAD
 *   Includes the real headers and then ours. Two declarations of the same
 *   function that disagree are a compile error naming that function, which is
 *   the compiler doing the comparison rather than a person. It needs the
 *   system compiler and its real headers, so it is a gate, not a build step:
 *   nothing in the package's own build reaches it.
 *
 *   Reversing the include order would work equally well; keeping the real ones
 *   first means the error message quotes ours as the redeclaration.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libc/stdio.h"
#include "libc/stdlib.h"
#include "libc/string.h"

int main(void) { return 0; }

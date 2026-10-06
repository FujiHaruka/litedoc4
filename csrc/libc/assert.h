/* See README.md in this directory. miniz includes <assert.h> unconditionally
and checks its own invariants with it; a broken one aborts, as the platform's
assert does when NDEBUG is not set. No include guard and an #undef, as the
platform's header has: `lean/lean.h` defines an `assert` of its own. */
#include <stdlib.h>

#undef assert
#ifdef NDEBUG
#define assert(e) ((void)0)
#else
#define assert(e) ((e) ? (void)0 : abort())
#endif

/* See README.md in this directory. Declares only what is called. */
#ifndef LITEDOC4_SHIM_STDLIB_H
#define LITEDOC4_SHIM_STDLIB_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *malloc(size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);
void qsort(void *base, size_t nmemb, size_t size,
           int (*compar)(const void *, const void *));
void *bsearch(const void *key, const void *base, size_t nmemb, size_t size,
              int (*compar)(const void *, const void *));

#ifdef __cplusplus
}
#endif

#endif

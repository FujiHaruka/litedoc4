/* See README.md in this directory. Declares only what is called. */
#ifndef LITEDOC4_SHIM_STRING_H
#define LITEDOC4_SHIM_STRING_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *memcpy(void *dest, const void *src, size_t n);
void *memmove(void *dest, const void *src, size_t n);
void *memset(void *s, int c, size_t n);
int memcmp(const void *s1, const void *s2, size_t n);
char *strchr(const char *s, int c);

#ifdef __cplusplus
}
#endif

#endif

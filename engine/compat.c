/* The iPhoneOS9.3 SDK stubs don't export strchr for armv7 (it lives in libsystem_platform as
   _platform_strchr); iOS 5's libSystem has it, but the linker can't see it, so supply one. */
#include <stddef.h>
char *strchr(const char *s, int c) {
    for (;; s++) { if (*s == (char)c) return (char *)s; if (!*s) return NULL; }
}

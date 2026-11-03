/* Fuzz ini_parse_string(). Used for the default-config target (inihfuzz, the OSS-Fuzz harness name)
   and, compiled with extra -DINI_* flags, for the heap/realloc/lineno/no-value variant target. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "ini.h"

static int User;
static char Prev_section[50];

#if INI_HANDLER_LINENO
static int dumper(void* user, const char* section, const char* name,
                  const char* value, int lineno)
#else
static int dumper(void* user, const char* section, const char* name,
                  const char* value)
#endif
{
    User = *((int*)user);
    if (strcmp(section, Prev_section)) {
        strncpy(Prev_section, section, sizeof(Prev_section));
        Prev_section[sizeof(Prev_section) - 1] = '\0';
    }
    if (name && value && strcmp(name, "user") == 0 && strcmp(value, "parse_error") == 0)
        return 0;
#if INI_HANDLER_LINENO
    (void)lineno;
#endif
    return 1;
}

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    static int u = 100;
    char* buf;

    if (size == 0)
        return -1;
    buf = (char*)calloc(size + 1, 1);
    if (!buf)
        return -1;
    memcpy(buf, data, size);
    Prev_section[0] = '\0';
    ini_parse_string(buf, dumper, &u);
    free(buf);
    return 0;
}

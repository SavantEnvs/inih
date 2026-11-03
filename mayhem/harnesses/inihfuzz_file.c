/* Port of the in-tree fuzzing/inihfuzz.c (file-input AFL driver): same handler, but the bytes come
   from the fuzzer and are exposed to ini_parse_file() through an in-memory FILE*, so the stream
   (fgets-based) reader path is fuzzed without any file I/O. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ini.h"

static int User;
static char Prev_section[50];

static int dumper(void* user, const char* section, const char* name,
                  const char* value)
{
    User = *((int*)user);
    if (!name || strcmp(section, Prev_section)) {
        strncpy(Prev_section, section, sizeof(Prev_section));
        Prev_section[sizeof(Prev_section) - 1] = '\0';
    }
    if (!name || !value)
        return 1;
    return strcmp(name, "user") == 0 && strcmp(value, "parse_error") == 0 ? 0 : 1;
}

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    static int u = 100;
    FILE* f;

    if (size == 0)
        return -1;
    f = fmemopen((void*)data, size, "r");
    if (!f)
        return -1;
    Prev_section[0] = '\0';
    ini_parse_file(f, dumper, &u);
    u++;
    fclose(f);
    return 0;
}

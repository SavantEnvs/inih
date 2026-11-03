/* Fuzz the C++ INIReader wrapper: parse a buffer, then exercise every accessor. */
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>
#include "INIReader.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    if (size == 0)
        return -1;
    INIReader reader(reinterpret_cast<const char*>(data), size);
    (void)reader.ParseError();
    (void)reader.ParseErrorMessage();
    std::vector<std::string> sections = reader.Sections();
    for (size_t i = 0; i < sections.size(); i++) {
        std::vector<std::string> keys = reader.Keys(sections[i]);
        for (size_t j = 0; j < keys.size(); j++) {
            const std::string& s = sections[i];
            const std::string& k = keys[j];
            (void)reader.HasValue(s, k);
            (void)reader.Get(s, k, "");
            (void)reader.GetString(s, k, "d");
            (void)reader.GetInteger(s, k, 0);
            (void)reader.GetInteger64(s, k, 0);
            (void)reader.GetUnsigned(s, k, 0);
            (void)reader.GetUnsigned64(s, k, 0);
            (void)reader.GetReal(s, k, 0.0);
            (void)reader.GetBoolean(s, k, false);
        }
        (void)reader.HasSection(sections[i]);
    }
    return 0;
}

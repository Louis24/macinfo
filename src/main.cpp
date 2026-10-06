// macinfo -- command line build: prints the info collected by src/sysinfo.cpp.

#include "sysinfo.h"

#include <cstdio>

int main()
{
#if defined(__APPLE__)
    std::printf("Hello from macOS!\n\n");
#else
    std::printf("(non-Apple host: local sanity check only)\n\n");
#endif
    std::printf("%s", macinfo::report().c_str());
    return 0;
}

#include "sysinfo.h"

#include <cstdio>
#include <vector>

#if defined(__APPLE__)
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <unistd.h>
#endif

namespace macinfo {

std::string cpuBrand()
{
#if defined(__APPLE__)
    char buf[256] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname("machdep.cpu.brand_string", &buf, &len, nullptr, 0) == 0)
        return std::string(buf);
    return "unknown";
#else
    return "non-apple host";
#endif
}

int cpuCores()
{
#if defined(__APPLE__)
    int n = 0;
    size_t len = sizeof(n);
    if (sysctlbyname("hw.physicalcpu", &n, &len, nullptr, 0) == 0)
        return n;
    return 1;
#else
    return 1;
#endif
}

std::string osVersion()
{
#if defined(__APPLE__)
    char buf[128] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname("kern.osproductversion", &buf, &len, nullptr, 0) == 0)
        return std::string(buf);
    return "unknown";
#else
    return "unknown";
#endif
}

std::string compilerFlavour()
{
#if defined(__apple_build_version__)
    return std::string("Apple clang ") + __clang_version__;
#elif defined(__clang__)
    return std::string("clang ") + __clang_version__;
#elif defined(__GNUC__)
    return std::string("gcc ") + __VERSION__;
#else
    return "unknown";
#endif
}

std::string archName()
{
#if defined(__APPLE__)
    struct utsname u;
    std::string machine = (uname(&u) == 0) ? std::string(u.machine) : std::string("unknown");

    int translated = 0;
    size_t len = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &len, nullptr, 0) == 0 && translated)
        machine += " (running under Rosetta 2)";
    return machine;
#else
#if defined(__x86_64__)
    return "x86_64";
#elif defined(__aarch64__)
    return "aarch64";
#else
    return "unknown";
#endif
#endif
}

std::string report()
{
    std::string out;
    out += "cpu        : " + cpuBrand() + "\n";
    out += "cores      : " + std::to_string(cpuCores()) + "\n";
    out += "macos      : " + osVersion() + "\n";
    out += "compiler   : " + compilerFlavour() + "\n";
    out += "arch       : " + archName() + "\n";

    std::vector<int> fib(20, 0);
    fib[1] = 1;
    for (size_t i = 2; i < fib.size(); ++i)
        fib[i] = fib[i - 1] + fib[i - 2];

    out += "\nfibonacci  :";
    for (int v : fib)
        out += " " + std::to_string(v);
    out += "\n";
    return out;
}

}  // namespace macinfo

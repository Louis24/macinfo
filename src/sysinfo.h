// System info collected through Apple's sysctl MIBs. Shared by the CLI and the .app GUI.
#pragma once

#include <string>

namespace macinfo {

std::string cpuBrand();
int cpuCores();
std::string osVersion();
std::string compilerFlavour();
std::string archName();

// Multi-line human readable report, used by both targets.
std::string report();

}  // namespace macinfo

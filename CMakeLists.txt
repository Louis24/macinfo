cmake_minimum_required(VERSION 3.20)

project(macinfo
        VERSION 1.0.0
        DESCRIPTION "Print info about the Mac this binary was built on"
        LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# -DUNIVERSAL=ON produces an arm64 + x86_64 fat binary (macOS only, needs both SDK slices).
option(UNIVERSAL "Build a universal (arm64 + x86_64) binary on macOS" OFF)
if(APPLE AND UNIVERSAL)
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "" FORCE)
endif()

option(BUILD_MAC_APP "Build the MacInfo.app GUI bundle (macOS only)" ON)

set(warnings $<$<OR:$<CXX_COMPILER_ID:AppleClang>,$<CXX_COMPILER_ID:Clang>,$<CXX_COMPILER_ID:GNU>>:-Wall -Wextra>)

# ---------------------------------------------------------------- CLI target
add_executable(macinfo src/main.cpp src/sysinfo.cpp)
target_compile_options(macinfo PRIVATE ${warnings})

install(TARGETS macinfo RUNTIME DESTINATION bin)

# ------------------------------------------------------------- .app target
if(APPLE AND BUILD_MAC_APP)
    enable_language(OBJCXX)
    set(CMAKE_OBJCXX_STANDARD 17)

    # Target is named MacInfoApp, not MacInfo: APFS is case-insensitive, so a
    # "MacInfo" target would collide with the "macinfo" target inside CMakeFiles
    # (macinfo.dir vs MacInfo.dir) and break make. The output is still MacInfo.app.
    add_executable(MacInfoApp MACOSX_BUNDLE src/gui_mac.mm src/sysinfo.cpp)
    set_target_properties(MacInfoApp PROPERTIES OUTPUT_NAME "MacInfo")
    target_compile_options(MacInfoApp PRIVATE ${warnings} -fobjc-arc)
    target_link_libraries(MacInfoApp PRIVATE "-framework AppKit")

    set_target_properties(MacInfoApp PROPERTIES
            MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/resources/Info.plist.in"
            MACOSX_BUNDLE_BUNDLE_NAME "MacInfo"
            MACOSX_BUNDLE_GUI_IDENTIFIER "com.louis24.macinfo"
            MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
            MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION}")

    install(TARGETS MacInfoApp BUNDLE DESTINATION .)
endif()

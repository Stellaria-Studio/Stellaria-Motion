cmake_minimum_required(VERSION 3.27)

project(StellariaMotion
    VERSION 0.1.0
    LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(STELLARIA_MOTION_BUILD_APP "Build the macOS host app shell" ON)
option(STELLARIA_MOTION_BUILD_TESTS "Build unit tests" ON)
set(STELLARIA_SP4_SDK_DIR "" CACHE PATH "Stellaria SP4 SDK checkout")

if(NOT STELLARIA_SP4_SDK_DIR AND DEFINED ENV{STELLARIA_SP4_SDK_DIR})
    set(STELLARIA_SP4_SDK_DIR "$ENV{STELLARIA_SP4_SDK_DIR}" CACHE PATH "Stellaria SP4 SDK checkout" FORCE)
endif()

if(NOT STELLARIA_SP4_SDK_DIR)
    set(_STELLARIA_SP4_SIBLING_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../Stellaria-SP4")
    if(EXISTS "${_STELLARIA_SP4_SIBLING_DIR}/CMakeLists.txt")
        set(STELLARIA_SP4_SDK_DIR "${_STELLARIA_SP4_SIBLING_DIR}" CACHE PATH "Stellaria SP4 SDK checkout" FORCE)
    endif()
endif()

if(STELLARIA_SP4_SDK_DIR AND EXISTS "${STELLARIA_SP4_SDK_DIR}/CMakeLists.txt")
    set(SP4_BUILD_TOOLS OFF CACHE BOOL "Build SP4 SDK command line tools" FORCE)
    add_subdirectory("${STELLARIA_SP4_SDK_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/StellariaSP4SDK" EXCLUDE_FROM_ALL)
endif()

add_library(MotionCore
    Sources/Core/BrowserProtocol.cpp
    Sources/Core/MotionProfiler.cpp
    Sources/Core/MotionQuality.cpp
    Sources/Core/RealtimeVFISession.cpp
    Sources/Core/RenderGraph.cpp
    Sources/VFI/MotionVFIPipeline.cpp
    Sources/VFI/RIFEModelBackend.cpp)

target_include_directories(MotionCore
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/Sources)

target_compile_features(MotionCore PUBLIC cxx_std_20)

target_compile_options(MotionCore PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Werror)

add_executable(StellariaMotionNativeHost
    Sources/BrowserAgent/native_host/NativeHost.cpp)
target_link_libraries(StellariaMotionNativeHost PRIVATE MotionCore)

if(APPLE)
    set(MOTION_KERNELS_SOURCE ${CMAKE_CURRENT_SOURCE_DIR}/Sources/Metal/MotionKernels.metal)
    set(MOTION_KERNELS_AIR ${CMAKE_CURRENT_BINARY_DIR}/MotionKernels.air)
    set(MOTION_KERNELS_METALLIB ${CMAKE_CURRENT_BINARY_DIR}/MotionKernels.metallib)

    add_custom_command(
        OUTPUT ${MOTION_KERNELS_AIR}
        COMMAND xcrun -sdk macosx metal -c ${MOTION_KERNELS_SOURCE} -o ${MOTION_KERNELS_AIR}
        DEPENDS ${MOTION_KERNELS_SOURCE}
        COMMENT "Compiling Motion Metal kernels"
        VERBATIM)

    add_custom_command(
        OUTPUT ${MOTION_KERNELS_METALLIB}
        COMMAND xcrun -sdk macosx metallib ${MOTION_KERNELS_AIR} -o ${MOTION_KERNELS_METALLIB}
        DEPENDS ${MOTION_KERNELS_AIR}
        COMMENT "Linking Motion Metal shader library"
        VERBATIM)

    add_custom_target(MotionMetalShaders ALL
        DEPENDS ${MOTION_KERNELS_METALLIB})

    add_library(MotionMetal
        Sources/Metal/MotionMetalRuntime.mm)
    target_include_directories(MotionMetal PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/Sources)
    target_link_libraries(MotionMetal
        PUBLIC MotionCore
        PRIVATE
            "-framework Metal"
            "-framework QuartzCore"
            "-framework CoreVideo"
            "-framework IOSurface")
    target_compile_options(MotionMetal PRIVATE -fobjc-arc -Wall -Wextra -Werror)
    add_dependencies(MotionMetal MotionMetalShaders)

    add_library(MotionRIFEApple
        Sources/VFI/RIFECoreMLRunner.mm
        Sources/VFI/RIFEMetal4BitRunner.mm
        Sources/VFI/RIFESP4Runner.mm
        Sources/VFI/RIFEMPSGraphRunner.mm)
    target_include_directories(MotionRIFEApple PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/Sources)
    if(TARGET sp4sdk)
        target_include_directories(MotionRIFEApple PRIVATE "${STELLARIA_SP4_SDK_DIR}/sdk/include")
        target_compile_definitions(MotionRIFEApple PRIVATE
            STELLARIA_SP4_SDK_DIR="${STELLARIA_SP4_SDK_DIR}"
            STELLARIA_SP4_DEFAULT_ASSET="${STELLARIA_SP4_SDK_DIR}/build/rife_sp4_a1p.sp4")
    endif()
    target_link_libraries(MotionRIFEApple
        PUBLIC MotionCore
        PRIVATE
            $<$<TARGET_EXISTS:sp4sdk>:sp4sdk>
            "-framework Foundation"
            "-framework CoreML"
            "-framework Metal"
            "-framework MetalPerformanceShadersGraph"
            "-framework QuartzCore")
    target_compile_options(MotionRIFEApple PRIVATE -fobjc-arc -Wall -Wextra -Werror)

    add_library(MotionVideo
        Sources/Video/MotionOfflineProcessor.mm
        Sources/Video/MotionOnlineProcessor.mm
        Sources/Video/MotionVideoSource.mm)
    target_include_directories(MotionVideo PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/Sources)
    target_link_libraries(MotionVideo
        PUBLIC MotionCore MotionMetal MotionRIFEApple
        PRIVATE
            "-framework AVFoundation"
            "-framework CoreGraphics"
            "-framework CoreImage"
            "-framework Metal"
            "-framework VideoToolbox"
            "-framework ScreenCaptureKit"
            "-framework CoreMedia"
            "-framework CoreVideo")
    target_compile_options(MotionVideo PRIVATE -fobjc-arc -Wall -Wextra -Werror)

    if(STELLARIA_MOTION_BUILD_APP)
        add_executable(StellariaMotionApp MACOSX_BUNDLE
            Sources/App/main.mm
            Sources/BrowserAgent/stream_bridge/BrowserStreamBridge.mm)
        set_target_properties(StellariaMotionApp PROPERTIES
            MACOSX_BUNDLE_BUNDLE_NAME "Stellaria Motion"
            MACOSX_BUNDLE_GUI_IDENTIFIER "studio.stellaria.motion"
            MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Sources/App/Info.plist)
        target_link_libraries(StellariaMotionApp
            PRIVATE MotionCore MotionMetal MotionVideo MotionRIFEApple
                "-framework AppKit"
                "-framework AVKit"
                "-framework CoreImage"
                "-framework CoreMedia"
                "-framework CoreVideo"
                "-framework ImageIO"
                "-framework Metal"
                "-framework QuartzCore"
                "-framework SwiftUI"
                "-framework UniformTypeIdentifiers"
                "-framework VideoToolbox")
        target_compile_options(StellariaMotionApp PRIVATE -fobjc-arc -Wall -Wextra -Werror)
        add_dependencies(StellariaMotionApp MotionMetalShaders StellariaMotionNativeHost)
        if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/Models/RIFE-safetensors/flownet.safetensors")
            add_custom_command(TARGET StellariaMotionApp POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E make_directory
                    "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/Models/RIFE-safetensors"
                COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    "${CMAKE_CURRENT_SOURCE_DIR}/Models/RIFE-safetensors/flownet.safetensors"
                    "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/Models/RIFE-safetensors/flownet.safetensors"
                COMMENT "Bundling RIFE model assets")
        endif()
        if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/Models/RIFE-SP4/rife_sp4_a1p.sp4")
            set(STELLARIA_MOTION_SP4_ASSET "${CMAKE_CURRENT_SOURCE_DIR}/Models/RIFE-SP4/rife_sp4_a1p.sp4")
        elseif(STELLARIA_SP4_SDK_DIR AND EXISTS "${STELLARIA_SP4_SDK_DIR}/build/rife_sp4_a1p.sp4")
            set(STELLARIA_MOTION_SP4_ASSET "${STELLARIA_SP4_SDK_DIR}/build/rife_sp4_a1p.sp4")
        endif()
        if(DEFINED STELLARIA_MOTION_SP4_ASSET)
            add_custom_command(TARGET StellariaMotionApp POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E make_directory
                    "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/Models/RIFE-SP4"
                COMMAND ${CMAKE_COMMAND} -E copy_if_different
                    "${STELLARIA_MOTION_SP4_ASSET}"
                    "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/Models/RIFE-SP4/rife_sp4_a1p.sp4"
                COMMENT "Bundling Stellaria SP4 RIFE asset")
        endif()
        if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/Models/RIFE-CoreML/conv_trunk")
            add_custom_command(TARGET StellariaMotionApp POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E make_directory
                    "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/Models/RIFE-CoreML"
                COMMAND ${CMAKE_COMMAND} -E copy_directory
                    "${CMAKE_CURRENT_SOURCE_DIR}/Models/RIFE-CoreML/conv_trunk"
                    "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/Models/RIFE-CoreML/conv_trunk"
                COMMENT "Bundling RIFE CoreML conv trunk assets")
        endif()
        if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/Models/RIFE-CoreML/continuous_trunk")
            add_custom_command(TARGET StellariaMotionApp POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E make_directory
                    "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/Models/RIFE-CoreML"
                COMMAND ${CMAKE_COMMAND} -E copy_directory
                    "${CMAKE_CURRENT_SOURCE_DIR}/Models/RIFE-CoreML/continuous_trunk"
                    "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/Models/RIFE-CoreML/continuous_trunk"
                COMMENT "Bundling RIFE CoreML continuous trunk assets")
        endif()
        add_custom_command(TARGET StellariaMotionApp POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E make_directory
                "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources"
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                ${MOTION_KERNELS_METALLIB}
                "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/MotionKernels.metallib"
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${CMAKE_CURRENT_SOURCE_DIR}/Sources/App/Resources/StellariaMotion.icns"
                "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/StellariaMotion.icns"
            COMMAND ${CMAKE_COMMAND} -E rm -rf
                "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/tools"
            COMMAND ${CMAKE_COMMAND} -E make_directory
                "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/tools"
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${CMAKE_CURRENT_SOURCE_DIR}/tools/bilibili_cache_client.py"
                "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/Resources/tools/bilibili_cache_client.py"
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "$<TARGET_FILE:StellariaMotionNativeHost>"
                "$<TARGET_BUNDLE_DIR:StellariaMotionApp>/Contents/MacOS/StellariaMotionNativeHost"
            COMMENT "Bundling Motion shaders and Chrome native host")
    endif()
endif()

if(STELLARIA_MOTION_BUILD_TESTS)
    enable_testing()
    add_executable(MotionCoreTests
        Tests/MotionCoreTests.cpp)
    target_link_libraries(MotionCoreTests PRIVATE MotionCore)
    add_test(NAME MotionCoreTests COMMAND MotionCoreTests)

    add_executable(RealtimeVFIPacingSmoke
        Tests/RealtimeVFIPacingSmoke.cpp)
    target_link_libraries(RealtimeVFIPacingSmoke PRIVATE MotionCore)
    add_test(NAME RealtimeVFIPacingSmoke COMMAND RealtimeVFIPacingSmoke)

    if(APPLE)
        add_executable(MotionOfflineProcessorSmoke
            Tests/MotionOfflineProcessorSmoke.mm)
        target_include_directories(MotionOfflineProcessorSmoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/Sources)
        target_link_libraries(MotionOfflineProcessorSmoke
            PRIVATE MotionVideo
                "-framework Foundation"
                "-framework AVFoundation"
                "-framework CoreGraphics"
                "-framework CoreVideo")
        target_compile_options(MotionOfflineProcessorSmoke PRIVATE -fobjc-arc -Wall -Wextra -Werror)
        add_test(NAME MotionOfflineProcessorSmoke COMMAND MotionOfflineProcessorSmoke)

        add_executable(LocalPlayerVideoOutputSmoke
            Tests/LocalPlayerVideoOutputSmoke.mm)
        target_include_directories(LocalPlayerVideoOutputSmoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/Sources)
        target_link_libraries(LocalPlayerVideoOutputSmoke
            PRIVATE MotionVideo
                "-framework Foundation"
                "-framework AVFoundation"
                "-framework CoreVideo")
        target_compile_options(LocalPlayerVideoOutputSmoke PRIVATE -fobjc-arc -Wall -Wextra -Werror)
        add_test(NAME LocalPlayerVideoOutputSmoke COMMAND LocalPlayerVideoOutputSmoke)

        add_executable(RIFEMPSGraphSmoke
            Tests/RIFEMPSGraphSmoke.mm)
        target_include_directories(RIFEMPSGraphSmoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/Sources)
        target_link_libraries(RIFEMPSGraphSmoke
            PRIVATE MotionRIFEApple
                "-framework Foundation"
                "-framework Metal"
                "-framework MetalPerformanceShadersGraph")
        target_compile_options(RIFEMPSGraphSmoke PRIVATE -fobjc-arc -Wall -Wextra -Werror)
        add_test(NAME RIFEMPSGraphSmoke COMMAND RIFEMPSGraphSmoke)

        add_executable(RIFEMPSGraphPerfSmoke
            Tests/RIFEMPSGraphPerfSmoke.mm)
        target_include_directories(RIFEMPSGraphPerfSmoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/Sources)
        target_link_libraries(RIFEMPSGraphPerfSmoke
            PRIVATE MotionRIFEApple
                "-framework Foundation"
                "-framework Metal"
                "-framework MetalPerformanceShadersGraph")
        target_compile_options(RIFEMPSGraphPerfSmoke PRIVATE -fobjc-arc -Wall -Wextra -Werror)
        add_test(NAME RIFEMPSGraphPerfSmoke COMMAND RIFEMPSGraphPerfSmoke)

        add_executable(RIFEMetal4BitSmoke
            Tests/RIFEMetal4BitSmoke.mm)
        target_include_directories(RIFEMetal4BitSmoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/Sources)
        target_link_libraries(RIFEMetal4BitSmoke
            PRIVATE MotionRIFEApple
                "-framework Foundation"
                "-framework Metal")
        target_compile_options(RIFEMetal4BitSmoke PRIVATE -fobjc-arc -Wall -Wextra -Werror)
        add_dependencies(RIFEMetal4BitSmoke MotionMetalShaders)
        add_test(NAME RIFEMetal4BitSmoke COMMAND RIFEMetal4BitSmoke)

        add_executable(RIFEMetal4BitPerfSmoke
            Tests/RIFEMetal4BitPerfSmoke.mm)
        target_include_directories(RIFEMetal4BitPerfSmoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/Sources)
        target_link_libraries(RIFEMetal4BitPerfSmoke
            PRIVATE MotionRIFEApple
                "-framework Foundation"
                "-framework Metal")
        target_compile_options(RIFEMetal4BitPerfSmoke PRIVATE -fobjc-arc -Wall -Wextra -Werror)
        add_dependencies(RIFEMetal4BitPerfSmoke MotionMetalShaders)
        add_test(NAME RIFEMetal4BitPerfSmoke COMMAND RIFEMetal4BitPerfSmoke)

        add_executable(RIFESP4Smoke
            Tests/RIFESP4Smoke.mm)
        target_include_directories(RIFESP4Smoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/Sources)
        target_link_libraries(RIFESP4Smoke
            PRIVATE MotionRIFEApple
                "-framework Foundation"
                "-framework Metal")
        target_compile_options(RIFESP4Smoke PRIVATE -fobjc-arc -Wall -Wextra -Werror)
        add_dependencies(RIFESP4Smoke MotionMetalShaders)
        add_test(NAME RIFESP4Smoke COMMAND RIFESP4Smoke)

        add_executable(RealtimeVFITestCLI
            Tests/RealtimeVFITestCLI.mm)
        target_include_directories(RealtimeVFITestCLI PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/Sources)
        target_link_libraries(RealtimeVFITestCLI
            PRIVATE MotionRIFEApple
                "-framework Foundation"
                "-framework AVFoundation"
                "-framework CoreMedia"
                "-framework CoreVideo"
                "-framework Metal"
                "-framework QuartzCore")
        target_compile_options(RealtimeVFITestCLI PRIVATE -fobjc-arc -Wall -Wextra -Werror)
        add_dependencies(RealtimeVFITestCLI MotionMetalShaders)
        add_test(NAME RealtimeVFITestCLI COMMAND RealtimeVFITestCLI --frames 8)
    endif()
endif()

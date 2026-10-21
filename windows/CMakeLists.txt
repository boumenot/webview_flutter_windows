cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "webview_flutter_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

find_program(NUGET_EXECUTABLE nuget)
if(NOT NUGET_EXECUTABLE)
  message(FATAL_ERROR "nuget.exe is required to download the WebView2 SDK. Add it to PATH.")
endif()

set(WEBVIEW2_VERSION "1.0.2903.40")
set(WEBVIEW2_ROOT "${CMAKE_CURRENT_BINARY_DIR}/packages/Microsoft.Web.WebView2.${WEBVIEW2_VERSION}")
if(NOT EXISTS "${WEBVIEW2_ROOT}/build/native/include/WebView2.h")
  execute_process(
    COMMAND "${NUGET_EXECUTABLE}" install Microsoft.Web.WebView2
      -Version "${WEBVIEW2_VERSION}" -OutputDirectory "${CMAKE_CURRENT_BINARY_DIR}/packages"
      -Source https://api.nuget.org/v3/index.json -NonInteractive
    RESULT_VARIABLE NUGET_RESULT
  )
  if(NOT NUGET_RESULT EQUAL 0)
    message(FATAL_ERROR "Unable to restore the WebView2 SDK (${NUGET_RESULT}).")
  endif()
endif()

if(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  set(WEBVIEW2_ARCH arm64)
else()
  set(WEBVIEW2_ARCH x64)
endif()

add_library(${PLUGIN_NAME} SHARED
  "webview_flutter_windows_plugin.cpp"
  "include/webview_flutter_windows/web_view_flutter_windows_plugin.h"
)
apply_standard_settings(${PLUGIN_NAME})
# The plugin throws std::invalid_argument; Flutter disables STL exceptions.
get_target_property(PLUGIN_DEFINITIONS ${PLUGIN_NAME} COMPILE_DEFINITIONS)
list(REMOVE_ITEM PLUGIN_DEFINITIONS "_HAS_EXCEPTIONS=0")
set_target_properties(${PLUGIN_NAME} PROPERTIES COMPILE_DEFINITIONS "${PLUGIN_DEFINITIONS}")
target_compile_definitions(${PLUGIN_NAME} PRIVATE _HAS_EXCEPTIONS=1)
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE "${WEBVIEW2_ROOT}/build/native/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter flutter_wrapper_plugin shlwapi shell32 ole32
  "${WEBVIEW2_ROOT}/build/native/${WEBVIEW2_ARCH}/WebView2LoaderStatic.lib"
)

configure_file("${WEBVIEW2_ROOT}/LICENSE.txt"
  "${CMAKE_CURRENT_BINARY_DIR}/WebView2.LICENSE.txt" COPYONLY)
configure_file("${WEBVIEW2_ROOT}/NOTICE.txt"
  "${CMAKE_CURRENT_BINARY_DIR}/WebView2.NOTICE.txt" COPYONLY)
set(webview_flutter_windows_bundled_libraries
  "${CMAKE_CURRENT_BINARY_DIR}/WebView2.LICENSE.txt"
  "${CMAKE_CURRENT_BINARY_DIR}/WebView2.NOTICE.txt"
  PARENT_SCOPE)

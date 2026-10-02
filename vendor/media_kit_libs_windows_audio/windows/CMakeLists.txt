# This file is a part of media_kit (https://github.com/media-kit/media-kit).
#
# Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
# All rights reserved.
# Use of this source code is governed by MIT license that can be found in the LICENSE file.

cmake_minimum_required(VERSION 3.14)
if(POLICY CMP0175)
  cmake_policy(SET CMP0175 NEW)
endif()

# This option is read by the other packages which are part of package:media_kit.
option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)

set(PROJECT_NAME "media_kit_libs_windows_audio")
project(${PROJECT_NAME} LANGUAGES CXX)

# ------------------------------------------------------------------------------

set(LIBMPV "libmpv-2.dll")

# Modified 2026 MOPELotus: use pinned LGPL runtimes for the actual CPU architecture.
if(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64")
  set(LINSEN_MPV_ARCH "arm64")
else()
  set(LINSEN_MPV_ARCH "x64")
endif()
set(LIBMPV_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../../../native/mpv/${LINSEN_MPV_ARCH}")
if(NOT EXISTS "${LIBMPV_SRC}/${LIBMPV}")
  message(FATAL_ERROR "Run python tooling/prepare_mpv.py ${LINSEN_MPV_ARCH} before Flutter build")
endif()

# ------------------------------------------------------------------------------
set(PLUGIN_NAME "media_kit_libs_windows_audio_plugin")

add_library(
  ${PLUGIN_NAME} SHARED
  "include/media_kit_libs_windows_audio/media_kit_libs_windows_audio_plugin_c_api.h"
  "media_kit_libs_windows_audio_plugin_c_api.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(
  ${PLUGIN_NAME}
  PROPERTIES
  CXX_VISIBILITY_PRESET
  hidden
)
target_compile_definitions(
  ${PLUGIN_NAME}
  PRIVATE
  FLUTTER_PLUGIN_IMPL
)

target_include_directories(
  ${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(
  ${PLUGIN_NAME}
  PRIVATE
  flutter
  flutter_wrapper_plugin
)

set(
  media_kit_libs_windows_audio_bundled_libraries
  "${LIBMPV_SRC}/${LIBMPV}"
  PARENT_SCOPE
)

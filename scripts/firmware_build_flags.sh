#!/usr/bin/env bash
# Keep diagnostics useful while preventing workstation paths in public images.
# GCC uses the last matching prefix; list the checkout before narrower roots.
FIRMWARE_SOURCE_ROOT=$(pwd -P)
FIRMWARE_PREFIX_FLAGS=""
firmware_map_prefix() {
  FIRMWARE_PREFIX_FLAGS+=" \"-ffile-prefix-map=$1=$2\" \"-fmacro-prefix-map=$1=$2\""
}
firmware_map_prefix "$FIRMWARE_SOURCE_ROOT" /sightlatch
firmware_map_prefix "$FIRMWARE_SOURCE_ROOT/build/arduino-data" /arduino/data
firmware_map_prefix "$FIRMWARE_SOURCE_ROOT/build/arduino-user" /arduino/user
firmware_map_prefix "$FIRMWARE_SOURCE_ROOT/firmware/build/compile" /arduino/build
# Arduino expands these recipe properties for globally installed toolchains too.
firmware_map_prefix '{runtime.platform.path}' /arduino/platform
firmware_map_prefix '{build.path}' /arduino/build
FIRMWARE_BUILD_PROPERTIES=(
  --build-property "compiler.c.extra_flags=$FIRMWARE_PREFIX_FLAGS"
  --build-property "compiler.cpp.extra_flags=$FIRMWARE_PREFIX_FLAGS"
)

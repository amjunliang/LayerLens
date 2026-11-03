#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
runtime="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/DeviceBridge"
# This is generated bundle content; never retain a helper from a previous SDK build.
rm -rf "$runtime"
mkdir -p "$runtime"
unavailable() {
  echo "$1" > "$runtime/unavailable.txt"
  /usr/bin/uuidgen > "$runtime/runtime.stamp"
  echo "note: DeviceBridge unavailable: $1"
  exit 0
}
[ "$(uname -m)" = arm64 ] || unavailable "当前机器缺少真机采集所需的运行环境。"
[ -d /Library/Developer/PrivateFrameworks/CoreDevice.framework/Frameworks/UniversalHID.framework ] || unavailable "当前开发工具缺少设备输入与采集组件。"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/layerlens-clang-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
make build/libLayerLensDevice.dylib build/lease-guardian
mkdir -p "$runtime/bin"
cp bin/device-resolve "$runtime/bin/device-resolve"
cp build/libLayerLensDevice.dylib LICENSE VERSION "$runtime/"
cp build/lease-guardian "$runtime/bin/lease-guardian"
chmod +x "$runtime/bin/device-resolve"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$runtime/libLayerLensDevice.dylib"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$runtime/bin/lease-guardian"
# Explicit Xcode output: changing embedded code must invalidate the app seal.
/usr/bin/uuidgen > "$runtime/runtime.stamp"

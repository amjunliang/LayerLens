#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
runtime="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/DeviceBridge"
# This is generated bundle content; never retain a helper from a previous SDK build.
rm -rf "$runtime"
mkdir -p "$runtime"
unavailable() {
  echo "$1" > "$runtime/unavailable.txt"
  echo "note: DeviceBridge unavailable: $1"
  exit 0
}
sdk="$(xcrun --sdk macosx --show-sdk-path)"
[ "$(uname -m)" = arm64 ] || unavailable "当前机器缺少真机采集所需的运行环境。"
[ -f "$sdk/System/Library/PrivateFrameworks/VideoProcessing.framework/Versions/A/VideoProcessing.tbd" ] || unavailable "当前开发工具缺少设备视频采集依赖。"
[ -d /Library/Developer/PrivateFrameworks/CoreDevice.framework/Frameworks/UniversalHID.framework ] || unavailable "当前开发工具缺少设备输入与采集组件。"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/layerlens-clang-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
make build/ipb-mirror
mkdir -p "$runtime/bin" "$runtime/libexec"
cp bin/ipb "$runtime/bin/ipb"
cp build/ipb-mirror "$runtime/libexec/ipb-mirror"
cp LICENSE VERSION "$runtime/"
chmod +x "$runtime/bin/ipb" "$runtime/libexec/ipb-mirror"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$runtime/libexec/ipb-mirror"

helper="$runtime/DeviceBridgeHelper.app"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Frameworks"
cp build/libLayerLensCompressed.dylib "$helper/Contents/Frameworks/"
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$helper/Contents/Frameworks/libLayerLensCompressed.dylib"
cp build/ipb-mirror "$helper/Contents/MacOS/DeviceBridgeHelper"
cat > "$helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.layerlens.devicebridge</string>
<key>CFBundleExecutable</key><string>DeviceBridgeHelper</string>
<key>CFBundleName</key><string>LayerLens DeviceBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$helper"

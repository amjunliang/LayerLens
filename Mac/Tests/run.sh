#!/bin/bash
# Run from any directory. Requires macOS, Xcode command-line tools and Node.js.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
build_root=/private/tmp/LayerLens-release-build
mkdir -p "$build_root"
lock_dir="$build_root/.regression-lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  printf '%s\n' 'Another regression run is active. Run only one copy at a time.' >&2
  exit 1
fi
run_dir=""
owned_paths=(
  "$build_root/run-plan-tests" "$build_root/log-clear" "$build_root/log-launch"
  "$build_root/git-path-tests" "$build_root/lifecycle-tests"
  "$build_root/integrity-tests" "$build_root/network-recovery"
  "$build_root/network-clear" "$build_root/legacy-network"
  "$build_root/network-replay" "$build_root/viewer-generations"
  "$build_root/network-viewer-events.json"
)
cleanup() {
  if [[ -n "$run_dir" ]]; then rm -rf -- "$run_dir"; fi
  rm -rf -- "${owned_paths[@]}"
  rmdir "$lock_dir" 2>/dev/null || true
  rmdir "$build_root" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_dir="$(mktemp -d "$build_root/regression.XXXXXX")"

common=(
  Mac/LayerLens/BoundedProcess.swift Mac/LayerLens/RecorderCache.swift
  Mac/LayerLens/DurableFile.swift Mac/LayerLens/BoundedStreamWriter.swift
  Mac/LayerLens/HTTPMessage.swift Mac/LayerLens/HTTPClient.swift
  Mac/LayerLens/Usbmux.swift Mac/LayerLens/AppEventStream.swift
  Mac/LayerLens/NetworkRecorder.swift Mac/Tests/RecorderTestSupport.swift
)
swift_test() {
  local name="$1"
  shift
  printf '[Swift] %s\n' "$name"
  xcrun swiftc -module-cache-path "$run_dir/modules" "$@" -o "$run_dir/$name"
  "$run_dir/$name"
}

printf '[Objective-C] network-hooks\n'
xcrun clang -fobjc-arc -fblocks -framework Foundation -I Pod/Classes/Network \
  Pod/Classes/Network/LayerLensNetworkHooks.m Mac/Tests/NetworkHooksTests.m -o "$run_dir/network-hooks"
"$run_dir/network-hooks"

printf '[Objective-C] display-geometry\n'
xcrun clang -fobjc-arc -fblocks -framework Foundation -framework CoreGraphics \
  -I Mac/DeviceBridge/Sources Mac/Tests/DisplayGeometryTests.m -o "$run_dir/display-geometry"
"$run_dir/display-geometry"

swift_test home-button Mac/LayerLens/SimulatorBridge.swift Mac/Tests/SimHomeButtonTests.swift
swift_test live-video Mac/LayerLens/LiveVideo.swift Mac/Tests/LiveVideoTests.swift
swift_test target-history Mac/LayerLens/TargetHistory.swift Mac/Tests/TargetHistoryTests.swift
swift_test target-state Mac/LayerLens/TargetStateHub.swift Mac/Tests/TargetStateHubTests.swift
swift_test git-paths Mac/LayerLens/GitController.swift Mac/Tests/GitPathTests.swift
swift_test streams-pty Mac/LayerLens/BoundedStreamWriter.swift Mac/LayerLens/PTYInputWriter.swift Mac/Tests/StreamAndPTYTests.swift
swift_test proxy Mac/LayerLens/HTTPMessage.swift Mac/LayerLens/ProxyTunnel.swift Mac/Tests/ProxyTunnelTests.swift
swift_test command-run Mac/LayerLens/CommandRunController.swift Mac/LayerLens/XcodeController.swift Mac/LayerLens/BoundedProcess.swift Mac/Tests/CommandRunTests.swift
swift_test run-plan Mac/LayerLens/XcodeController.swift Mac/LayerLens/BoundedProcess.swift Mac/Tests/XcodeRunPlanTests.swift
swift_test process-capture Mac/LayerLens/BoundedProcess.swift Mac/Tests/ProcessCaptureTests.swift
swift_test lifecycle "${common[@]}" Mac/LayerLens/AppLogRecorder.swift Mac/Tests/ConnectionLifecycleTests.swift
swift_test log-launch "${common[@]}" Mac/LayerLens/AppLogRecorder.swift Mac/Tests/LogLaunchTests.swift
swift_test log-clear "${common[@]}" Mac/LayerLens/AppLogRecorder.swift Mac/Tests/LogClearTests.swift
swift_test integrity "${common[@]}" Mac/LayerLens/AppLogRecorder.swift Mac/Tests/DataIntegrityTests.swift
swift_test legacy-reconnect "${common[@]}" Mac/Tests/LegacyNetworkReconnectTests.swift
swift_test network-recovery "${common[@]}" Mac/Tests/NetworkRecorderRecoveryTests.swift
swift_test network-clear "${common[@]}" Mac/Tests/NetworkClearTests.swift
swift_test network-replay "${common[@]}" Mac/Tests/NetworkViewerTestSupport.swift Mac/Tests/NetworkReplayTests.swift
# Produces the real SSE fixture consumed by NetworkViewerWebTests.cjs below.
swift_test viewer-epoch "${common[@]}" Mac/Tests/NetworkViewerTestSupport.swift Mac/Tests/NetworkViewerEpochTests.swift

for file in \
  GitViewStateTests.cjs GitInteractionTests.cjs RecordClearTests.cjs TargetSelectionTests.cjs TargetTaskTests.cjs AutoFollowTests.cjs PageActivityTests.cjs LiveVideoDecoderTests.cjs LiveBudgetWebTests.cjs NetworkAsyncStateTests.cjs \
  NetworkCaptureActionTests.cjs NetworkSmallScreenTests.cjs NetworkViewerWebTests.cjs CommandRunWebTests.cjs XcodeRunTests.cjs CanvasSelectionTests.cjs LiveInspectTests.cjs LiveHomeTests.cjs LiveResumeTests.cjs LiveVideoStateTests.cjs LivePixelZoomTests.cjs; do
  printf '[Node] %s\n' "$file"
  node "Mac/Tests/$file"
done
printf '%s\n' 'PASS all Mac regressions'

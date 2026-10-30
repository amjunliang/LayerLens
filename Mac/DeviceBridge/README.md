# LayerLens DeviceBridge

Derived from ipb (MIT), https://github.com/ipbtools/ipb at
bf3fcad375db5e11d5573a7ef11fa9a02c8cd1d7. See LICENSE.

LayerLens changes mirror.m to run without a window, receive JSON lines on stdin,
and emit big-endian uint32 length-prefixed compressed video packets on stdout.
The ipb launcher forwards stdin to the child. Upstream session limits remain:
3600 seconds and 8192 input events; reconnect after a session ends.
Apple private ABI requires compatible Xcode/CoreDevice and an unlocked paired iOS 27 device.

The app bundles DeviceBridgeHelper.app and launches it with LaunchServices to
obtain the console user's display session. Private session FIFOs (0700 directory,
0600 endpoints) carry JSON input and framed images. The helper watches its parent
PID and closes its session when LayerLens exits. Upstream stdout diagnostics are
redirected to stderr, keeping the frame stream clean. Build uses an explicit
Mercury rpath; build-runtime.sh signs and embeds the helper.

CompressedStream.m is LayerLens code. Its linked interpose library observes the
VideoProcessing/VideoToolbox decompression entrypoints inside our helper process.
The callback copies the device's compressed CMSampleBuffer bytes, then skips the
host decode. No Apple process is injected or modified. The helper forwards hvcC
(or avcC), source timestamps and original length-prefixed NAL units. WebCodecs in
the shared webpage is the only video decoder. Encoder padding is cropped only
when drawing the decoded frame in the browser. Protocol: 05 = JSON configuration,
06/07 = key/delta with big-endian 64-bit microsecond PTS followed by source bytes.
Swift caches a bounded GOP for newly joined or recovering viewers. No JPEG
conversion or VideoToolbox encoding occurs on the physical-device live path.

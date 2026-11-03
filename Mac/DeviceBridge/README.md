# LayerLens DeviceBridge

The device resolution and CoreDevice/HID glue are derived from ipb (MIT),
commit `bf3fcad375db5e11d5573a7ef11fa9a02c8cd1d7`. See LICENSE.

## Current runtime

- `bin/device-resolve` resolves a device identifier and its CoreDevice tunnel,
  returning `[deviceUUID, interface, hostIP, deviceIP, productType]` as JSON.
- `libLayerLensDevice.dylib` runs media reception and HID input in the GUI app.
  Apple's receiver decodes device video; a bounded latest-frame slot passes borrowed
  CVPixelBuffers to Swift at up to 30 fps. The GUI app's LiveVideoEncoder and
  LiveVideoBroadcaster handle H.264 encoding and WebSocket recovery for both devices
  and simulators. There is no JPEG encode/decode stage.
- `bin/lease-guardian` owns the Apple `devicectl` tunnel observer. Only LayerLens
  holds the lifetime pipe's write end, marked close-on-exec. Session closure or
  main-process death triggers EOF; the guardian terminates and reaps its command,
  then exits. TERM has a 500 ms grace period before KILL. The observer's 15-second
  timeout remains a secondary fallback. No shared system service is terminated.

Native callback types: 8 = nonfatal rotation-result JSON, 9 = geometry JSON, 10 = borrowed CVPixelBuffer pointer
(count=0, retained by Swift before returning), 254 = status, 255 = error,
0 = final closure. WebSocket types are shared: 1 = avcC, 2 = H.264 keyframe,
3 = delta. Slow viewers skip deltas until a fresh keyframe; late viewers request
one from the encoder without reconnecting device capture.
RemoteXPC owns service sockets after creation; the original RTP socket remains
session-owned. Input, image conversion and setup run off the UI thread.

One physical device can be active at a time; multiple windows share its session.
Simulator capture is independent. Mode/focus changes retain the connection;
closing the last viewer retains the session for 30 seconds.

## Build and validation

`make` builds only the native library and lifetime guardian. The app's
`build-runtime.sh` packages and signs these with the resolver and license.
Private frameworks require a compatible Apple Silicon Mac and developer tools.

After building, run the guardian lifecycle checks:

```sh
mkdir -p /private/tmp/LayerLens-release-build
python3 Mac/DeviceBridge/scripts/test_lease_guardian.py
```

Run this command from the repository root. The tests use disposable commands
that ignore TERM and cover normal closure, parent SIGKILL and guardian SIGTERM.
Current architecture and verified behavior are documented in
[device-live.md](../../docs/device-live.md).

Physical-device rotation uses `devicectl device orientation rotate` on the serial device-control queue, separate from HID input. The command has a 5-second deadline; failures are returned as nonfatal input results. Orientation comes from the command result and normal display metadata, shared across viewers.

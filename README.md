# LayerLens

[中文](README.zh-CN.md)

Inspect, edit and explore your iOS view hierarchy, in the LayerLens Mac app or in your browser.

- **Hierarchy**: searchable window / view / layer tree, annotated with owning view controllers and ivar names
- **2D**: screenshot with frame overlays; hover or click to locate views
- **3D**: exploded layers you can rotate, pan and zoom, with adjustable spacing and an isolate mode for the selection
- **Attributes**: view and edit frame, colors, alpha, hidden, text and more, applied instantly
- **Class info**: ivars (with current values), properties and methods across the class chain
- **Live** (simulator): see and drive the simulator screen in the window; ⌥-click to select a view
- **Run**: have Xcode rebuild and run the app, with build errors shown on the page
- **Devices**: works over USB on physical devices

## How it fits together

| Part | Location | Role |
|---|---|---|
| iOS pod | `Pod/` | Runs a tiny HTTP server inside your debug build that serves the hierarchy, attributes and screenshots |
| Mac app | `Mac/` | Discovers apps on simulators and USB devices, serves the web UI and live screen, and drives Xcode |
| Web UI | `Web/` | Plain HTML/CSS/JS, no build step, no CDN; English and Chinese, light and dark |

The Mac app's window is the web UI. You can also open `http://127.0.0.1:9523` in a browser, and use several windows or tabs at once.

## Requirements

- iOS 15+, CocoaPods
- macOS 14+, Xcode (the live screen uses Xcode's simulator frameworks)
- Chrome or Safari when using a browser (the live screen needs WebCodecs)

## 1. Add the pod

Add it to the `Debug` configuration only, so it never ships in a release build:

```ruby
pod 'LayerLens', :git => 'https://github.com/amjunliang/LayerLens.git', :configurations => ['Debug']
```

LookinServer, a dependency, declares iOS 9, which recent Xcode versions no longer support. Add this to the end of your Podfile:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      if config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].to_f < 12.0
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      end
    end
  end
end
```

Run `pod install`, then run the app in the Debug configuration. No code is needed. The Xcode console prints:

```
[LayerLens] Running on port 9527, open the LayerLens Mac app to inspect
```

- Ports start at 9527 and go up to 9536 when taken, so several apps can run at once.
- The server listens on the loopback address only, and does not start in non-`DEBUG` builds.
- LookinServer comes in as a dependency. If you already use Lookin, its Mac client keeps working.

## 2. Run the Mac app

Open `Mac/LayerLens.xcodeproj` in Xcode and run it, or:

```sh
cd Mac
xcodebuild -scheme LayerLens -configuration Release -derivedDataPath build
open build/Build/Products/Release/LayerLens.app
```

The device list at the top left shows running simulators and USB devices, with the LayerLens-enabled apps on each. Pick one to inspect it. Closing the window keeps the app running in the menu bar, so the browser still works.

The app is ad-hoc signed by default, so macOS may ask for the Automation permission again after each re-sign. To keep a stable signature, create `Mac/Local.xcconfig` (ignored by git) containing `CODE_SIGN_IDENTITY = Apple Development: xxx`.

## Live screen (simulator)

Pick an app on a simulator and switch to Live. The Mac app captures the simulator screen itself, encodes it as H.264 for the page, and forwards touches, keys and paste to the simulator. Nothing else needs to be installed.

- Drag to scroll and swipe in the app; ⌥-click to select a view and switch to 2D. Selecting needs the integrated app connected and in the foreground; otherwise ⌥-click is a normal tap, so Live also works as a plain simulator.
- The toolbar has Home, App Switcher, Rotate and Copy Screenshot.
- When the app goes to the background the status dot turns orange; the page keeps the connection and picks up again when it returns.
- Windows watching the same simulator share one capture and encoder.

**Taps and drags do nothing**: after a reboot, a simulator sometimes stops accepting injected touches. The page offers a fix when repeated drags don't change the screen, or choose Fix Simulator Touch… in the View options menu. This restarts backboardd and SpringBoard in the simulator, quitting the foreground app; it is back in about 10 seconds.

## Run button

The Run button in the toolbar has Xcode build and run with the current scheme on the device you're viewing, just like Xcode's own Run button. Build errors are shown on the page, and the page reconnects when the app restarts.

- LayerLens finds the right Xcode workspace from the app's source paths, even with several projects or several Xcode versions open.
- The first run asks for permission to control Xcode. If you declined, enable it in System Settings › Privacy & Security › Automation.
- Before running, Xcode's run destination is switched to the device you're viewing. If Xcode has no destination for it (for example the scheme doesn't support it), Xcode's current destination is used and the page tells you.

## Physical devices

Connect the device with a cable and run the app. It appears in the device list with no extra setup; the Mac app reaches it through usbmuxd.

- Wi-Fi connections aren't supported.
- The live screen is simulator only.

## Shortcuts

Press `?` for the full list. The common ones:

| Keys | Action |
|---|---|
| `R` | Refresh |
| `1` `2` `3` | Live / 2D / 3D |
| `F` | Zoom to selection |
| `0` | Fit to window |
| `S` | Isolate the selection in 3D |
| `[` `]` | Layer spacing in 3D |
| Space + drag | Pan the canvas |
| `⌘` `C` | Copy the selected node's path |

## Troubleshooting

- **The app isn't in the device list**: make sure it runs in Debug and the console shows `[LayerLens] Running on port …`. Physical devices must be connected over USB.
- **"… is outdated, some features may not work"**: the pod and the Mac app use different API versions. Update both to the same release.
- **Live screen unavailable**: make sure Xcode is installed and selected with `xcode-select` (not the Command Line Tools). The page shows the exact reason.
- **No permission to control Xcode**: allow LayerLens to control Xcode in System Settings › Privacy & Security › Automation.

## Implementation

- `Pod/Classes/Server`: HTTP/1.1 server on Network.framework, plus an event stream that lets the page notice app restarts.
- `Pod/Classes/Lookin`: the only code that calls LookinServer, which collects the hierarchy, attributes and screenshots. It uses LookinServer internals, so the version is pinned.
- `Pod/Classes/Runtime`: Objective-C runtime helpers for class info.
- `Mac/LayerLens/HubServer.swift`: the Mac server (port 9523). Serves the web UI and forwards `/t/<device>/<app>/...` to the matching iOS app. Listens on 127.0.0.1 only and checks Host and Origin.
- `Mac/LayerLens/TargetRegistry.swift`, `Usbmux.swift`: discover apps on simulators and USB devices.
- `Mac/LayerLens/Simulator*.swift`: the live screen. Reads the screen IOSurface and injects touches and keys through the private CoreSimulator / SimulatorKit APIs, and encodes with VideoToolbox.
- `Mac/LayerLens/XcodeController.swift`: drives Xcode through AppleScript.
- `Web`: the web UI. A Debug build of the Mac app reads `Web/` straight from the repo, so a page refresh picks up changes.

## Acknowledgements

- [LookinServer](https://github.com/QMUI/LookinServer) by QMUI: view hierarchy data
- [baguette](https://tddworks.github.io/baguette/) by tddworks: reference for simulator screen capture and input injection

## License

MIT. See [LICENSE](LICENSE).

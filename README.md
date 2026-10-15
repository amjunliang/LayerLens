# LayerLens

[中文](README.zh-CN.md)

Inspect, edit and explore your iOS view hierarchy in the browser.

LayerLens runs a tiny HTTP server inside your debug build. Open the printed URL in a desktop browser and you get:

- **Hierarchy**: searchable tree of windows, views and layers, with view controllers and ivar names
- **2D**: screenshot with frame overlays, hover and click to locate views
- **3D**: exploded layers you can rotate, zoom and focus on a subtree
- **Attributes**: read and edit frame, colors, alpha, hidden, text and more, changes apply immediately
- **Class info**: ivars with live values, properties and methods of the whole class chain
- **Live** (simulator): mirror the simulator screen and control it from the browser, ⌥-click to select a view
- **Run** (simulator): rebuild and relaunch the app in Xcode from the browser, build errors are shown in the page

No Mac app and no browser extension. The page is plain HTML/CSS/JS bundled in the pod, in English and Chinese.

## Requirements

- iOS 15+
- CocoaPods
- Chrome or Safari (live mode needs WebCodecs)
- Live mode and Run: [baguette](https://tddworks.github.io/baguette/) on the Mac, see [Live mode and Run](#live-mode-and-run)

## Installation

Add LayerLens to the `Debug` configuration only, it is a debugging tool and must not ship:

```ruby
pod 'LayerLens', :configurations => ['Debug']
```

Then run `pod install`. LookinServer is pulled in as a dependency. If you already use Lookin, the Mac app keeps working side by side.

Recent Xcode versions reject LookinServer's iOS 9 deployment target. If the build fails with "deployment target ... is set to 9.0", raise it for all pods in your Podfile:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    end
  end
end
```

## Usage

### Option 1: environment variable, no code

In Xcode, edit the scheme › Run › Arguments › Environment Variables, add `LAYERLENS_AUTOSTART` = `1`. LayerLens starts with the app and logs the URL:

```
[LayerLens] Running at: http://127.0.0.1:9527/
```

### Option 2: code

```objc
#if DEBUG
#import <LayerLens/LayerLens.h>
#endif

#if DEBUG
[[LayerLens sharedInstance] start];
#endif
```

Then open `http://127.0.0.1:9527` on the Mac running the simulator. If the port is taken, the next free one up to 9536 is used, check the log.

### Real devices

Real devices are supported over USB only. Plug the device into the Mac, run the app, and it shows up in the LayerLens Mac app with no extra setup.

- Wi-Fi connections are not supported.
- Live mode and Run are simulator only.

`start`/`startWithLocalNetwork:` do nothing outside `DEBUG` builds.

## Live mode and Run

Both are optional and rely on [baguette](https://tddworks.github.io/baguette/), a third-party command line tool running on the Mac. It streams the simulator screen, forwards input and loads the small plugin shipped with LayerLens (`BaguettePlugins/layerlens`) that drives Xcode.

Install it once:

```sh
brew install baguette
```

That's it. LayerLens adds a build phase that starts baguette in the background with its plugin when you build for the simulator in Debug, the log goes to `/tmp/baguette.log`. If baguette is not installed the step is skipped and everything else works.

Starting it yourself requires the plugin directory, otherwise Run is unavailable:

```sh
baguette serve --allowed-hosts 127.0.0.1 --plugin-dir <path to LayerLens>/BaguettePlugins
```

Quit it:

```sh
pkill -f "baguette serve"
```

baguette keeps running in the background until you quit it, log out or restart the Mac. Quitting Xcode, stopping the app or closing the simulator does not stop it, and later builds reuse the running instance. After updating LayerLens, quit it once so the next build loads the new plugin. The next simulator build starts it again. The shortcuts panel (`?`) in the page also lets you copy these commands.

### Multiple simulators

- One baguette serves all simulators. Each running app starts its own LayerLens on the next free port (9527, 9528, ...), and each page only shows and controls the simulator its app runs in.
- Run always uses Xcode's current run destination. If that is another simulator, the app in this page does not restart and the page stays on "Building and restarting app", click Run again to stop tracking.
- Ports are taken in startup order, so after restarting several apps a URL may point to a different simulator. Check the app name and the log when it matters.

The first time you press Run, macOS asks to allow controlling Xcode. If it was denied, enable it in System Settings › Privacy & Security › Automation.

## Troubleshooting

| Message in the page | Cause | Fix |
|---|---|---|
| baguette is not running | Not installed, or quit | Install it and build once |
| baguette has no plugins loaded | Started by hand without `--plugin-dir` | Quit it and build again |
| Xcode is not running | | Open the project in Xcode |
| This project is not open in Xcode | Xcode has another project open | Open the workspace of this app |
| No permission to control Xcode | Automation permission denied | System Settings › Privacy & Security › Automation |

- **Stuck on "Building and restarting app"**: Xcode's run destination is probably not this simulator, so the app never restarts. Click Run again to stop tracking.
- **Taps do nothing in live mode**: copy the fix command from the shortcuts panel (`baguette heal`), it restarts SpringBoard.
- **Build warning "baguette is running without the LayerLens plugins"**: a baguette started elsewhere is running, quit it and build again.

## How it works

- `Classes/Server`: HTTP/1.1 server on Network.framework, plus a server-sent events stream so the page knows when the app restarts.
- `Classes/Lookin`: the only place that talks to LookinServer, which collects the hierarchy, attributes and screenshots. LookinServer internals are used, hence the pinned version.
- `Classes/Runtime`: Objective-C runtime reader for class info.
- `Assets/web`: the page. No build step, no CDN.
- `BaguettePlugins/layerlens`: baguette plugin. The page passes the app's compile-time source path so the plugin picks the matching Xcode workspace.

## Acknowledgements

- [LookinServer](https://github.com/QMUI/LookinServer) by QMUI
- [baguette](https://tddworks.github.io/baguette/) by tddworks

## License

MIT, see [LICENSE](LICENSE).

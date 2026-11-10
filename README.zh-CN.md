# LayerLens

[English](README.md)

查看、修改 iOS 视图层级, Mac App 和浏览器使用同一界面.

- **层级**: 可搜索的 window / view / layer 树, 标注所属 VC 和 ivar 名
- **2D**: 截图叠加 frame 框, 悬停、点击定位视图
- **3D**: 分层展开, 可旋转、平移、缩放, 调整层间距, 独立显示选中元素
- **属性**: 查看并修改 frame、颜色、alpha、hidden、文字等, 修改立即生效
- **类信息**: 整条类链的 ivar (带当前值)、property、method
- **实时** (模拟器): 在窗口中显示并操作模拟器画面, ⌥ + 点击选中视图
- **运行**: 让 Xcode 重新编译运行当前 App, 编译错误直接显示在页面上
- **真机**: USB 连接即可使用

## 组成

| 部分 | 位置 | 作用 |
|---|---|---|
| iOS SDK | `Pod/` | 在 Debug 包内运行一个很小的 HTTP 服务, 提供层级、属性、截图等接口 |
| Mac App | `Mac/` | 自动发现模拟器和 USB 真机上的 App, 提供网页和实时画面, 驱动 Xcode 运行 |
| 网页 | `Web/` | 原生 HTML/CSS/JS, 无构建步骤, 不依赖 CDN, 支持中英文和深色模式 |

Mac App 的窗口就是这个网页, 也可以在浏览器中打开 `http://127.0.0.1:9523`, 多个窗口、标签页可以同时查看.

## 环境要求

- iOS 15+, Swift Package Manager 或 CocoaPods
- macOS 14+, Xcode (实时画面使用 Xcode 自带的模拟器框架)
- 浏览器访问时使用 Chrome 或 Safari (实时画面需要 WebCodecs)

## 1. 集成 iOS SDK

### Swift Package Manager

1. 在 Xcode 中选择 **File > Add Package Dependencies…**。
2. 输入 `https://github.com/amjunliang/LayerLens.git`。
3. 当前先选择 **Branch: master**（已有的 `0.7.0` 标签尚不包含 SPM 配置）。
4. 将 **LayerLens** 产品添加到需要调试的 App target，无需嵌入动态框架。
5. 在 App target 的 **Build Settings > Excluded Source File Names** 中，仅为 **Release** 设置以下任一种方式，效果相同：
   - 分别添加两项：`LayerLens.o` 和 `LayerLensCore.o`。
   - 添加一项通配符：`LayerLens*.o`，同时匹配这两个模块。

   保留已有值；Debug 不添加。使用其他发布配置时也需要对它们设置。

以 Debug 配置运行 App 即可自动启动，无需调用初始化方法，也无需额外添加 `-ObjC`。需要使用日志 API 时，导入和调用都放在 Debug 条件中：

```swift
#if DEBUG
import LayerLens
#endif

// 在需要记录日志的位置：
#if DEBUG
LayerLens.log("调试信息")
#endif
```

Objective-C 同样用 `#if DEBUG` 包住 `@import LayerLens;` 和 API 调用。

SPM 与 CocoaPods 二选一，不要在同一个 App 中重复集成。Xcode 默认将此产品以 `LayerLens.o` 和 `LayerLensCore.o` 链入 App；上面的 Release 排除设置让 SDK 实现不进入最终可执行文件，无需在每次发布前手动移除依赖。SPM 仍可能解析、下载和编译 SDK。仅包住调用或禁用服务启动并不能替代这个排除设置。

### CocoaPods

只加到 `Debug` 配置, 调试工具不能进入正式包:

```ruby
pod 'LayerLens', :git => 'https://github.com/amjunliang/LayerLens.git', :configurations => ['Debug']
```

执行 `pod install` 后以 Debug 配置运行 App 即可, 无需编写代码. 启动后 Xcode 控制台输出:

```
[LayerLens] Running on port 9527, open the LayerLens Mac app to inspect
```

- 端口从 9527 开始, 被占用时依次尝试到 9536, 多个 App 可以同时运行.
- 服务只监听本机回环地址; 非 `DEBUG` 编译时不会启动.
- 没有第三方依赖. 层级采集基于内置的 LookinServer 代码, 已改为 `LayerLens_` 前缀, 与项目中原有的 LookinServer 互不影响, Lookin 的 Mac 客户端照常可用.

### 多平台项目

SPM 的公共入口可用于多平台 target。iOS 使用 `LayerLensCore` 提供实际检查能力；原生 macOS 和其他未支持的 Apple 平台仅提供空日志接口，不启动服务、不会编译 UIKit 实现。`logDirectory` 在这些平台返回空字符串。这不代表支持原生 Mac App 的层级检查。

暂不支持 SwiftUI 逻辑视图树检查，仅展示 App 实际生成的 UIKit / CALayer 层级。

## 2. 运行 Mac App

用 Xcode 打开 `Mac/LayerLens.xcodeproj` 运行, 或:

```sh
cd Mac
xcodebuild -scheme LayerLens -configuration Release -derivedDataPath build
open build/Build/Products/Release/LayerLens.app
```

左上角的设备列表会列出运行中的模拟器和 USB 真机, 以及其上集成了 LayerLens 的 App, 选中即可查看. 关闭窗口后 Mac App 继续在菜单栏运行, 浏览器仍可访问.

默认使用 ad-hoc 签名, 每次重新签名后 macOS 可能需要重新允许"自动化"权限. 在 `Mac/` 下新建 `Local.xcconfig` (已忽略), 写入 `CODE_SIGN_IDENTITY = Apple Development: xxx` 可固定签名.

## 实时画面 (模拟器)

选择模拟器上的 App 后切到「实时」. Mac App 直接采集模拟器屏幕, 编码为 H.264 推给网页, 并把触摸、键盘、粘贴转发给模拟器, 不需要安装其他工具.

- 拖动即在 App 内滑动; 按住 ⌥ 点击选中视图并切到 2D. 选择元素需要已集成的 App 已连接且在前台, 否则 ⌥ + 点击按普通点击处理, 实时画面可当普通模拟器使用.
- 工具栏可回到主屏幕、打开多任务、旋转、复制屏幕截图.
- 「MCP 设置…」可一键为 Claude Code 和 Codex 安装内置只读 MCP 与 Skill, 让 Agent 直接读取当前选中元素、源码目录, 并按需搜索日志和抓包, 详见 [docs/mcp.md](docs/mcp.md).
- App 进入后台时状态点变为橙色, 连接保持, 回到前台后自动恢复.
- 多个窗口同时观看同一台模拟器时共用一路采集编码.

**点击、拖动无效**: 模拟器重启后偶尔不再接收注入的触摸. 网页检测到连续拖动但画面无变化时会提示修复, 也可以在「视图选项」菜单中选择「修复模拟器触摸」. 修复会重启模拟器的 backboardd 和 SpringBoard, 前台 App 会被结束, 约 10 秒后恢复.

## 运行按钮

点击工具栏的运行按钮, Xcode 按当前 Scheme 在正在查看的设备上重新编译运行, 与点击 Xcode 的运行按钮相同. 编译失败时错误直接显示在页面上; App 重启后页面自动重连.

- LayerLens 根据 App 编译时的源文件路径找到对应的 Xcode 工作区, 同时打开多个项目或多个 Xcode 时也能区分.
- 第一次运行时 macOS 会询问是否允许 LayerLens 控制 Xcode. 如果之前拒绝了, 在 系统设置 › 隐私与安全性 › 自动化 中打开.
- 运行前会把 Xcode 的运行目标切到正在查看的设备. Xcode 中没有该设备的运行目标时 (如 Scheme 不支持), 沿用 Xcode 当前的运行目标, 页面会给出提示.

## 真机

用数据线连接 Mac 后运行 App, 设备列表中即会出现, 无需额外配置. Mac App 经 usbmuxd 访问设备上的服务.

- 不支持 Wi-Fi 连接.
- 实时画面仅支持模拟器.

## 快捷键

按 `?` 查看全部快捷键, 常用的有:

| 按键 | 作用 |
|---|---|
| `R` | 刷新 |
| `1` `2` `3` | 实时 / 2D / 3D |
| `F` | 放大选中元素 |
| `0` | 适应窗口 |
| `S` | 3D 中独立显示选中元素 |
| `[` `]` | 3D 中调整层间距 |
| 空格 + 拖动 | 平移画布 |
| `⌘` `C` | 复制选中节点路径 |

## 常见问题

- **设备列表中没有 App**: 确认以 Debug 配置运行, 且控制台有 `[LayerLens] Running on port …`; 真机需通过 USB 连接.
- **提示版本过旧**: iOS 端 Pod 与 Mac App 的接口版本不一致, 把两者更新到同一版本.
- **实时画面不可用**: 确认已安装 Xcode, 并用 `xcode-select` 选中它 (而不是 Command Line Tools). 页面上会显示具体原因.
- **运行按钮提示没有控制 Xcode 的权限**: 在 系统设置 › 隐私与安全性 › 自动化 中允许 LayerLens 控制 Xcode.

## 实现

- `Pod/Classes/Server`: 基于 Network.framework 的 HTTP/1.1 服务, 另有一个事件流让网页感知 App 重启.
- `Pod/Classes/Lookin`: 唯一调用内置 Lookin 代码的地方, 由它采集层级、属性和截图.
- `Pod/Classes/Vendor/Lookin`: 内置的 [LookinServer](https://github.com/QMUI/LookinServer) (develop `ae39613`), 类名、分类方法和宏改为 `LayerLens_` 前缀, 去掉了与 Lookin 客户端通信的部分 (Peertalk、连接与请求处理、导出).
- `Pod/Classes/Runtime`: 读取类信息的 Objective-C runtime 工具.
- `Mac/LayerLens/HubServer.swift`: Mac 端服务 (端口 9523), 提供网页并把 `/t/<设备>/<App>/...` 转发给对应的 iOS App; 只监听 127.0.0.1, 并校验 Host 和 Origin.
- `Mac/LayerLens/TargetRegistry.swift`, `Usbmux.swift`: 发现模拟器和 USB 真机上的 App.
- `Mac/LayerLens/Simulator*.swift`: 实时画面. 通过 CoreSimulator / SimulatorKit 私有接口读取屏幕 IOSurface、注入触摸和按键, 用 VideoToolbox 编码.
- `Mac/LayerLens/XcodeController.swift`: 通过 AppleScript 让 Xcode 运行.
- `Web`: 网页. Debug 编译的 Mac App 直接读取仓库中的 `Web/`, 修改后刷新页面即可生效.

## 致谢

- [LookinServer](https://github.com/QMUI/LookinServer) by QMUI: 视图层级数据
- [baguette](https://tddworks.github.io/baguette/) by tddworks: 模拟器画面采集与输入注入的实现参考

## 许可

MIT, 见 [LICENSE](LICENSE).

## 实验性真机实时控制

所有已连接设备均显示「实时」入口，不按系统版本置灰。进入后实际尝试采集，失败时在画布显示原因并提供「重试」。当前已验证 macOS 27 / Xcode 27 / iOS 27 组合。
设备需配对、信任 Mac、开启开发者模式并保持解锁，Xcode 的设备支持映像需就绪。
选中 USB 真机或其上的 App 后点击「实时」，可测试单指点击拖动、Home、多任务、键盘和文本粘贴。
Option + 点击定位视图仍要求前台 App 已集成 Pod。旋转请直接转动手机，画面会跟随；真机旋转按钮暂未开放。

真机采集与 HID 输入在 LayerLens 主进程内的原生库运行，不启动独立采集 helper，也不使用 FIFO。Apple 接收器解码后将像素缓冲区交给真机与模拟器共用的低延迟 H.264 编码器，经 WebSocket 发给网页解码显示，不再转换 JPEG。真机源帧最高 30 帧/秒；按观看尺寸缩放编码，新窗口和慢窗口通过请求关键帧恢复。
同一台真机可被多个窗口共享；目前一次支持一台真机，模拟器会话独立。页面失焦或切到 2D/3D 保留连接；最后一个观看连接关闭后保留 30 秒再释放。仅保留最新源帧，关键帧按需重新编码，不重放 GOP。
设备解析仍使用短时 devicectl 命令；隧道观察任务由小型守护进程管理，通过生命周期管道绑定主 App。正常关闭或主 App 被强杀时，管道断开，守护进程终止并回收自己启动的观察任务后退出；正常终止等待最多 500 毫秒，再强制终止。原有 15 秒超时保留为第二层兜底。守护进程不采集画面，也不终止共享系统服务。私有框架若在主进程内崩溃，可能影响整个 App，仍属于实验性功能。
参考实现来源与 MIT 许可证见 `Mac/DeviceBridge/`。

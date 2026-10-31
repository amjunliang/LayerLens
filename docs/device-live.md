# 真机实时画面与控制

## 当前架构

网页选择真机并进入实时模式后显示 Loading。`device-resolve` 解析设备 UUID、
CoreDevice 隧道接口及两端地址。LayerLens 主进程加载 `libLayerLensDevice.dylib`，
协商 Apple 媒体接收和 HID 服务。

设备视频由 Apple 接收器解码为像素缓冲区，通过进程内回调交给 Swift，复用模拟器的
`LiveVideoEncoder` 和 `LiveVideoBroadcaster`。像素按有效画面裁剪、观看尺寸缩放后编码为
低延迟 H.264，经 WebSocket 发给同一套网页 WebCodecs 解码器。不再生成或解码 JPEG。
真机源帧最高 30 fps，仅保留最新源帧。协议统一为 0x01=avcC、0x02=关键帧、0x03=增量帧。
慢窗口丢弃增量帧后等待新关键帧；新窗口请求立即编码当前源帧，不重启设备采集。
首张解码画面到达后隐藏 Loading。
点击、拖动、键盘及 Home/多任务操作通过原生 HID 通道发给设备。

同一设备多个窗口共享采集，目前同时支持一台真机。2D/3D 切换与窗口失焦保留连接；
最后一个观看连接关闭后保留 30 秒再释放。模拟器使用独立的 CoreSimulator/SimulatorKit 链路。

## 生命周期

进程关系：LayerLens → lease-guardian → Apple devicectl 隧道观察任务。
采集、解码及触摸均在主程序内，守护进程仅管理隧道观察任务的退出。

主程序独占生命周期管道写端，并设置 close-on-exec；守护进程持有读端。
正常关闭会话时关闭写端；崩溃或 SIGKILL 时系统也会关闭它。守护进程收到 EOF 后，
向自己创建的命令进程组发送 TERM，最多等待 500 毫秒，再发送 KILL，回收后退出。
不终止共享的 CoreDevice、CoreSimulator 或其他应用的进程。观察命令的 15 秒超时
保留为第二层兜底。

## 验证记录

环境：macOS 27.0.1、Xcode 27.0（27A266a）、iPhone 15 / iOS 27.0.1。

- 接入 H.264 前，真机画面尺寸 1179×2556、pointScale=3；点击变色和列表拖动通过。
- 切换到模拟器后显示和触摸通过。
- 连续 8 轮真机采集/关闭及文件描述符复用检查通过。
- 生命周期测试覆盖正常关闭、父进程 SIGKILL、守护进程 SIGTERM；子命令忽略 TERM 时，
  三项均约 0.56 秒内清理完成。
- 已安装 Release 真机采集中强杀主程序，实际守护进程和 devicectl 约 0.25 秒内退出。
  正常退出无残留；重新打开后真机可重新连接。
- 示例中的公开采集检测 API 在投屏时显示 sceneCaptureState=active、isCaptured=true，
  停止后恢复；这些值不能识别单次触摸来源。
- 共用链路的独立测试通过：真实 H.264 编码解码回环验证奇数宽度、右/下 padding 裁剪、
  顶部/底部颜色方向、IOSurface 输入及缩放；广播测试验证有界发送、积压恢复、新窗口及配置变化。
- H.264 接入后，Debug 实机与 iPhone 17 Pro / iOS 26.5 模拟器均验证显示、点击变色；
  真机列表拖动及实时→2D→实时切换通过。两条 WebSocket 路由均验证 avcC 和 IDR 关键帧，
  新观看者加入与尺寸上报后继续收到可用配置/关键帧，无 JPEG 或原始 HEVC 包。
- 最终 Release 编译、签名和安装通过；安装后的真机、模拟器路由再次通过首帧、
  新观看者和尺寸上报检查，WKWebView 中两种设备均正常显示。

## 使用条件与限制

设备需已配对、信任 Mac、开启开发者模式、保持解锁，开发工具的设备支持需就绪。
实时入口不按系统版本隐藏，实际连接失败时显示原因并允许重试。
已验证上述系统组合，不代表其他系统和设备均支持。

真机仍需先解码设备视频再编码 H.264，并非原始码流透传。实际资源开销需按设备测量。
当前使用私有框架；框架异常可能影响
主程序，短时验证不等于长期稳定性保证。尚未完成全部硬件按键、键盘组合键、旋转和
长时间性能验证。

## 编码器与广播测试

在仓库根目录运行（需要本机 VideoToolbox 编解码能力）：

```sh
mkdir -p /private/tmp/LayerLens-release-build
swiftc Mac/LayerLens/LiveVideo.swift Mac/Tests/LiveVideoTests.swift -o /private/tmp/LayerLens-release-build/live-video-tests
/private/tmp/LayerLens-release-build/live-video-tests
node Mac/Tests/LiveVideoDecoderTests.cjs
```

网页解码测试覆盖首帧等待、解码积压后的关键帧恢复、配置变化，以及已关闭/出错解码器的重建。

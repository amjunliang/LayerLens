# Device Hub 真机实时控制接入计划

日期：2026-10-30  
分支：`codex/device-hub-integration`

## 目标与范围

为 LayerLens 的实时页增加 iOS 27 真机画面、点击拖动、键盘和 Home 控制。首轮验证使用已配对、已解锁、开启开发者模式且可被 Xcode 27 发现的设备。运行时检测实际能力，不单凭系统版本开放功能。

本机已确认 macOS 27.0.1、Xcode 27.0（27A266a），并在 CoreDevice / DeviceKit 中发现 UniversalHID 和 AVConference 相关符号。尚未验证本机真机控制成功；私有符号和开源项目的成功记录不等于本项目已经可用。

## 1. 独立验证后端（先决条件）

- 固定 ipb 参考源码的 commit，核对 MIT 许可证及实际依赖。
- 在独立 Mac helper 中验证 CoreDevice 设备枚举、DDI 状态、HID 服务发现和视频流协商，不先修改现有模拟器后端。
- 使用一台 iOS 27 真机依次验证首帧、点击、拖动、Home、键盘按下与释放。
- 记录 macOS / Xcode / CoreDevice / iOS 版本、设备型号、连接方式、错误与结果；同时确认 Device Hub 退出后仍可工作，以及隧道保活方式。
- 通过条件：无 Apple 进程注入、无需 Apple 专属 entitlement，独立 helper 可持续收帧且操作位置准确。如果失败，先明确服务拒绝、DDI、ABI 或权限原因再决定后续路径。

## 2. 接入设备与会话

- 新增真机后端与 helper 通信层；IPC 区分会话控制、帧数据、输入、状态和错误，并限制积压。
- 在 TargetRegistry 中映射现有 USB 设备 UDID 与 CoreDevice 标识，避免重复设备。首版只开放已发现 USB 真机的实时能力，Wi-Fi 产品支持另行验证。
- 真机媒体/HID 使用 CoreDevice 会话；现有 Pod 请求继续经 usbmuxd 转发。
- 增加设备级能力与状态：视频、触摸、键盘、按钮、锁定、未配对、DDI 未就绪和不支持。
- 所有观看者离开时停止媒体、释放输入、退出 helper；helper 异常退出时主程序显示可恢复错误。

## 3. 视频接入现有网页

- 从真机媒体流取得解码后的 CVPixelBuffer；扩展 SimulatorEncoder 接受像素缓冲区，复用 H.264 / WebSocket / WebCodecs 链路。
- 从现有 SimulatorLive / SimulatorStream 中提取必要的共享会话与广播逻辑，保留模拟器专属采集和输入实现。
- 增加通用实时路由，兼容已有 /sim 路由；按设备能力显示实时页和控件。
- 处理实际内容尺寸、编码 padding、横竖屏和坐标变换；视频帧及输入使用同一份几何状态。
- 通过条件：横竖屏不拉伸、点击落点准确，多窗口共用一条真机会话，慢观看者不会阻塞采集。

## 4. 输入和检查联动

- 将网页 down / move / up 映射为真机 HID；断开、切设备和失焦时释放触摸和键盘状态。
- 首版实现单指点击拖动、Home、基础键盘；滚轮、组合键、中文提交与剪贴板逐项验证后开放。
- 输入超时或连接失败后不自动重放已提交操作。
- 复用 Option + 点击选择视图流程；只有已连接 Pod 且目标 App 在前台时执行层级定位。
- 按实际能力开放硬件按钮，不承诺所有机型支持 Siri、Action Button 或 Camera Control。

## 5. 验收与交付

- 构建 Mac App 与 helper，确认打包路径、签名及私有框架加载错误可诊断。
- 真机验证：连续观看至少 10 分钟、点击长按拖动、键盘按下释放、横竖屏、切后台、锁定再解锁、USB 断连重连、双窗口与最后观看者退出。
- 回归模拟器实时画面、触摸、键盘、截图及 Option 选择；确认旧 iOS 真机仍可使用原有层级检查。
- 记录首帧时间、输入延迟、CPU 与内存变化及测试条件，不提前承诺帧率或低延迟。
- 更新中英文 README：支持矩阵、配置步骤、已验证能力、私有 ABI 限制和具体故障提示。

## 实施顺序

先完成第 1 阶段的可运行证据，再依次提交设备会话、视频、输入及文档。私有框架放入独立 helper；现有 macOS 14 最低要求保留，新增能力在不满足环境时明确不可用。

## 参考

- Apple 官方介绍：https://developer.apple.com/videos/play/wwdc2026/260/
- Xcode 27 发行说明：https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
- ipb：https://github.com/ipbtools/ipb/
- 镜像源码：https://github.com/ipbtools/ipb/blob/main/Sources/mirror.m
- 镜像能力及限制：https://github.com/ipbtools/ipb/blob/main/docs/mirror.md

## 首版实施记录

- 已集成独立 DeviceBridgeHelper.app，通过 LaunchServices 获取用户图形显示会话；直接启动子进程在本机看到零显示器，会导致 CVDisplayLink / AVConference 1302 错误。
- 已使用当前 USB iPhone 15（iOS 27.0.1）验证 WebSocket 收到连续 1179×2556 真机 JPEG 帧；未自动发送触摸，交互验收由用户进行。
- 首版使用裁剪 JPEG 帧复用网页 0x04 格式，暂不进行 H.264 重编码；输入、会话隔离、多窗口及退出释放已接入。
- 支持 Home、多任务、单指触摸、键盘和文本粘贴；旋转由手机方向驱动，网页旋转按钮暂禁用。
- macOS 构建、JS 语法检查与 diff 空白检查通过。长时间性能、复杂手势、敏感系统 UI 与完整交互仍待验收。

## 原始视频与采集检测验证

已将真机链路改为原始 HEVC 配置及压缩帧转发，跳过 Mac 后端解码和 JPEG 编码。
WebCodecs 在共享网页中完成视频解码；已在 Mac App 的 WKWebView 中确认显示。
示例已增加公开采集 API 检测面板并在 iPhone 15 / iOS 27.0.1 上安装运行。
投屏前 inactive/false，投屏中 active/true，结束后恢复；原始记录与方法见
`device-hub-verification/README.md`。该结果只识别采集状态，不能识别单次触摸来源。

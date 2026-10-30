# 真机验证记录（2026-10-30）

环境：iPhone 15 / iOS 27.0.1，macOS 27.0.1，Xcode 27.0（27A266a）。
示例：com.layerlens.example，使用本机已有的开发配置文件编译、安装并启动。

## 公开采集 API

示例界面新增检测标签，注册 UITraitSceneCaptureState trait 与 UIScreen 捕获通知，
同时每秒轮询并写入 Documents/capture-probe.json。采集 view/window/scene 三层 trait，
以及 UIScreen.isCaptured，避免仅测一个尚未挂载的 trait 环境。
运行期间防止示例前台自动锁屏，离开界面恢复。

| 阶段 | view | window | scene | isCaptured |
|---|---|---|---|---|
| 关闭 Device Hub 和 LayerLens 真机投屏 | 0 | 0 | 0 | false |
| 仅开启 LayerLens 真机投屏，已收到连续帧 | 1 | 1 | 1 | true |
| 关闭 LayerLens 真机投屏 | 0 | 0 | 0 | false |

0=UISceneCaptureStateInactive，1=UISceneCaptureStateActive。
原始记录分别见 capture-before.json、capture-during.json、capture-after.json。
投屏前记录距读取约 0.25 秒，投屏中记录距读取约 0.96 秒，均为前台实时采样。
曾出现手机自动锁屏导致记录不更新的无效采样，未用于上表。
Apple Device Hub 原先也打开着该设备；已退出以排除干扰。

结论：在此设备和系统组合上，App 能通过公开 API 感知 LayerLens 的屏幕采集。
这不能证明每一次触摸是否来自远控，也不能识别控制软件名称。
原始码流版本也已在 Mac App 网页中显示检测面板，采集状态为 active/YES。

## 原始压缩视频

设备协商输出 hvc1.1.6.L150.B0，编码尺寸 1184×2576，实际屏幕 1179×2556。
在自有 helper 的 VideoProcessing/VideoToolbox 解码入口获得 CMSampleBuffer：
其 ImageBuffer 为 NULL，数据为设备编码的长度前缀 HEVC NAL 单元。
配置来自原始 hvcC，关键帧由 HEVC IRAP NAL（16–23）判定；此处样本没有可靠的
NotSync attachment，因此不能依赖 attachment 的默认值判断关键帧。

已验证 WebSocket 连续收到 100 帧：1 个关键帧、99 个增量帧和 1 份配置。
初始关键帧约 49 KB，静态页面增量帧示例约 0.5 KB。此为特定页面样本，不代表性能承诺。
Mac App 的 WKWebView 使用同一 WebCodecs 前端成功显示示例 App，未走 JPEG 转换。

链路：设备媒体流 → 解包后的原始 HEVC 样本 → FIFO → WebSocket → WebCodecs → Canvas。
Mac 后端跳过解码调用，不进行缩放、像素裁剪或视频重编码。
网络解包、解码配置与时间戳封装仍然需要；编码 padding 在网页绘制阶段裁掉。
独立浏览器使用同一页面/协议，本次已验证 WKWebView，未单独验证所有浏览器版本。

后续连续性检查收到 300 帧：1 个关键帧、299 个增量帧和 1 份配置，无 JPEG 帧。
新窗口使用有界 GOP 缓存；如果源端长期不发新关键帧而缓存已超限，新窗口加入时重建共享
媒体会话取得新的源端关键帧，现有窗口会短暂重连。未宣称已实现可靠的源端关键帧请求。

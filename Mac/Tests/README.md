# Mac 回归测试

这些是维护用的回归测试，不是备份或构建产物，不参与 Mac Release，也不进入 Pod 包。
旧 Pod 的兼容行为由 Mac 本地测试服务验证；首次开启前已有 Session 的代理接入由隔离的 Objective-C 测试验证。

## 运行

需要 macOS、Xcode 命令行工具和 Node.js。在仓库根目录执行：

```sh
bash Mac/Tests/run.sh
```

脚本先运行 Objective-C 抓包 hook 测试，再依次编译和运行全部 Swift 测试，最后运行 Node 测试。遇到失败立即停止。
部分测试使用本机回环网络、独立 PTY 和临时 Git 仓库；不操作已连接设备、用户仓库或实际日志/抓包数据。
视频测试使用本机 VideoToolbox 编码器。

所有运行产物位于 `/private/tmp/LayerLens-release-build`，脚本退出时清理本次测试二进制、模块缓存、
事件样本和测试数据目录，不删除同目录下的 Release 构建产物。不要并行运行本套测试或单独运行使用相同临时路径的测试。

## 覆盖范围

| 范围 | 测试 |
| --- | --- |
| Home 原生消息、旧版双击回退、关闭隔离及服务异常 | `SimHomeButtonTests.swift`、`LiveHomeTests.cjs`、`LiveResumeTests.cjs` |
| H.264 编码、丢帧与网页解码 | `LiveVideoTests.swift`、`LiveVideoDecoderTests.cjs` |
| 实时点选定位的像素与 point 换算、缩放旋转及切换目标隔离 | `LiveInspectTests.cjs` |
| 目标选择、前后台状态、共享订阅与扫描竞争 | `TargetStateHubTests.swift`、`TargetSelectionTests.cjs`、`AutoFollowTests.cjs`、`TargetTaskTests.cjs` |
| Git 特殊文件名操作 | `GitPathTests.swift` |
| 发送队列限流、PTY 输入与代理完整性 | `StreamAndPTYTests.swift`、`ProxyTunnelTests.swift` |
| 连接取消、文件句柄、缓存回收与进程退出 | `ConnectionLifecycleTests.swift` |
| 日志写盘、HTTP 截断、抓包保存及释放确认 | `DataIntegrityTests.swift` |
| 旧 Pod 的无序回放和正文复用 | `LegacyNetworkReconnectTests.swift` |
| 首次开启前已有 Session 的代理数据及完成回调 | `NetworkHooksTests.m` |
| 逐条退避、释放确认恢复、设备及进程隔离、断线回放恢复、无定时补查、长请求保护和重启中断 | `NetworkRecorderRecoveryTests.swift` |
| 目标历史无效标识清理、有效记录保留 | `TargetHistoryTests.swift`、`AutoFollowTests.cjs` |
| 日志当前启动隔离、真实流重置、重连续接与历史保存 | `LogLaunchTests.swift` |
| 日志持久清空、重连边界、设备与启动隔离、写盘失败保护 | `LogClearTests.swift` |
| 日志/网络统一确认、历史只读与迟到响应保护 | `RecordClearTests.cjs` |
| 折叠时保留选中行、局部插入和提交高亮 | `GitInteractionTests.cjs` |
| 改动面板完整移组继承、部分暂存独立、已有目标优先、路径稳定与冷启动迁移 | `GitViewStateTests.cjs` |
| 离线清空、清空边界持久化与新请求保护 | `NetworkClearTests.swift` |
| 分页续接、窗口版本、清空、重启和网页同步 | `NetworkReplayTests.swift`、`NetworkViewerEpochTests.swift`、`NetworkViewerWebTests.cjs` |
| 异步状态查询、暂停缓冲和抓包开关 | `NetworkAsyncStateTests.cjs`、`NetworkCaptureActionTests.cjs` |
| Xcode 运行期间前后台跟随、任务隔离、命令超时及多 target 匹配 | `XcodeRunTests.cjs`、`XcodeRunPlanTests.swift`、`ProcessCaptureTests.swift` |

`RecorderTestSupport.swift` 提供隔离的本地 App 服务及接口替身；
`NetworkViewerTestSupport.swift` 提供真实 SSE 查看端。
`NetworkViewerWebTests.cjs` 使用 `NetworkViewerEpochTests.swift` 生成的事件样本，完整脚本已保证执行顺序。

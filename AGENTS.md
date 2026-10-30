# LayerLens 工作约定

## 编译、安装与清理

- 调试和迭代过程中，按需进行语法检查、Debug 编译、运行或测试，不要求每次改动都执行 Release 编译和安装。
- 一次代码任务完成、准备向用户交付最终结果前，统一执行一次 Release 编译、安装、打开验证和清理。若验证后继续修改代码，最终交付前重新执行。
- 用户明确要求“打包”时，也执行完整的 Release 编译和安装流程。仅讨论、调研或修改文档时不触发该流程。
- 使用当前工作区代码，保留用户已有的修改，不擅自回滚、提交或推送。
- 编译命令：

  ```sh
  xcodebuild -project Mac/LayerLens.xcodeproj -scheme LayerLens -configuration Release -derivedDataPath /private/tmp/LayerLens-release-build build
  ```

- 最终安装位置固定为 `/Applications/MyApp/LayerLens.app`。
- 仅在编译成功后替换已安装的应用。先暂存新应用，退出旧应用，保留旧应用作为临时备份；安装失败时恢复备份。
- 安装成功后打开 `/Applications/MyApp/LayerLens.app`，确认应用已运行。
- 完成后清理本次构建目录、构建日志、安装暂存和临时备份，不删除用户数据、日志记录或其他工作文件。
- 临时路径限定为：
  - `/private/tmp/LayerLens-release-build`
  - `/private/tmp/LayerLens-release-build.log`
  - `/private/tmp/LayerLens-install-stage.app`
  - `/private/tmp/LayerLens-install-backup.app`
- 若编译或安装失败，明确报告失败原因，不宣称完成；保留或恢复原先可运行的应用。

# LayerLens

[English](README.md)

在浏览器里查看、修改 iOS 视图层级.

LayerLens 在 Debug 包内运行一个很小的 HTTP 服务, 用电脑浏览器打开日志中的地址即可:

- **层级**: 可搜索的 window / view / layer 树, 标注所属 VC 和 ivar 名
- **2D**: 截图叠加 frame 框, 悬停、点击定位视图
- **3D**: 分层展开, 可旋转、缩放、只看选中子树
- **属性**: 查看并修改 frame、颜色、alpha、hidden、文字等, 修改立即生效
- **类信息**: 整条类链的 ivar (带当前值)、property、method
- **实时** (模拟器): 在浏览器中显示并操作模拟器画面, ⌥ + 点击选中视图
- **运行** (模拟器): 在浏览器中让 Xcode 重新编译运行, 编译错误直接显示在页面上

不需要 Mac 客户端和浏览器插件. 网页是 Pod 内置的 HTML/CSS/JS, 支持中英文.

## 环境要求

- iOS 15+
- CocoaPods
- Chrome 或 Safari (实时画面需要 WebCodecs)
- 实时画面和运行按钮需要在 Mac 上安装 [baguette](https://tddworks.github.io/baguette/), 见 [实时画面与运行](#实时画面与运行)

## 安装

只加到 `Debug` 配置, 调试工具不能进入正式包:

```ruby
pod 'LayerLens', :configurations => ['Debug']
```

然后执行 `pod install`. LookinServer 会作为依赖自动引入, 已经在用 Lookin 的话, Mac 客户端照常可用.

新版 Xcode 不再支持 LookinServer 设置的 iOS 9 最低版本. 编译报 "deployment target ... is set to 9.0" 时, 在 Podfile 中统一调高:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    end
  end
end
```

## 使用

### 方式一: 环境变量, 无需代码

Xcode 中编辑 Scheme › Run › Arguments › Environment Variables, 添加 `LAYERLENS_AUTOSTART` = `1`. App 启动时自动开启, 日志会打印访问地址:

```
[LayerLens] Running at: http://127.0.0.1:9527/
```

### 方式二: 代码

```objc
#if DEBUG
#import <LayerLens/LayerLens.h>
#endif

#if DEBUG
[[LayerLens sharedInstance] start];
#endif
```

然后在运行模拟器的 Mac 上打开 `http://127.0.0.1:9527`. 端口被占用时依次尝试到 9536, 以日志为准.

### 真机

真机只支持通过 USB 连接. 用数据线连接 Mac 后运行 App, 即可在 LayerLens Mac App 中看到, 无需额外配置.

- 不支持 Wi-Fi 连接.
- 实时画面和运行按钮仅支持模拟器.

非 `DEBUG` 编译时 `start` / `startWithLocalNetwork:` 不会启动服务.

## 实时画面与运行

这两项是可选功能, 依赖运行在 Mac 上的三方命令行工具 [baguette](https://tddworks.github.io/baguette/). 它负责推送模拟器画面、转发输入, 并加载 LayerLens 自带的插件 (`BaguettePlugins/layerlens`) 来驱动 Xcode.

安装一次即可:

```sh
brew install baguette
```

LayerLens 会添加一个编译步骤: 模拟器 Debug 编译时自动带上插件在后台启动 baguette, 日志在 `/tmp/baguette.log`. 未安装时跳过, 其他功能不受影响.

手动启动时必须带上插件目录, 否则运行按钮不可用:

```sh
baguette serve --allowed-hosts 127.0.0.1 --plugin-dir <LayerLens 所在路径>/BaguettePlugins
```

退出:

```sh
pkill -f "baguette serve"
```

baguette 启动后会一直在后台运行, 直到手动退出、注销或重启 Mac. 退出 Xcode、停止 App、关闭模拟器都不会让它停止, 之后的编译会直接复用已运行的实例. 升级 LayerLens 后需要退出一次, 下次编译才会加载新插件. 退出后, 下次模拟器编译时会自动重新启动. 网页的快捷键面板 (`?`) 中也可以直接复制这些命令.

### 多个模拟器

- 一个 baguette 服务所有模拟器. 每个运行中的 App 各自启动 LayerLens, 依次占用空闲端口 (9527, 9528, ...), 每个网页只显示和操作自己 App 所在的模拟器.
- 运行按钮始终使用 Xcode 当前的运行目标. 如果目标是另一台模拟器, 本网页的 App 不会重启, 页面会停在「正在编译并重启 App」, 再点一次运行按钮取消跟踪.
- 端口按启动先后分配, 多个 App 重启后同一地址可能对应到另一台模拟器, 需要区分时以页面标题的 App 名和日志为准.

第一次点击运行时, macOS 会询问是否允许控制 Xcode. 如果之前拒绝了, 在 系统设置 › 隐私与安全性 › 自动化 中打开.

## 常见问题

| 网页提示 | 原因 | 处理 |
|---|---|---|
| baguette 未运行 | 未安装或已退出 | 安装后编译一次 |
| baguette 未加载插件 | 手动启动时没带 `--plugin-dir` | 退出后重新编译 |
| Xcode 未打开 | | 在 Xcode 中打开项目 |
| Xcode 中未打开本项目 | Xcode 打开的是其他项目 | 打开这个 App 的工作区 |
| 没有控制 Xcode 的权限 | 自动化权限被拒绝 | 系统设置 › 隐私与安全性 › 自动化 |

- **一直显示「正在编译并重启 App」**: Xcode 的运行目标可能不是当前模拟器, App 不会重启. 再点一次运行按钮取消跟踪.
- **实时画面中点击无效**: 在快捷键面板复制修复命令 (`baguette heal`), 会重启 SpringBoard.
- **编译警告 "baguette is running without the LayerLens plugins"**: 有其他方式启动的 baguette 在运行, 退出后重新编译.

## 实现

- `Classes/Server`: 基于 Network.framework 的 HTTP/1.1 服务, 另有一个事件流让网页感知 App 重启.
- `Classes/Lookin`: 唯一调用 LookinServer 的地方, 由它采集层级、属性和截图. 用到了 LookinServer 的内部类, 因此限定了版本.
- `Classes/Runtime`: 读取类信息的 Objective-C runtime 工具.
- `Assets/web`: 网页, 无构建步骤, 不依赖 CDN.
- `BaguettePlugins/layerlens`: baguette 插件. 网页会传入 App 编译时的源文件路径, 插件据此找到对应的 Xcode 工作区.

## 致谢

- [LookinServer](https://github.com/QMUI/LookinServer) by QMUI
- [baguette](https://tddworks.github.io/baguette/) by tddworks

## 许可

MIT, 见 [LICENSE](LICENSE).

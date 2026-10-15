'use strict';

// 界面语言: 中文原文即 key, 英文环境下查表替换, 查不到时原样显示.
// 设置为 auto 时跟随浏览器语言, 存 localStorage
const LANG_KEY = 'layerlens_lang';

function loadLangSetting() {
  try {
    return localStorage.getItem(LANG_KEY) || 'auto';
  } catch (e) {
    return 'auto';
  }
}

const LANG = (() => {
  const setting = loadLangSetting();
  if (setting === 'zh' || setting === 'en') return setting;
  return (navigator.language || '').toLowerCase().startsWith('zh') ? 'zh' : 'en';
})();

const EN = {
  // 工具栏与菜单
  '未连接': 'Not connected',
  '实时': 'Live',
  '在 Xcode 中运行': 'Run in Xcode',
  '刷新 (R)': 'Refresh (R)',
  '刷新': 'Refresh',
  '视图选项': 'View options',
  '主题': 'Theme',
  '自动': 'Auto',
  '浅色': 'Light',
  '深色': 'Dark',
  '语言': 'Language',
  '快捷键 (?)': 'Shortcuts (?)',
  '快捷键': 'Shortcuts',
  '上一个 / 下一个节点': 'Previous / next node',
  '收起, 再按选中父节点': 'Collapse, again to select parent',
  '展开, 再按进入子节点': 'Expand, again to enter child',
  '双指滑动': 'Two-finger swipe',
  '平移画布': 'Pan canvas',
  '空格': 'Space',
  '平移画布, 也可中键拖动': 'Pan canvas, or middle-button drag',
  '再次点击': 'Click again',
  '选中下面一层': 'Select the layer below',
  '双击': 'Double-click',
  '只看该子树, 双击空白处退出 (3D)': 'Focus on subtree, double-click empty space to exit (3D)',
  '放大选中元素': 'Zoom to selection',
  '实时 / 2D / 3D': 'Live / 2D / 3D',
  '调整层间距 (3D)': 'Adjust layer spacing (3D)',
  '显示 / 隐藏截图 (3D)': 'Show / hide screenshots (3D)',
  '捏合': 'Pinch',
  '缩放, 也可 ⌘ + 滚轮': 'Zoom, or ⌘ + scroll',
  '拖动': 'Drag',
  '旋转 (3D)': 'Rotate (3D)',
  '复制选中节点路径': 'Copy selected node path',
  '右键': 'Right-click',
  '复制菜单': 'Copy menu',
  '显示此面板': 'Show this panel',
  '在 App 内滑动 / 滚动': 'Swipe / scroll in app',
  '点击': 'Click',
  '选中元素并切到 2D': 'Select element and switch to 2D',
  '粘贴到模拟器': 'Paste to simulator',
  '停止向模拟器输入按键': 'Stop sending keys to simulator',

  // 层级与画布
  '搜索类名 / 地址 / ivar': 'Search class / address / ivar',
  '筛选': 'Filter',
  '显示 CALayer': 'Show CALayer',
  '显示隐藏视图': 'Show hidden views',
  '选择元素 (按住 ⌥ 点击)': 'Select element (⌥ + click)',
  '选择元素': 'Select element',
  '适应窗口': 'Fit to window',
  '只看选中子树': 'Selected subtree only',
  '层间距': 'Layer spacing',
  '截图': 'Screenshots',
  '运行': 'Run',
  '正在等待连接…': 'Waiting for connection…',
  '当前浏览器不支持 WebCodecs, 请使用 Chrome 或 Safari': 'This browser does not support WebCodecs, please use Chrome or Safari',
  '实时画面连接已断开': 'Live view disconnected',
  '层级': 'Hierarchy',
  '画布': 'Canvas',
  '详情': 'Details',
  '{0} 节点': '{0} nodes',

  // 详情
  '属性': 'Attributes',
  '类信息': 'Class',
  '选择一个视图': 'Select a view',
  '加载中...': 'Loading...',
  '查看 VC 类信息': 'View VC class info',
  '文字': 'Text',
  '标题': 'Title',
  '特殊': 'Special',
  '地址': 'Address',
  '屏幕坐标': 'Screen rect',
  '可见性': 'Visibility',
  '清除': 'Clear',
  '已修改 {0}': 'Modified {0}',
  '该节点没有对应的 OC 对象': 'This node has no Objective-C object',
  '过滤 ivar / property / method': 'Filter ivar / property / method',
  '类': 'Class',
  '描述': 'Description',
  '返回视图': 'Back to view',
  '在层级中选中': 'Select in hierarchy',

  // 复制
  '复制': 'Copy',
  '复制路径': 'Copy path',
  '复制类名': 'Copy class name',
  '复制成员变量名': 'Copy ivar name',
  '复制层级路径': 'Copy hierarchy path',
  '复制元素信息': 'Copy element info',
  '复制对象地址': 'Copy object address',
  '复制 LLDB 命令': 'Copy LLDB command',
  '已复制路径': 'Copied path',
  '已复制类名': 'Copied class name',
  '已复制成员变量名': 'Copied ivar name',
  '已复制层级路径': 'Copied hierarchy path',
  '已复制元素信息': 'Copied element info',
  '已复制对象地址': 'Copied object address',
  '已复制 LLDB 命令': 'Copied LLDB command',
  '已复制命令': 'Copied command',
  '已复制修复命令, 执行后会重启 SpringBoard': 'Copied fix command, running it restarts SpringBoard',
  '复制失败: {0}': 'Copy failed: {0}',
  '复制元素截图': 'Copy element screenshot',
  '复制屏幕截图': 'Copy screen screenshot',
  '已复制元素截图': 'Copied element screenshot',
  '已复制屏幕截图': 'Copied screen screenshot',
  '当前环境不支持复制图片': 'Copying images is not supported here',
  '暂无画面': 'No frame yet',
  '未选中元素': 'No element selected',
  '触摸似乎没有生效, 修复会结束前台 App': 'Touch does not seem to work. Fixing will quit the foreground app',
  '修复': 'Fix',
  '忽略': 'Ignore',
  '正在修复触摸, 模拟器桌面约 10 秒后恢复': 'Fixing touch, the simulator will be back in about 10 seconds',
  '触摸已修复': 'Touch fixed',
  '修复失败: {0}': 'Fix failed: {0}',
  '修复模拟器触摸…': 'Fix Simulator Touch…',
  '将重启模拟器的 backboardd 与 SpringBoard, 前台 App 会被结束, 约 10 秒后恢复. 继续?': 'This restarts backboardd and SpringBoard in the simulator and quits the foreground app. It takes about 10 seconds. Continue?',

  // 连接与运行状态
  '连接失败': 'Connection failed',
  '连接失败: {0}': 'Connection failed: {0}',
  '获取层级失败: {0}': 'Failed to load hierarchy: {0}',
  '已连接 · 上次刷新 {0}': 'Connected · last refresh {0}',
  '刷新 (R) · 上次 {0}': 'Refresh (R) · last {0}',
  '正在编译并重启 App, 完成后自动刷新': 'Building and restarting app, will refresh when done',
  '已连接, 正在刷新…': 'Connected, refreshing…',
  'App 已重启, 已切换到实时画面': 'App restarted, switched to live view',
  '正在运行… 点击取消跟踪': 'Running… click to stop tracking',
  '运行失败: {0}': 'Run failed: {0}',
  'Xcode 未打开': 'Xcode is not running',
  'Xcode 中未打开本项目': 'This project is not open in Xcode',
  '没有控制 Xcode 的权限, 请在 系统设置 › 隐私与安全性 › 自动化 中允许': 'No permission to control Xcode, allow it in System Settings › Privacy & Security › Automation',
  '运行已取消': 'Run cancelled',
  '编译失败: {0}': 'Build failed: {0}',
  '编译失败, 请在 Xcode 查看': 'Build failed, see Xcode',
  '等待超时, 请在 Xcode 查看': 'Timed out, see Xcode',
  // 设备与 App
  '切换设备 / App': 'Switch device / app',
  '没有运行中的已集成 App': 'No running app with LayerLens',
  '端口 {0}': 'Port {0}',
  '无法连接 LayerLens: {0}': 'Cannot reach LayerLens: {0}',
  '无法连接 LayerLens': 'Cannot reach LayerLens',
  '需要允许 LayerLens 控制 Xcode': 'LayerLens needs permission to control Xcode',
  '请在系统弹窗中允许 LayerLens 控制 Xcode': 'Allow LayerLens to control Xcode in the system dialog',
  '正在连接实时画面…': 'Connecting live view…',
  '无法加载 Xcode 的模拟器框架': 'Unable to load Xcode simulator frameworks',
  '请确认已安装 Xcode, 并用 xcode-select 选中它': 'Make sure Xcode is installed and selected with xcode-select',
  '可用': 'Available',
  '向左旋转': 'Rotate Left',
  '不可用': 'Unavailable',
  '模拟器画面采集与输入注入的实现参考': 'Reference for simulator capture and input injection',
  // 面板与状态提示
  '在浏览器打开': 'Open in Browser',
  '按以下步骤开始使用, 设备连接后会自动打开': 'Follow these steps to get started, it opens automatically when a device connects',
  '集成': 'Integrate',
  '查看': 'Inspect',
  '只在 Debug 下集成, 执行 pod install 即可, 无需代码': 'Debug only, just run pod install, no code needed',
  '在模拟器中运行 App, 或通过 USB 连接真机运行': 'Run the app in a simulator, or on a device connected via USB',
  '2D / 3D 查看视图层级和属性, 模拟器还支持实时画面': 'Inspect view hierarchy and properties in 2D / 3D, simulators also support live view',
  'App 集成…': 'App Integration…',
  '查看集成说明': 'View integration guide',
  '关于 LayerLens': 'About LayerLens',
  '关闭': 'Close',
  'App 集成': 'App Integration',
  '真机不支持实时画面': 'Live view is not available on physical devices',
  '只使用实时画面': 'Live view only',
  '没有发现设备': 'No devices found',
  '版本不兼容': 'Incompatible',
  'App 中的 LayerLens 版本过旧, 部分功能可能不可用, 请更新 Pod': 'The LayerLens pod in this app is outdated, some features may not work. Please update the pod',
  'LayerLens Mac App 版本过旧, 部分功能可能不可用, 请更新 Mac App': 'The LayerLens Mac app is outdated, some features may not work. Please update the Mac app',
  'App 未运行或在后台': 'App not running or in background',
  'App 未运行或在后台, 启动后会自动连接': 'App not running or in background, connects automatically once launched',
  '启动模拟器并运行集成了 LayerLens 的 App, 会自动连接': 'Boot a simulator and run an app with LayerLens integrated, it connects automatically',
  '运行集成了 LayerLens 的 App 后会自动连接, 也可以切换到实时查看模拟器画面': 'Run an app with LayerLens integrated to connect automatically, or switch to Live to view the simulator',
  '运行集成了 LayerLens 的 App 后会自动连接': 'Run an app with LayerLens integrated to connect automatically',
  '已复制': 'Copied',
  '1. 在 Podfile 中添加, 只在 Debug 集成': '1. Add to your Podfile, Debug only',
  '2. 设置最低系统版本': '2. Set the deployment target',
  '依赖的 LookinServer 声明了 iOS 9, 新版 Xcode 已不支持, 在 Podfile 末尾添加:': 'The LookinServer dependency declares iOS 9, which recent Xcode no longer supports. Add this to the end of your Podfile:',
  '3. 安装并运行': '3. Install and run',
  '以 Debug 配置运行 App 即可, 无需编写代码; Release 包不包含 LayerLens.': 'Run the app with the Debug configuration, no code needed. Release builds do not include LayerLens.',
  '4. 确认连接': '4. Verify',
  'Xcode 控制台输出 [LayerLens] Running on port …, 左上角的设备列表中出现该 App.': 'The Xcode console prints [LayerLens] Running on port …, and the app shows up in the device list at the top left.',
  '真机调试': 'Physical devices',
  '模拟器': 'Simulator',
  '设备 (USB)': 'Device (USB)',
  '通过 USB 连接即可使用, 无需额外配置; 暂不支持 Wi-Fi 连接.': 'Works over USB with no extra setup. Wi-Fi is not supported yet.',
  '运行中': 'Running',
  '未运行': 'Not running',
  '版本': 'Version',
  '接口版本': 'API version',
  '当前 App': 'Current app',
  '旧版本': 'outdated',
  'iOS 视图调试工具, 浏览器和 Mac App 使用同一界面': 'iOS view debugger, the same interface in the browser and the Mac app',
  '以 MIT 许可证开源': 'Open source under the MIT License',
  '致谢': 'Acknowledgements',
  '视图层级数据': 'view hierarchy data',
  '模拟器实时画面': 'simulator live view',
};

function t(text, ...args) {
  const value = LANG === 'en' ? EN[text] ?? text : text;
  return value.replace(/\{(\d)\}/g, (_, i) => args[i] ?? '');
}

// 翻译静态 HTML: 含中文的文字节点及 title / aria-label / placeholder 属性
function applyI18n() {
  document.documentElement.lang = LANG === 'en' ? 'en' : 'zh-CN';
  if (LANG !== 'en') return;
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const text = node.nodeValue.trim();
    if (text && /[一-鿿]/.test(text)) node.nodeValue = node.nodeValue.replace(text, t(text));
  }
  document.querySelectorAll('[title], [aria-label], [placeholder]').forEach((node) => {
    ['title', 'aria-label', 'placeholder'].forEach((name) => {
      if (node.hasAttribute(name)) node.setAttribute(name, t(node.getAttribute(name)));
    });
  });
}

// 切换语言后重新加载, 不做逐个控件的实时切换
function setLang(setting) {
  try {
    localStorage.setItem(LANG_KEY, setting);
  } catch (e) {
    // 无痕模式等场景下不可用, 忽略
  }
  location.reload();
}

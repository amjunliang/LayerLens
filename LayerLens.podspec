Pod::Spec.new do |spec|
  spec.name         = "LayerLens"
  spec.version      = "0.6.0"
  spec.summary      = "Inspect, edit and explore your iOS view hierarchy from the LayerLens Mac app or your browser."
  spec.description  = <<-DESC
  LayerLens runs a tiny HTTP server inside your debug build. The LayerLens Mac app discovers simulators and
  devices automatically and lets you browse the view hierarchy, inspect and edit properties, read class info
  and explore layers in 3D, in its window or in any browser. Built on LookinServer.
  DESC
  spec.homepage     = "https://github.com/amjunliang/LayerLens"
  spec.license      = { :type => "MIT", :file => "LICENSE" }
  spec.author       = { "YueYou" => "YueYou" }
  spec.platform     = :ios, "15.0"
  spec.source       = { :git => "https://github.com/amjunliang/LayerLens.git", :tag => spec.version.to_s }
  spec.requires_arc = true

  spec.source_files        = "Pod/Classes/**/*.{h,m}"
  spec.public_header_files = "Pod/Classes/LayerLens.h"
  spec.frameworks          = "UIKit", "Network", "UniformTypeIdentifiers"
  # 沙盒浏览: 打包 zip 用到 crc32, 预览 SQLite 数据库
  spec.libraries           = "z", "sqlite3"

  # 使用了 LookinServer 的内部类, 限定在已验证的版本范围内
  spec.dependency "LookinServer", "~> 1.2.8"

  # Lookin 头文件整体包在 SHOULD_COMPILE_LOOKIN_SERVER 中, 该宏只定义在 LookinServer target 上
  spec.pod_target_xcconfig = {
    "GCC_PREPROCESSOR_DEFINITIONS" => "$(inherited) SHOULD_COMPILE_LOOKIN_SERVER=1"
  }
end

//
//  SimulatorKeyboard.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation

/// 网页 KeyboardEvent.code 与修饰键到 HID 键盘页用法码的映射, 以及模拟器剪贴板写入
enum SimulatorKeyboard {
    /// 按住时长: 太短 iOS 可能收不到, 太长会触发长按重复
    static let holdMicroseconds: useconds_t = 30_000

    static let modifiers: [String: UInt32] = ["control": 0xE0, "shift": 0xE1, "option": 0xE2, "command": 0xE3]

    static let codes: [String: UInt32] = {
        var map: [String: UInt32] = [
            "Enter": 0x28, "Escape": 0x29, "Backspace": 0x2A, "Tab": 0x2B, "Space": 0x2C,
            "Minus": 0x2D, "Equal": 0x2E, "BracketLeft": 0x2F, "BracketRight": 0x30, "Backslash": 0x31,
            "Semicolon": 0x33, "Quote": 0x34, "Backquote": 0x35, "Comma": 0x36, "Period": 0x37, "Slash": 0x38,
            "ArrowRight": 0x4F, "ArrowLeft": 0x50, "ArrowDown": 0x51, "ArrowUp": 0x52,
        ]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            map["Key\(c)"] = UInt32(0x04 + i)
        }
        // HID 数字键顺序为 1~9, 0
        for i in 1...9 {
            map["Digit\(i)"] = UInt32(0x1E + i - 1)
        }
        map["Digit0"] = 0x27
        return map
    }()

    /// 按下修饰键 -> 按下并松开主键 -> 倒序松开修饰键
    @discardableResult
    static func press(code: String, modifiers names: [String], on touch: SimTouch) -> Bool {
        guard let usage = codes[code] else { return false }
        let held = names.compactMap { modifiers[$0] }
        for modifier in held {
            touch.sendKey(usage: modifier, down: true)
        }
        let pressed = touch.sendKey(usage: usage, down: true)
        usleep(holdMicroseconds)
        touch.sendKey(usage: usage, down: false)
        for modifier in held.reversed() {
            touch.sendKey(usage: modifier, down: false)
        }
        return pressed
    }

    /// 写入模拟器剪贴板. Xcode 27 的 simctl pbcopy 返回成功但不生效, 先用 devicectl, 不支持时退回 simctl
    static func setPasteboard(_ text: String, udid: String) -> Bool {
        let payload = Data(text.utf8)
        return run(["devicectl", "device", "pasteboard", "copy", "--device", udid], input: payload)
            || run(["simctl", "pbcopy", udid], input: payload)
    }

    private static func run(_ arguments: [String], input: Data) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        pipe.fileHandleForWriting.write(input)
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

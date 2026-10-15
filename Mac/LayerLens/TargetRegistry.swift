//
//  TargetRegistry.swift
//  LayerLens
//
//  Created by YueYou on 10/15/26.
//  Copyright © 2026 YueYou. Released under the MIT License.
//

import Foundation
import Network

/// 与 iOS App 建立连接的方式
enum TargetEndpoint {
    /// 模拟器与 Mac 共用回环地址
    case local(port: UInt16)
    /// USB 真机, 经 usbmuxd 连接设备回环地址上的端口
    case usb(deviceId: Int, port: UInt16)

    var port: UInt16 {
        switch self {
        case .local(let port), .usb(_, let port):
            return port
        }
    }

    var connectionType: String {
        switch self {
        case .local:
            return "simulator"
        case .usb:
            return "usb"
        }
    }
}

enum DeviceKind: String {
    case simulator
    case device
}

struct DeviceRecord {
    let id: String
    let kind: DeviceKind
    let name: String
    let os: String
    /// 机型, 如 iPhone 15; 真机名称是用户自定义的, 需要另外显示机型
    var model = ""
}

struct AppRecord {
    let deviceId: String
    let bundleId: String
    let endpoint: TargetEndpoint
    /// iOS 端 /api/app 的原始内容
    let info: [String: Any]
}

/// 定时发现模拟器和集成了 LayerLens 的 App, 所有状态只在 queue 上读写
final class TargetRegistry {
    /// 与 iOS 端 Pod 的端口范围保持一致
    static let appPorts: ClosedRange<UInt16> = 9527...9536
    static let refreshInterval: TimeInterval = 2
    /// 真机 App 连续偶发失败(超时等)达到该次数才移除, 明确拒绝连接时立即移除
    static let usbMissLimit = 3

    private let queue = DispatchQueue(label: "com.layerlens.registry")
    private let session: URLSession
    private var timer: DispatchSourceTimer?
    private var simulators: [DeviceRecord] = []
    private var usbDevices: [Usbmux.Device] = []
    /// UDID -> devicectl 查到的名称和系统版本, 每台设备只查一次
    private var deviceDetails: [String: (name: String, os: String, model: String)] = [:]
    private var detailsLoading: Set<String> = []
    private var apps: [AppRecord] = []
    /// "UDID|Bundle ID" -> 真机 App 连续偶发失败的次数
    private var usbMisses: [String: Int] = [:]
    private var scanning = false
    private var scanWaiters: [() -> Void] = []
    /// Bundle ID -> 编译时源文件路径, App 未运行时也能据此让 Xcode 运行
    private var sourceFiles: [String: String]
    private static let sourceFilesKey = "LayerLensSourceFiles"

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        sourceFiles = UserDefaults.standard.dictionary(forKey: Self.sourceFilesKey) as? [String: String] ?? [:]
    }

    /// 本机的配对身份, 设备上按此记住允许的 Mac
    func sourceFile(bundleId: String) -> String {
        queue.sync { sourceFiles[bundleId] ?? "" }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.refreshInterval)
        timer.setEventHandler { [weak self] in
            self?.refreshSimulators()
            self?.refreshUSBDevices()
            self?.scanApps(completion: nil)
        }
        timer.resume()
        self.timer = timer
    }

    /// 找到 App 当前的连接方式; 未找到时立即重新扫描一次, 以便 App 刚重启时不必等下个周期
    func resolve(deviceId: String, bundleId: String, completion: @escaping (TargetEndpoint?) -> Void) {
        queue.async { [self] in
            if let app = findApp(deviceId: deviceId, bundleId: bundleId) {
                completion(app.endpoint)
                return
            }
            scanApps { [self] in
                completion(findApp(deviceId: deviceId, bundleId: bundleId)?.endpoint)
            }
        }
    }

    /// 设备列表, 供网页展示; 每台设备附带其上运行的 App
    func snapshot(completion: @escaping ([[String: Any]]) -> Void) {
        queue.async { [self] in
            var devices = simulators + usbDevices.map { usbRecord($0) }
            // 未出现在 simctl / usbmuxd 结果中的设备(刷新时机不同)补上
            for app in apps where !devices.contains(where: { $0.id == app.deviceId }) {
                if case .local = app.endpoint {
                    devices.append(DeviceRecord(id: app.deviceId, kind: .simulator, name: app.info["deviceName"] as? String ?? "", os: app.info["os"] as? String ?? ""))
                } else {
                    let details = deviceDetails[app.deviceId]
                    let name = details?.name.nonEmpty ?? app.info["deviceName"] as? String ?? "iPhone"
                    let os = details?.os.nonEmpty ?? app.info["os"] as? String ?? ""
                    devices.append(DeviceRecord(id: app.deviceId, kind: .device, name: name, os: os, model: details?.model ?? ""))
                }
            }
            let result: [[String: Any]] = devices.map { device in
                let deviceApps = apps
                    .filter { $0.deviceId == device.id }
                    .sorted { ($0.info["appName"] as? String ?? "") < ($1.info["appName"] as? String ?? "") }
                    .map { app -> [String: Any] in
                        var info = app.info
                        info["port"] = app.endpoint.port
                        info["connection"] = app.endpoint.connectionType
                        return info
                    }
                return ["id": device.id, "kind": device.kind.rawValue, "name": device.name, "os": device.os, "model": device.model, "apps": deviceApps]
            }
            completion(result)
        }
    }

    // MARK: - Simulators

    private func refreshSimulators() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let devices = Self.bootedSimulators()
            self?.queue.async {
                self?.simulators = devices
            }
        }
    }

    /// 解析 `simctl list devices booted -j`, 运行时标识形如 com.apple.CoreSimulator.SimRuntime.iOS-26-5
    private static func bootedSimulators() -> [DeviceRecord] {
        guard let data = run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "-j"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else {
            return []
        }
        var result: [DeviceRecord] = []
        for (runtime, devices) in runtimes {
            let parts = (runtime.components(separatedBy: "SimRuntime.").last ?? runtime).split(separator: "-")
            let os = parts.isEmpty ? runtime : "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
            for device in devices where device["state"] as? String == "Booted" {
                guard let udid = device["udid"] as? String else { continue }
                result.append(DeviceRecord(id: udid, kind: .simulator, name: device["name"] as? String ?? udid, os: os))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    // MARK: - USB devices

    private func refreshUSBDevices() {
        Usbmux.listDevices(queue: queue) { [weak self] devices in
            // 偶发请求失败时沿用上次结果, 避免设备上的 App 被清空
            guard let self, let devices else { return }
            self.usbDevices = devices
            devices.filter { self.deviceDetails[$0.udid] == nil && !self.detailsLoading.contains($0.udid) }.forEach { self.loadDetails(udid: $0.udid) }
        }
    }

    /// 名称优先取 devicectl, 其次取设备上 App 上报的名称
    private func usbRecord(_ device: Usbmux.Device) -> DeviceRecord {
        let app = apps.first { $0.deviceId == device.udid }
        let details = deviceDetails[device.udid]
        let name = details?.name.nonEmpty ?? app?.info["deviceName"] as? String ?? "iPhone"
        let os = details?.os.nonEmpty ?? app?.info["os"] as? String ?? ""
        return DeviceRecord(id: device.udid, kind: .device, name: name, os: os, model: details?.model ?? "")
    }

    private func loadDetails(udid: String) {
        detailsLoading.insert(udid)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let details = Self.devicectlDetails()
            self?.queue.async {
                guard let self else { return }
                self.detailsLoading.remove(udid)
                self.deviceDetails.merge(details) { _, new in new }
                // 查不到(如 Xcode 版本过旧)时记为空, 不再重复查询
                if self.deviceDetails[udid] == nil {
                    self.deviceDetails[udid] = ("", "", "")
                }
            }
        }
    }

    /// 解析 `devicectl list devices --json-output`, 只能输出到文件
    private static func devicectlDetails() -> [String: (name: String, os: String, model: String)] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("layerlens-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--quiet", "--json-output", file.path]) != nil,
              let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = (json["result"] as? [String: Any])?["devices"] as? [[String: Any]] else {
            return [:]
        }
        var result: [String: (name: String, os: String, model: String)] = [:]
        for device in devices {
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            guard let udid = hardware["udid"] as? String, let name = properties["name"] as? String else { continue }
            let version = properties["osVersionNumber"] as? String ?? ""
            let platform = hardware["platform"] as? String ?? "iOS"
            result[udid] = (name, version.isEmpty ? "" : "\(platform) \(version)", hardware["marketingName"] as? String ?? "")
        }
        return result
    }

    // MARK: - Apps

    private func findApp(deviceId: String, bundleId: String) -> AppRecord? {
        apps.first { $0.deviceId == deviceId && $0.bundleId == bundleId }
    }

    /// 并发请求端口范围内每个端口的 /api/app; 扫描进行中时合并到同一次扫描
    private func scanApps(completion: (() -> Void)?) {
        if let completion {
            scanWaiters.append(completion)
        }
        guard !scanning else { return }
        scanning = true
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [AppRecord] = []
        // 偶发失败(非明确拒绝)的真机端口, 用于判断是否保留上次结果
        var transientPorts: Set<String> = []
        let devices = usbDevices
        for device in devices {
            for port in Self.appPorts {
                group.enter()
                Self.fetchUSBAppInfo(deviceId: device.id, port: port, queue: queue) { info, refused in
                    defer { group.leave() }
                    lock.lock()
                    defer { lock.unlock() }
                    guard let info, let bundleId = info["bundleId"] as? String else {
                        if !refused {
                            transientPorts.insert("\(device.udid)|\(port)")
                        }
                        return
                    }
                    found.append(AppRecord(deviceId: device.udid, bundleId: bundleId, endpoint: .usb(deviceId: device.id, port: port), info: info))
                }
            }
        }
        for port in Self.appPorts {
            guard let url = URL(string: "http://127.0.0.1:\(port)/api/app") else { continue }
            group.enter()
            session.dataTask(with: url) { data, response, _ in
                defer { group.leave() }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let bundleId = info["bundleId"] as? String,
                      let udid = info["simulatorUDID"] as? String, !udid.isEmpty else {
                    return
                }
                lock.lock()
                found.append(AppRecord(deviceId: udid, bundleId: bundleId, endpoint: .local(port: port), info: info))
                lock.unlock()
            }.resume()
        }
        group.notify(queue: queue) { [self] in
            apps = found + retainedUSBApps(found: found, devices: devices, transientPorts: transientPorts)
            rememberSourceFiles()
            scanning = false
            let waiters = scanWaiters
            scanWaiters = []
            waiters.forEach { $0() }
        }
    }

    /// 上次找到但本次偶发失败的真机 App 暂时保留, 避免列表闪烁
    private func retainedUSBApps(found: [AppRecord], devices: [Usbmux.Device], transientPorts: Set<String>) -> [AppRecord] {
        var retained: [AppRecord] = []
        var misses: [String: Int] = [:]
        for app in apps {
            guard case .usb(let deviceId, let port) = app.endpoint,
                  devices.contains(where: { $0.id == deviceId }),
                  !found.contains(where: { $0.deviceId == app.deviceId && $0.bundleId == app.bundleId }),
                  transientPorts.contains("\(app.deviceId)|\(port)") else {
                continue
            }
            let key = "\(app.deviceId)|\(app.bundleId)"
            let count = (usbMisses[key] ?? 0) + 1
            if count < Self.usbMissLimit {
                misses[key] = count
                retained.append(app)
            }
        }
        usbMisses = misses
        return retained
    }

    private func rememberSourceFiles() {
        var changed = false
        for app in apps {
            if let file = app.info["sourceFile"] as? String, !file.isEmpty, sourceFiles[app.bundleId] != file {
                sourceFiles[app.bundleId] = file
                changed = true
            }
        }
        if changed {
            UserDefaults.standard.set(sourceFiles, forKey: Self.sourceFilesKey)
        }
    }

    /// 经 usbmuxd 请求设备上的 /api/app; refused 表示该端口无人监听
    private static func fetchUSBAppInfo(deviceId: Int, port: UInt16, queue: DispatchQueue, completion: @escaping (_ info: [String: Any]?, _ refused: Bool) -> Void) {
        Usbmux.connect(deviceId: deviceId, port: port, queue: queue) { connection, refused in
            guard let connection else {
                completion(nil, refused)
                return
            }
            let request = HTTPClient.request(method: "GET", path: "/api/app", host: "127.0.0.1:\(port)")
            HTTPClient.exchange(request, on: connection, queue: queue, timeout: 2) { response in
                completion(response?.status == 200 ? response?.json : nil, false)
            }
        }
    }

    // MARK: - Helpers

    static func run(_ path: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

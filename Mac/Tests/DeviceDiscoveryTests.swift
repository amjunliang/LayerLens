import Foundation

enum AppLogRecorder { static func savedApps() -> [String: Set<String>] { [:] } }
enum NetworkRecorder { static func savedApps() -> [String: Set<String>] { [:] } }

@main struct DeviceDiscoveryTests {
    static func main() {
        testUsbmuxParsing()
        testDeviceControlParsing()
        print("PASS usbmux and devicectl physical device discovery parsing")
    }

    private static func testUsbmuxParsing() {
        precondition(Usbmux.parseDevices(from: [:]) == nil)
        let reply: [String: Any] = [
            "DeviceList": [
                [
                    "DeviceID": 3,
                    "Properties": [
                        "ConnectionType": "Network",
                        "SerialNumber": "00008120001A54820A12201E",
                    ],
                ],
                [
                    "DeviceID": 4,
                    "Properties": [
                        "ConnectionType": "USB",
                        "SerialNumber": "00008130001C40240EB9401C",
                    ],
                ],
                [
                    "DeviceID": 7,
                    "Properties": [
                        "ConnectionType": "USB",
                        "SerialNumber": "00008130001C40240EB9401C",
                    ],
                ],
                [
                    "Properties": [
                        "DeviceID": 2,
                        "ConnectionType": "USB",
                        "SerialNumber": "a1b2c3d4e5f60708091011121314151617181920",
                    ],
                ],
            ]
        ]
        let devices = Usbmux.parseDevices(from: reply)
        precondition(devices == [
            Usbmux.Device(id: 2, udid: "a1b2c3d4e5f60708091011121314151617181920"),
            Usbmux.Device(id: 7, udid: "00008130-001C40240EB9401C"),
        ], "Unexpected parsed usbmux devices: \(String(describing: devices))")
    }

    private static func testDeviceControlParsing() {
        let payload: [String: Any] = [
            "result": [
                "devices": [
                    [
                        "hardwareProperties": [
                            "reality": "simulated",
                            "udid": "SIM-1",
                            "marketingName": "iPhone 17 Pro",
                            "platform": "iOS",
                        ],
                        "deviceProperties": [
                            "name": "iPhone 17 Pro",
                            "osVersionNumber": "26.5",
                        ],
                        "connectionProperties": [
                            "transportType": "sameMachine",
                        ],
                    ],
                    [
                        "hardwareProperties": [
                            "reality": "physical",
                            "udid": "00008130-001C40240EB9401C",
                            "marketingName": "iPhone 15 Pro Max",
                            "platform": "iOS",
                        ],
                        "deviceProperties": [
                            "name": "iPhone 4S",
                            "osVersionNumber": "27.0.1",
                        ],
                        "connectionProperties": [
                            "transportType": "wired",
                        ],
                    ],
                    [
                        "properties": [
                            "hardware": [
                                "reality": "physical",
                                "udid": "00008120-001A54820A12201E",
                                "marketingName": "iPhone 15",
                                "platform": "iOS",
                            ],
                            "software": [
                                "osVersionNumber": [
                                    "stringValue": "27.2",
                                ],
                            ],
                            "state": [
                                "name": "港版15",
                            ],
                            "connection": [
                                "transportType": "localNetwork",
                            ],
                        ],
                    ],
                ],
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let snapshot = TargetRegistry.parseDeviceControlJSON(data)
        precondition(snapshot != nil)
        precondition(snapshot?.details["00008130-001C40240EB9401C"] ?? ("", "", "") == ("iPhone 4S", "iOS 27.0.1", "iPhone 15 Pro Max"))
        precondition(snapshot?.details["00008120-001A54820A12201E"] ?? ("", "", "") == ("港版15", "iOS 27.2", "iPhone 15"))
        precondition(snapshot?.details["SIM-1"] == nil)
        precondition(snapshot?.wired == [
            DeviceRecord(id: "00008130-001C40240EB9401C", kind: .device, name: "iPhone 4S", os: "iOS 27.0.1", model: "iPhone 15 Pro Max"),
        ], "Unexpected wired devices: \(String(describing: snapshot?.wired))")
    }
}

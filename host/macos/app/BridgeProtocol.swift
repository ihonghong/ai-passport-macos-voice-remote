import Foundation

struct ShortcutChord: Decodable, Equatable {
    var modifiers: [String]
    var key: ShortcutKey?

    enum ShortcutKey: Decodable, Equatable {
        case name(String)
        case usage(UInt8)

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() {
                self = .usage(0)
            } else if let name = try? value.decode(String.self) {
                self = .name(name)
            } else {
                let usage = try value.decode(Int.self)
                guard (0...0x65).contains(usage) else {
                    throw DecodingError.dataCorruptedError(
                        in: value,
                        debugDescription: "HID usage must be between 0 and 101"
                    )
                }
                self = .usage(UInt8(usage))
            }
        }
    }
}

struct ButtonConfiguration: Decodable, Equatable {
    var up: ShortcutChord
    var mid: ShortcutChord
    var down: ShortcutChord

    private enum CodingKeys: String, CodingKey {
        case up
        case mid
        case down
        case ok
    }

    init(up: ShortcutChord, mid: ShortcutChord, down: ShortcutChord) {
        self.up = up
        self.mid = mid
        self.down = down
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        up = try values.decode(ShortcutChord.self, forKey: .up)
        if let configured = try values.decodeIfPresent(ShortcutChord.self, forKey: .mid) {
            mid = configured
        } else {
            mid = try values.decode(ShortcutChord.self, forKey: .ok)
        }
        down = try values.decode(ShortcutChord.self, forKey: .down)
    }
}

private struct LegacyShortcutConfiguration: Decodable {
    var voice: ShortcutChord
    var send: ShortcutChord
    var clear: ShortcutChord
}

struct ProviderConfiguration: Decodable, Equatable {
    var name: String
    var settings: [String: JSONValue]
}

enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([String: JSONValue].self) { self = .object(decoded) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
}

struct AppConfiguration: Decodable, Equatable {
    var deviceName: String
    var audioDevice: String
    var buttons: ButtonConfiguration
    var provider: ProviderConfiguration

    enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
        case audioDevice = "audio_device"
        case buttons
        case shortcuts
        case provider
    }

    init(
        deviceName: String,
        audioDevice: String,
        buttons: ButtonConfiguration,
        provider: ProviderConfiguration
    ) {
        self.deviceName = deviceName
        self.audioDevice = audioDevice
        self.buttons = buttons
        self.provider = provider
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceName = try values.decodeIfPresent(String.self, forKey: .deviceName)
            ?? Self.defaults.deviceName
        audioDevice = try values.decodeIfPresent(String.self, forKey: .audioDevice)
            ?? Self.defaults.audioDevice
        provider = try values.decodeIfPresent(ProviderConfiguration.self, forKey: .provider)
            ?? Self.defaults.provider
        if let physical = try values.decodeIfPresent(ButtonConfiguration.self, forKey: .buttons) {
            buttons = physical
        } else if let legacy = try values.decodeIfPresent(
            LegacyShortcutConfiguration.self, forKey: .shortcuts
        ) {
            buttons = ButtonConfiguration(
                up: legacy.clear, mid: legacy.send, down: legacy.voice
            )
        } else {
            buttons = Self.defaults.buttons
        }
    }

    static let defaults = AppConfiguration(
        deviceName: "AI Passport",
        audioDevice: "BlackHole 2ch",
        buttons: ButtonConfiguration(
            up: ShortcutChord(modifiers: ["left_command"], key: .name("delete")),
            mid: ShortcutChord(modifiers: [], key: .name("return")),
            down: ShortcutChord(
                modifiers: ["left_control", "left_command"], key: .usage(0)
            )
        ),
        provider: ProviderConfiguration(name: "none", settings: [:])
    )

    static func load(from url: URL) throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return .defaults }
        return try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
    }
}

enum PassportProtocol {
    static let audioReportID: UInt8 = 2
    static let hostStatusReportID: UInt8 = 3
    static let audioReportBytes = 176
    static let hostStatusEpoch = DateComponents(
        calendar: Calendar(identifier: .gregorian),
        timeZone: TimeZone(secondsFromGMT: 0),
        year: 2020, month: 1, day: 1
    ).date!

    static func outputReportFrame(_ payload: Data) -> Data {
        var report = Data([hostStatusReportID])
        report.append(payload)
        return report
    }

    static let modifierUsages: [String: UInt8] = [
        "left_control": 0x01,
        "left_shift": 0x02,
        "left_option": 0x04,
        "left_command": 0x08,
        "right_control": 0x10,
        "right_shift": 0x20,
        "right_option": 0x40,
        "right_command": 0x80,
    ]

    static let keyUsages: [String: UInt8] = [
        "return": 0x28,
        "escape": 0x29,
        "delete": 0x2A,
        "space": 0x2C,
    ]

    static func crc8(_ bytes: some Sequence<UInt8>) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }

    static func encode(_ chord: ShortcutChord, button: String) throws -> (UInt8, UInt8) {
        var modifiers: UInt8 = 0
        for name in chord.modifiers {
            guard let value = modifierUsages[name] else {
                throw BridgeError.invalidConfiguration("Unsupported \(button) modifier: \(name)")
            }
            modifiers |= value
        }
        let key: UInt8
        switch chord.key ?? .usage(0) {
        case .usage(let value): key = value
        case .name(let name):
            guard let value = keyUsages[name] else {
                throw BridgeError.invalidConfiguration("Unsupported \(button) key: \(name)")
            }
            key = value
        }
        guard modifiers != 0 || key != 0 else {
            throw BridgeError.invalidConfiguration("Button \(button) cannot be empty")
        }
        return (modifiers, key)
    }

    static func keymapPayload(_ buttons: ButtonConfiguration) throws -> Data {
        var bytes: [UInt8] = [Character("K").asciiValue!]
        // Preserve the v1 wire order: DOWN, MID, UP.
        for (name, chord) in [
            ("down", buttons.down), ("mid", buttons.mid), ("up", buttons.up)
        ] {
            let encoded = try encode(chord, button: name)
            bytes.append(contentsOf: [encoded.0, encoded.1])
        }
        bytes.append(crc8(bytes))
        return Data(bytes)
    }

    static func hostStatusPayload(
        audioReady: Bool,
        remainingPercent: Int? = nil,
        dailyTotal: Int? = nil,
        date: Date = Date(),
        calendar sourceCalendar: Calendar = .current
    ) -> Data {
        let calendar = sourceCalendar
        let start = calendar.startOfDay(for: hostStatusEpoch)
        let current = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let currentDay = calendar.date(from: current) ?? date
        let days = min(0x3FFF, max(0, calendar.dateComponents([.day], from: start, to: currentDay).day ?? 0))
        let minutes = (current.hour ?? 0) * 60 + (current.minute ?? 0)
        let remaining = min(100, max(0, remainingPercent ?? 0x7F))
        let daily = dailyTotal.map { min(126, max(0, Int((Double($0) / 10_000_000).rounded()))) } ?? 0x7F
        var packed = UInt64(days)
        packed |= UInt64(minutes) << 14
        packed |= UInt64(audioReady ? 1 : 0) << 25
        packed |= UInt64(remaining) << 26
        packed |= UInt64(daily) << 33
        var bytes: [UInt8] = [0xA5, Character("A").asciiValue!, Character("D").asciiValue!]
        for offset in 0..<5 { bytes.append(UInt8(truncatingIfNeeded: packed >> (offset * 8))) }
        return Data(bytes)
    }

    static func parseAudioReport(_ data: Data) throws -> AudioPacket {
        guard data.count >= 4 else { throw BridgeError.invalidAudioPacket("Short HID report") }
        let bytes = [UInt8](data)
        let payloadBytes = Int(bytes[3])
        guard payloadBytes <= audioReportBytes - 4, data.count >= 4 + payloadBytes else {
            throw BridgeError.invalidAudioPacket("Invalid payload length")
        }
        return AudioPacket(
            type: bytes[0],
            sequence: UInt16(bytes[1]) | UInt16(bytes[2]) << 8,
            payload: Data(bytes[4..<(4 + payloadBytes)])
        )
    }
}

struct AudioPacket {
    let type: UInt8
    let sequence: UInt16
    let payload: Data
}

enum BridgeError: LocalizedError {
    case invalidConfiguration(String)
    case invalidAudioPacket(String)
    case audioDeviceMissing(String)
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail), .invalidAudioPacket(let detail): return detail
        case .audioDeviceMissing(let name): return "No Core Audio output device matching \(name)"
        case .coreAudio(let operation, let status): return "\(operation) failed (\(status))"
        }
    }
}

final class PCMResampler {
    private let factor: Int
    private var previous: Int16?

    init(inputRate: Int) throws {
        guard inputRate == 8_000 || inputRate == 16_000 else {
            throw BridgeError.invalidAudioPacket("Unsupported sample rate: \(inputRate)")
        }
        factor = 48_000 / inputRate
    }

    func convert(_ input: Data, bitsPerSample: Int) throws -> Data {
        let samples: [Int16]
        if bitsPerSample == 8 {
            samples = input.map { Int16(Int8(bitPattern: $0)) << 8 }
        } else if bitsPerSample == 16 {
            guard input.count.isMultiple(of: 2) else {
                throw BridgeError.invalidAudioPacket("PCM16 payload has an odd byte count")
            }
            let bytes = [UInt8](input)
            samples = stride(from: 0, to: bytes.count, by: 2).map {
                Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
            }
        } else {
            throw BridgeError.invalidAudioPacket("Unsupported PCM bit depth")
        }
        guard !samples.isEmpty else { return Data() }
        var output = Data(capacity: samples.count * factor * 4)
        var last = previous ?? samples[0]
        for sample in samples {
            for step in 0..<factor {
                let value = Int16(
                    (Int(factor - step) * Int(last) + Int(step) * Int(sample)) / factor
                )
                var littleEndian = value.littleEndian
                withUnsafeBytes(of: &littleEndian) {
                    output.append(contentsOf: $0)
                    output.append(contentsOf: $0)
                }
            }
            last = sample
        }
        previous = last
        return output
    }
}

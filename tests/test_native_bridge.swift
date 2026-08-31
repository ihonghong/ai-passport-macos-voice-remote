import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private struct NativeBridgeTests {
    static func main() throws {
        let keymap = try PassportProtocol.keymapPayload(AppConfiguration.defaults.buttons)
        require(keymap.map { String(format: "%02x", $0) }.joined() == "4b09000028082ac3",
                "native keymap must match the Python/firmware contract")
        require(PassportProtocol.outputReportFrame(keymap).map {
            String(format: "%02x", $0)
        }.joined() == "034b09000028082ac3",
                "IOKit output reports must include their report ID byte")

        let physical = try JSONDecoder().decode(AppConfiguration.self, from: Data("""
        {"buttons":{"up":{"modifiers":[],"key":"escape"},"mid":{"modifiers":[],"key":"space"},"down":{"modifiers":["left_shift"],"key":null}}}
        """.utf8))
        require(physical.buttons.up.key == .name("escape"),
                "public configuration must bind the physical Up button")
        require(physical.buttons.down.modifiers == ["left_shift"],
                "public configuration must bind the physical Down button")
        require(physical.buttons.mid.key == .name("space"),
                "public configuration must bind the physical middle button")

        let legacyPhysical = try JSONDecoder().decode(AppConfiguration.self, from: Data("""
        {"buttons":{"up":{"modifiers":[],"key":"escape"},"down":{"modifiers":["left_shift"],"key":null},"ok":{"modifiers":[],"key":"return"}}}
        """.utf8))
        require(legacyPhysical.buttons.mid.key == .name("return"),
                "buttons.ok must migrate to buttons.mid")

        let legacy = try JSONDecoder().decode(AppConfiguration.self, from: Data("""
        {"shortcuts":{"voice":{"modifiers":["left_control"],"key":null},"send":{"modifiers":[],"key":"return"},"clear":{"modifiers":[],"key":"escape"}}}
        """.utf8))
        require(legacy.buttons.down.modifiers == ["left_control"] &&
                legacy.buttons.mid.key == .name("return") &&
                legacy.buttons.up.key == .name("escape"),
                "legacy semantic configuration must migrate to Down, Mid, and Up")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 31, hour: 12, minute: 34
        ))!
        let status = PassportProtocol.hostStatusPayload(
            audioReady: true, remainingPercent: 42, dailyTotal: 31_000_000,
            date: date, calendar: calendar
        )
        require(status.map { String(format: "%02x", $0) }.joined() == "a541448289bcaa06",
                "native host status must match the Python/firmware contract")
        require(PassportProtocol.outputReportFrame(status).map {
            String(format: "%02x", $0)
        }.joined() == "03a541448289bcaa06",
                "native status output must include report ID 3")

        let packet = try PassportProtocol.parseAudioReport(Data([
            2, 0x34, 0x12, 3, 1, 2, 3,
        ]))
        require(packet.type == 2 && packet.sequence == 0x1234 && packet.payload == Data([1, 2, 3]),
                "wireless audio packet parsing")

        let resampler = try PCMResampler(inputRate: 16_000)
        let output = try resampler.convert(Data([0, 0, 0xff, 0x7f]), bitsPerSample: 16)
        require(output.count == 2 * 3 * 2 * 2, "16 kHz mono must become 48 kHz stereo")
        require(CodexMetrics.readDailyTokens() >= 0, "daily token total cannot be negative")

        print("Native Bridge protocol tests: PASS")
    }
}

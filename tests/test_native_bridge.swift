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
        let keymap = try PassportProtocol.keymapPayload(AppConfiguration.defaults.shortcuts)
        require(keymap.map { String(format: "%02x", $0) }.joined() == "4b09000028082ac3",
                "native keymap must match the Python/firmware contract")

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

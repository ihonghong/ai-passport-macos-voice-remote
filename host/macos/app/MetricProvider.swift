import Foundation

struct MetricSnapshot: Equatable {
    var remainingPercent: Int?
    var dailyTotal: Int?

    static let unknown = MetricSnapshot(remainingPercent: nil, dailyTotal: nil)
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        if case .string(let value)? = self[key] { return value }
        return nil
    }

    func number(_ key: String) -> Double? {
        if case .number(let value)? = self[key] { return value }
        return nil
    }
}

final class MetricMonitor {
    var onSnapshot: ((MetricSnapshot) -> Void)?

    private let configuration: ProviderConfiguration
    private let queue = DispatchQueue(label: "com.aipassport.metrics", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(configuration: ProviderConfiguration) {
        self.configuration = configuration
    }

    func start() {
        guard timer == nil, configuration.name != "none" else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let refresh = max(5, configuration.settings.number("refresh_seconds") ?? 300)
        timer.schedule(deadline: .now(), repeating: refresh)
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func refresh() {
        guard configuration.name == "codex" || configuration.name == "auto" else {
            return
        }
        let snapshot = MetricSnapshot(
            remainingPercent: CodexMetrics.readRemaining(
                executable: configuration.settings.string("executable"),
                timeout: configuration.settings.number("timeout_seconds") ?? 10
            ),
            dailyTotal: CodexMetrics.readDailyTokens()
        )
        DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
    }
}

enum CodexMetrics {
    static func readRemaining(executable: String?, timeout: TimeInterval) -> Int? {
        guard let command = resolveCodex(executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        var pending = Data()
        var result: Int?
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   object["id"] as? Int == 2,
                   let remaining = remainingPercent(from: object) {
                    result = remaining
                    semaphore.signal()
                    break
                }
            }
            lock.unlock()
        }

        do {
            try process.run()
            let requests: [[String: Any]] = [
                [
                    "id": 1, "method": "initialize",
                    "params": [
                        "clientInfo": [
                            "name": "ai-passport-app",
                            "title": "AI Passport",
                            "version": "1.0.0",
                        ],
                    ],
                ],
                ["method": "initialized", "params": [:]],
                ["id": 2, "method": "account/rateLimits/read", "params": [:]],
            ]
            for request in requests {
                let data = try JSONSerialization.data(withJSONObject: request)
                input.fileHandleForWriting.write(data)
                input.fileHandleForWriting.write(Data([0x0A]))
            }
            _ = semaphore.wait(timeout: .now() + timeout)
        } catch {
            result = nil
        }
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        lock.lock()
        let snapshot = result
        lock.unlock()
        return snapshot
    }

    static func readDailyTokens(now: Date = Date()) -> Int {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? NSString(string: "~/.codex").expandingTildeInPath)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"

        var candidates = Set<URL>()
        for day in [today, yesterday] {
            let sessionDirectory = root.appendingPathComponent("sessions")
                .appendingPathComponent(formatter.string(from: day))
            if let entries = try? fileManager.contentsOfDirectory(
                at: sessionDirectory, includingPropertiesForKeys: nil
            ) {
                candidates.formUnion(entries.filter { $0.pathExtension == "jsonl" })
            }
        }
        let archived = root.appendingPathComponent("archived_sessions")
        if let entries = try? fileManager.contentsOfDirectory(
            at: archived, includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            candidates.formUnion(entries.filter { url in
                guard url.pathExtension == "jsonl" else { return false }
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                return modified.map { $0 >= today } ?? false
            })
        }
        let sessions = root.appendingPathComponent("sessions")
        if let enumerator = fileManager.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                if modified.map({ $0 >= today }) ?? false { candidates.insert(url) }
            }
        }

        return candidates.reduce(into: 0) { total, url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                total += tokenDelta(record: record, day: today, calendar: calendar)
            }
        }
    }

    private static func resolveCodex(_ explicit: String?) -> String? {
        if let explicit, FileManager.default.isExecutableFile(atPath: explicit) { return explicit }
        let environment = ProcessInfo.processInfo.environment
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let path = String(directory) + "/codex"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let fallback = NSString(string: "~/.local/bin/codex").expandingTildeInPath
        return FileManager.default.isExecutableFile(atPath: fallback) ? fallback : nil
    }

    private static func remainingPercent(from message: [String: Any]) -> Int? {
        guard let result = message["result"] as? [String: Any] else { return nil }
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        let snapshot = (byID?["codex"] as? [String: Any])
            ?? (result["rateLimits"] as? [String: Any])
        guard let primary = snapshot?["primary"] as? [String: Any],
              let used = primary["usedPercent"] as? Int
        else { return nil }
        return min(100, max(0, 100 - used))
    }

    private static func tokenDelta(
        record: [String: Any], day: Date, calendar: Calendar
    ) -> Int {
        guard record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let timestamp = record["timestamp"] as? String,
              let date = ISO8601DateFormatter().date(from: timestamp),
              calendar.isDate(date, inSameDayAs: day),
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any],
              let total = usage["total_tokens"] as? Int
        else { return 0 }
        return max(0, total)
    }
}

import CoreFoundation
import Foundation
import IOKit.hid

enum NativeBridgeState: Equatable {
    case waiting(String)
    case connected(String)
    case recording(String)
    case error(String)
    case stopped
}

final class NativeBridge {
    var onStateChange: ((NativeBridgeState) -> Void)?

    private let configuration: AppConfiguration
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var reportBuffers: [ObjectIdentifier: UnsafeMutablePointer<UInt8>] = [:]
    private var statusTimer: Timer?
    private var audioSink: NativeAudioSink?
    private var resampler: PCMResampler?
    private var bitsPerSample: Int?
    private var expectedSequence: UInt16?
    private var metricSnapshot = MetricSnapshot.unknown
    private var metricMonitor: MetricMonitor?
    private(set) var isRunning = false

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    deinit { stop() }

    func start() {
        guard !isRunning else { return }
        do {
            _ = try PassportProtocol.keymapPayload(configuration.buttons)
            audioSink = try NativeAudioSink(deviceName: configuration.audioDevice)
        } catch {
            publish(.error(error.localizedDescription))
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let matching: [String: Any] = [
            // IOHIDManager matches top-level usage pairs, while macOS keeps
            // the composite device's primary usage as Keyboard.
            kIOHIDDeviceUsagePageKey as String: 0xFF00,
            kIOHIDDeviceUsageKey as String: 1,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nativeDeviceMatched, opaqueSelf)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nativeDeviceRemoved, opaqueSelf)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            cleanupManager()
            if result == kIOReturnNotPermitted {
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                publish(.error(
                    "Grant AI Passport Input Monitoring permission, then restart the App"
                ))
            } else {
                publish(.error("Unable to open macOS HID manager (\(result))"))
            }
            return
        }
        isRunning = true
        publish(.waiting("Waiting for \(configuration.deviceName)"))
        let metricMonitor = MetricMonitor(configuration: configuration.provider)
        metricMonitor.onSnapshot = { [weak self] snapshot in
            self?.metricSnapshot = snapshot
            self?.sendHostStatus(audioReady: self?.device != nil)
        }
        self.metricMonitor = metricMonitor
        metricMonitor.start()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] _ in self?.sendHostStatus(audioReady: true)
        }
    }

    func stop() {
        guard manager != nil || audioSink != nil else { return }
        statusTimer?.invalidate()
        statusTimer = nil
        metricMonitor?.stop()
        metricMonitor = nil
        if device != nil { sendHostStatus(audioReady: false) }
        if let device { close(device) }
        self.device = nil
        cleanupManager()
        audioSink?.close()
        audioSink = nil
        resampler = nil
        isRunning = false
        publish(.stopped)
    }

    fileprivate func matched(_ device: IOHIDDevice) {
        guard self.device == nil, matches(device) else { return }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            publish(.error("Unable to open \(configuration.deviceName) HID (\(result))"))
            return
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: PassportProtocol.audioReportBytes)
        reportBuffers[ObjectIdentifier(device)] = buffer
        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, PassportProtocol.audioReportBytes, nativeInputReport, opaqueSelf
        )
        self.device = device
        publish(.connected(configuration.audioDevice))

        do {
            try sendKeymap()
        } catch {
            publish(.error(error.localizedDescription))
            return
        }
        // Firmware polls Output Report 3 every 500 ms. Preserve the ordering
        // used by the proven Python bridge so keymap and status cannot race.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak device] in
            guard let self, let device, self.device === device else { return }
            self.sendHostStatus(audioReady: true)
        }
    }

    fileprivate func removed(_ device: IOHIDDevice) {
        guard self.device === device else { return }
        close(device)
        self.device = nil
        resampler = nil
        bitsPerSample = nil
        expectedSequence = nil
        publish(.waiting("Waiting for \(configuration.deviceName)"))
    }

    fileprivate func received(reportID: UInt32, bytes: UnsafePointer<UInt8>, count: Int) {
        guard reportID == PassportProtocol.audioReportID else { return }
        do {
            let packet = try PassportProtocol.parseAudioReport(Data(bytes: bytes, count: count))
            switch packet.type {
            case 1: try startAudio(packet.payload)
            case 2: try receiveAudio(packet)
            case 3:
                expectedSequence = nil
                publish(.connected(configuration.audioDevice))
            default: break
            }
        } catch {
            publish(.error(error.localizedDescription))
        }
    }

    private var opaqueSelf: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private func matches(_ device: IOHIDDevice) -> Bool {
        guard let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString)
                as? String,
              product.caseInsensitiveCompare(configuration.deviceName) == .orderedSame
        else { return false }
        if let primary = IOHIDDeviceGetProperty(
            device, kIOHIDPrimaryUsagePageKey as CFString
        ) as? NSNumber, primary.intValue == 0xFF00 {
            return true
        }
        guard let usagePairs = IOHIDDeviceGetProperty(
            device, kIOHIDDeviceUsagePairsKey as CFString
        ) as? [[String: Any]] else { return false }
        return usagePairs.contains { pair in
            (pair[kIOHIDDeviceUsagePageKey as String] as? NSNumber)?.intValue == 0xFF00
        }
    }

    private func startAudio(_ payload: Data) throws {
        let bytes = [UInt8](payload)
        guard bytes.count >= 5, bytes[0] == 1 else {
            throw BridgeError.invalidAudioPacket("Unsupported wireless audio format")
        }
        let sampleRate = Int(bytes[1]) | Int(bytes[2]) << 8
        let bitDepth = Int(bytes[3])
        guard bytes[4] == 1, bitDepth == 8 || bitDepth == 16 else {
            throw BridgeError.invalidAudioPacket("Unsupported PCM parameters")
        }
        resampler = try PCMResampler(inputRate: sampleRate)
        bitsPerSample = bitDepth
        expectedSequence = nil
        audioSink?.startSegment()
        publish(.recording("\(sampleRate) Hz/\(bitDepth)-bit/mono"))
    }

    private func receiveAudio(_ packet: AudioPacket) throws {
        guard let resampler, let bitsPerSample else { return }
        expectedSequence = packet.sequence &+ 1
        audioSink?.write(try resampler.convert(packet.payload, bitsPerSample: bitsPerSample))
    }

    private func sendKeymap() throws {
        guard let device else { return }
        let payload = try PassportProtocol.keymapPayload(configuration.buttons)
        try setOutputReport(device: device, payload: payload)
    }

    private func sendHostStatus(audioReady: Bool) {
        guard let device else { return }
        do {
            try setOutputReport(
                device: device,
                payload: PassportProtocol.hostStatusPayload(
                    audioReady: audioReady,
                    remainingPercent: metricSnapshot.remainingPercent,
                    dailyTotal: metricSnapshot.dailyTotal
                )
            )
        } catch {
            publish(.error(error.localizedDescription))
        }
    }

    private func setOutputReport(device: IOHIDDevice, payload: Data) throws {
        let report = PassportProtocol.outputReportFrame(payload)
        let result = report.withUnsafeBytes { raw -> IOReturn in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(
                device, kIOHIDReportTypeOutput,
                CFIndex(PassportProtocol.hostStatusReportID), base, report.count
            )
        }
        guard result == kIOReturnSuccess else {
            throw BridgeError.invalidAudioPacket("Unable to write HID report (\(result))")
        }
    }

    private func close(_ device: IOHIDDevice) {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if let buffer = reportBuffers.removeValue(forKey: ObjectIdentifier(device)) {
            buffer.deallocate()
        }
    }

    private func cleanupManager() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        for buffer in reportBuffers.values { buffer.deallocate() }
        reportBuffers.removeAll()
    }

    private func publish(_ state: NativeBridgeState) {
        let name: String
        let detail: String
        switch state {
        case .waiting(let value): (name, detail) = ("waiting", value)
        case .connected(let value): (name, detail) = ("connected", value)
        case .recording(let value): (name, detail) = ("recording", value)
        case .error(let value): (name, detail) = ("error", value)
        case .stopped: (name, detail) = ("stopped", "Bridge stopped")
        }
        NSLog("AI Passport bridge state: %@: %@", name, detail)
        let statusURL = URL(fileURLWithPath: NSString(
            string: "~/Library/Application Support/AI Passport Bridge/status.json"
        ).expandingTildeInPath)
        let status: [String: Any] = [
            "state": name,
            "detail": detail,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "updated_at": Date().timeIntervalSince1970,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status) {
            try? data.write(to: statusURL, options: .atomic)
        }
        if Thread.isMainThread { onStateChange?(state) }
        else { DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) } }
    }
}

private let nativeDeviceMatched: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<NativeBridge>.fromOpaque(context).takeUnretainedValue().matched(device)
}

private let nativeDeviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<NativeBridge>.fromOpaque(context).takeUnretainedValue().removed(device)
}

private let nativeInputReport: IOHIDReportCallback = {
    context, _, _, _, reportID, report, reportLength in
    guard let context else { return }
    Unmanaged<NativeBridge>.fromOpaque(context).takeUnretainedValue().received(
        reportID: reportID, bytes: report, count: reportLength
    )
}

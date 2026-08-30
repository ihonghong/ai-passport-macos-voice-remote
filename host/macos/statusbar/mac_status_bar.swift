import AppKit
import CoreAudio
import Darwin
import Foundation

private struct BridgeStatus: Decodable {
    let state: String
    let detail: String
    let pid: Int32
    let updated_at: Double
}

private struct BridgeConfig: Decodable {
    let audio_device: String?
}

private func configuredAudioDeviceName() -> String {
    let path = NSString(
        string: "~/Library/Application Support/AI Passport Bridge/config.json"
    ).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path),
          let config = try? JSONDecoder().decode(BridgeConfig.self, from: data),
          let name = config.audio_device?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty
    else { return "BlackHole 2ch" }
    return name
}

private final class AudioInputManager {
    let virtualInputName: String
    private let previousUIDKey = "previousPhysicalInputUID"

    init(virtualInputName: String = configuredAudioDeviceName()) {
        self.virtualInputName = virtualInputName
    }

    private func propertyString(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            device, &address, 0, nil, &size, &value
        ) == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private func propertyUInt32(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            device, &address, 0, nil, &size, &value
        ) == noErr else { return nil }
        return value
    }

    private func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            device, &address, 0, nil, &size
        ) == noErr, size > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(
            device, &address, 0, nil, &size, list
        ) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(list).contains {
            $0.mNumberChannels > 0
        }
    }

    private func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        var result = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &result
        ) == noErr else { return [] }
        return result.filter(hasInput)
    }

    private func defaultDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &device
        ) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    var defaultInputName: String? {
        guard let device = defaultDevice() else { return nil }
        return propertyString(device: device, selector: kAudioObjectPropertyName)
    }

    var passportModeEnabled: Bool {
        defaultInputName == virtualInputName
    }

    private func setDefault(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var selected = device
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            size, &selected
        ) == noErr
    }

    func selectPassportMode() -> Bool {
        let inputs = devices()
        if let current = defaultDevice(),
           propertyString(device: current, selector: kAudioObjectPropertyName) != virtualInputName,
           let uid = propertyString(
               device: current,
               selector: kAudioDevicePropertyDeviceUID
           ) {
            UserDefaults.standard.set(uid, forKey: previousUIDKey)
        }
        guard let virtualInput = inputs.first(where: {
            propertyString(device: $0, selector: kAudioObjectPropertyName) == virtualInputName
        }) else { return false }
        return setDefault(virtualInput)
    }

    func selectMeetingMode() -> Bool {
        let inputs = devices().filter {
            propertyString(device: $0, selector: kAudioObjectPropertyName) != virtualInputName
        }
        if let previousUID = UserDefaults.standard.string(forKey: previousUIDKey),
           let previous = inputs.first(where: {
               propertyString(device: $0, selector: kAudioDevicePropertyDeviceUID) == previousUID
           }) {
            return setDefault(previous)
        }
        if let builtIn = inputs.first(where: {
            propertyUInt32(
                device: $0,
                selector: kAudioDevicePropertyTransportType
            ) == kAudioDeviceTransportTypeBuiltIn
        }) {
            return setDefault(builtIn)
        }
        guard let fallback = inputs.first else { return false }
        return setDefault(fallback)
    }
}

@MainActor
private final class StatusAppDelegate: NSObject, NSApplicationDelegate {
    private let statusPath = NSString(
        string: "~/Library/Application Support/AI Passport Bridge/status.json"
    ).expandingTildeInPath
    private let logPath = NSString(
        string: "~/Library/Logs/AI Passport Bridge.log"
    ).expandingTildeInPath
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.squareLength
    )
    private let stateItem = NSMenuItem(title: "正在读取状态…", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let passportModeItem = NSMenuItem(
        title: "AI Passport 输入",
        action: #selector(selectPassportMode),
        keyEquivalent: ""
    )
    private let meetingModeItem = NSMenuItem(
        title: "会议输入（物理麦克风）",
        action: #selector(selectMeetingMode),
        keyEquivalent: ""
    )
    private let bridgeToggleItem = NSMenuItem(
        title: "关闭音频桥",
        action: #selector(toggleBridge),
        keyEquivalent: ""
    )
    private let audioInputs = AudioInputManager()
    private let resumePassportInputKey = "resumePassportInputWhenConnected"
    private let inputPolicyInitializedKey = "connectionInputPolicyInitialized"
    private var bridgeIsAlive = false
    private var deviceIsConnected = false
    private var connectionStateIsKnown = false
    private var timer: Timer?

    private var resumePassportInputWhenConnected: Bool {
        get { UserDefaults.standard.bool(forKey: resumePassportInputKey) }
        set { UserDefaults.standard.set(newValue, forKey: resumePassportInputKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Preserve the mode selected before this connection-aware policy was
        // installed. Future disconnects temporarily restore a physical input
        // without forgetting that the user wanted Passport mode while online.
        if !UserDefaults.standard.bool(forKey: inputPolicyInitializedKey) {
            resumePassportInputWhenConnected = audioInputs.passportModeEnabled
            UserDefaults.standard.set(true, forKey: inputPolicyInitializedKey)
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        stateItem.isEnabled = false
        detailItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(detailItem)
        menu.addItem(.separator())

        for item in [passportModeItem, meetingModeItem] {
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        }
        menu.addItem(.separator())

        bridgeToggleItem.target = self
        bridgeToggleItem.isEnabled = true
        menu.addItem(bridgeToggleItem)

        let openLog = NSMenuItem(
            title: "打开运行日志",
            action: #selector(openLogFile),
            keyEquivalent: ""
        )
        openLog.target = self
        openLog.isEnabled = true

        let restart = NSMenuItem(
            title: "重新启动音频桥",
            action: #selector(restartBridge),
            keyEquivalent: ""
        )
        restart.target = self
        restart.isEnabled = true
        menu.addItem(restart)
        menu.addItem(openLog)
        statusItem.menu = menu

        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatus()
            }
        }
    }

    private func setIcon(statusColor: NSColor, tooltip: String) {
        guard let button = statusItem.button else { return }
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.labelColor.setStroke()
        let card = NSBezierPath(
            roundedRect: NSRect(x: 1.5, y: 2.5, width: 16, height: 13),
            xRadius: 2.5,
            yRadius: 2.5
        )
        card.lineWidth = 1.4
        card.stroke()

        let label = "AI" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 7.5, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]
        let labelSize = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(
                x: (size.width - labelSize.width) / 2 - 0.3,
                y: (size.height - labelSize.height) / 2 - 0.5
            ),
            withAttributes: attributes
        )

        statusColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 14.2, y: 12.0, width: 4.2, height: 4.2)).fill()
        image.unlockFocus()
        image.isTemplate = false
        button.image = image
        button.toolTip = tooltip
    }

    private func refreshStatus() {
        func refreshModeItems() {
            passportModeItem.state = audioInputs.passportModeEnabled ? .on : .off
            meetingModeItem.state = audioInputs.passportModeEnabled ? .off : .on
        }

        func applyInputPolicy(connected: Bool) {
            let justConnected = !connectionStateIsKnown || connected != deviceIsConnected
            deviceIsConnected = connected
            connectionStateIsKnown = true

            if connected {
                if justConnected && resumePassportInputWhenConnected &&
                    !audioInputs.passportModeEnabled {
                    _ = audioInputs.selectPassportMode()
                }
            } else if audioInputs.passportModeEnabled {
                // BlackHole remains available even when the board is offline.
                // Restore the last physical microphone so other applications
                // do not silently keep recording from an empty virtual input.
                _ = audioInputs.selectMeetingMode()
            }
            refreshModeItems()
        }

        guard let data = FileManager.default.contents(atPath: statusPath),
              let status = try? JSONDecoder().decode(BridgeStatus.self, from: data)
        else {
            bridgeIsAlive = false
            applyInputPolicy(connected: false)
            stateItem.title = "AI Passport：状态未知"
            detailItem.title = "尚未收到桥接状态"
            setIcon(statusColor: .secondaryLabelColor, tooltip: "AI Passport 状态未知")
            return
        }

        let processAlive = kill(status.pid, 0) == 0 || errno == EPERM
        bridgeIsAlive = processAlive
        bridgeToggleItem.title = processAlive ? "关闭音频桥" : "开启音频桥"
        if !processAlive {
            applyInputPolicy(connected: false)
            stateItem.title = "AI Passport：桥接未运行"
            detailItem.title = "launchd 正在尝试恢复"
            setIcon(statusColor: .systemOrange, tooltip: "AI Passport 桥接未运行")
            return
        }

        switch status.state {
        case "connected":
            applyInputPolicy(connected: true)
            stateItem.title = "AI Passport：已连接"
            detailItem.title = status.detail
            setIcon(statusColor: .systemGreen, tooltip: "AI Passport 已连接")
        case "recording":
            applyInputPolicy(connected: true)
            stateItem.title = "AI Passport：正在录音"
            detailItem.title = status.detail
            setIcon(statusColor: .systemRed, tooltip: "AI Passport 正在录音")
        case "waiting":
            applyInputPolicy(connected: false)
            stateItem.title = "AI Passport：等待设备"
            detailItem.title = status.detail
            setIcon(statusColor: .secondaryLabelColor, tooltip: "AI Passport 等待设备")
        case "error":
            applyInputPolicy(connected: false)
            stateItem.title = "AI Passport：桥接错误"
            detailItem.title = status.detail
            setIcon(statusColor: .systemOrange, tooltip: "AI Passport 桥接错误")
        default:
            applyInputPolicy(connected: false)
            stateItem.title = "AI Passport：已停止"
            detailItem.title = status.detail
            setIcon(statusColor: .secondaryLabelColor, tooltip: "AI Passport 已停止")
        }
    }

    @objc private func openLogFile() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc private func restartBridge() {
        if !bridgeIsAlive {
            startBridge()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "kickstart", "-k", "gui/\(getuid())/com.aipassport.bridge"
        ]
        try? process.run()
        stateItem.title = "AI Passport：正在重启…"
        detailItem.title = "请稍候"
    }

    @objc private func selectPassportMode() {
        resumePassportInputWhenConnected = true
        if deviceIsConnected && !audioInputs.selectPassportMode() {
            stateItem.title = "AI Passport：无法切换输入"
            detailItem.title = "没有找到 \(audioInputs.virtualInputName)"
        } else if !deviceIsConnected {
            stateItem.title = "AI Passport：等待设备"
            detailItem.title = "连接后将自动启用 Passport 输入"
        }
        refreshStatus()
    }

    @objc private func selectMeetingMode() {
        resumePassportInputWhenConnected = false
        if !audioInputs.selectMeetingMode() {
            stateItem.title = "AI Passport：无法切换输入"
            detailItem.title = "没有找到可用的物理麦克风"
        }
        refreshStatus()
    }

    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private func startBridge() {
        let domain = "gui/\(getuid())"
        _ = runLaunchctl(["enable", "\(domain)/com.aipassport.bridge"])
        let plist = NSString(
            string: "~/Library/LaunchAgents/com.aipassport.bridge.plist"
        ).expandingTildeInPath
        _ = runLaunchctl(["bootstrap", domain, plist])
        _ = runLaunchctl(["kickstart", "-k", "\(domain)/com.aipassport.bridge"])
    }

    @objc private func toggleBridge() {
        let domain = "gui/\(getuid())"
        if bridgeIsAlive {
            _ = runLaunchctl(["bootout", "\(domain)/com.aipassport.bridge"])
        } else {
            startBridge()
        }
        refreshStatus()
    }
}

@main
private struct PassportStatusApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--print-default-input") {
            print(AudioInputManager().defaultInputName ?? "unknown")
            return
        }
        let app = NSApplication.shared
        let delegate = StatusAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

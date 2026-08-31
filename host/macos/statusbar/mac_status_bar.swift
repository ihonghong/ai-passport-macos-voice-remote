import AppKit
import CoreAudio
import Darwin
import Foundation
import ServiceManagement

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

    var virtualInputAvailable: Bool {
        devices().contains {
            propertyString(device: $0, selector: kAudioObjectPropertyName) == virtualInputName
        }
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
    private let configURL = URL(fileURLWithPath: NSString(
        string: "~/Library/Application Support/AI Passport Bridge/config.json"
    ).expandingTildeInPath)
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
    private let loginItem = NSMenuItem(
        title: "登录时自动启动",
        action: #selector(toggleLoginItem),
        keyEquivalent: ""
    )
    private let installBlackHoleItem = NSMenuItem(
        title: "安装 BlackHole 2ch…",
        action: #selector(openBlackHoleInstallPage),
        keyEquivalent: ""
    )
    private let audioInputs = AudioInputManager()
    private let resumePassportInputKey = "resumePassportInputWhenConnected"
    private let inputPolicyInitializedKey = "connectionInputPolicyInitialized"
    private let blackHolePromptKey = "didShowBlackHoleInstallPrompt"
    private let blackHoleInstallURL = URL(string: "https://existential.audio/blackhole/")!
    private var bridgeIsAlive = false
    private var deviceIsConnected = false
    private var connectionStateIsKnown = false
    private var timer: Timer?
    private var nativeBridge: NativeBridge?

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
        loginItem.target = self
        loginItem.isEnabled = true
        menu.addItem(loginItem)
        installBlackHoleItem.target = self
        installBlackHoleItem.isEnabled = true
        menu.addItem(installBlackHoleItem)

        let openConfig = NSMenuItem(
            title: "打开配置文件",
            action: #selector(openConfigFile),
            keyEquivalent: ""
        )
        openConfig.target = self
        openConfig.isEnabled = true

        let restart = NSMenuItem(
            title: "应用最新配置（重启音频桥）",
            action: #selector(restartBridge),
            keyEquivalent: ""
        )
        restart.target = self
        restart.isEnabled = true
        menu.addItem(restart)
        menu.addItem(openConfig)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "退出 AI Passport",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)
        statusItem.menu = menu

        refreshLoginItem()
        if !UserDefaults.standard.bool(forKey: "didRequestLoginItem") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didRequestLoginItem")
            refreshLoginItem()
        }

        refreshBlackHoleAvailability(showAlert: true)
        startNativeBridge(reloadConfiguration: true)
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
        bridgeIsAlive = nativeBridge?.isRunning == true
        bridgeToggleItem.title = bridgeIsAlive ? "关闭音频桥" : "开启音频桥"
        refreshBlackHoleAvailability(showAlert: false)
        refreshModeItems()
    }

    private func refreshBlackHoleAvailability(showAlert: Bool) {
        let available = audioInputs.virtualInputAvailable
        installBlackHoleItem.isHidden = available
        if available {
            UserDefaults.standard.set(false, forKey: blackHolePromptKey)
            return
        }
        guard showAlert,
              !UserDefaults.standard.bool(forKey: blackHolePromptKey)
        else { return }
        UserDefaults.standard.set(true, forKey: blackHolePromptKey)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无线麦克风需要 BlackHole 2ch"
        alert.informativeText = "BlackHole 2ch 是 AI Passport 把无线音频提供给听写应用所需的虚拟麦克风。安装完成后，请按安装提示重启 Mac，再打开 AI Passport。"
        alert.addButton(withTitle: "打开官方安装页面")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(blackHoleInstallURL)
        }
    }

    private func refreshModeItems() {
        passportModeItem.state = audioInputs.passportModeEnabled ? .on : .off
        meetingModeItem.state = audioInputs.passportModeEnabled ? .off : .on
    }

    private func applyInputPolicy(connected: Bool) {
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
            // Restore the last physical microphone so other applications do
            // not silently keep recording from an empty virtual input.
            _ = audioInputs.selectMeetingMode()
        }
        refreshModeItems()
    }

    private func applyNativeState(_ state: NativeBridgeState) {
        bridgeIsAlive = nativeBridge?.isRunning == true
        bridgeToggleItem.title = bridgeIsAlive ? "关闭音频桥" : "开启音频桥"
        switch state {
        case .connected(let detail):
            applyInputPolicy(connected: true)
            stateItem.title = "AI Passport：已连接"
            detailItem.title = detail
            setIcon(statusColor: .systemGreen, tooltip: "AI Passport 已连接")
        case .recording(let detail):
            applyInputPolicy(connected: true)
            stateItem.title = "AI Passport：正在录音"
            detailItem.title = detail
            setIcon(statusColor: .systemRed, tooltip: "AI Passport 正在录音")
        case .waiting(let detail):
            applyInputPolicy(connected: false)
            stateItem.title = "AI Passport：等待设备"
            detailItem.title = detail
            setIcon(statusColor: .secondaryLabelColor, tooltip: "AI Passport 等待设备")
        case .error(let detail):
            applyInputPolicy(connected: false)
            stateItem.title = "AI Passport：桥接错误"
            detailItem.title = detail
            setIcon(statusColor: .systemOrange, tooltip: "AI Passport 桥接错误")
        case .stopped:
            applyInputPolicy(connected: false)
            stateItem.title = "AI Passport：已停止"
            detailItem.title = "音频桥已关闭"
            setIcon(statusColor: .secondaryLabelColor, tooltip: "AI Passport 已停止")
        }
    }

    @objc private func openConfigFile() {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            do {
                try FileManager.default.createDirectory(
                    at: configURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if let example = Bundle.main.url(
                    forResource: "config.example", withExtension: "json"
                ) {
                    try FileManager.default.copyItem(at: example, to: configURL)
                }
            } catch {
                stateItem.title = "AI Passport：无法创建配置"
                detailItem.title = error.localizedDescription
                return
            }
        }
        NSWorkspace.shared.open(configURL)
    }

    @objc private func openBlackHoleInstallPage() {
        NSWorkspace.shared.open(blackHoleInstallURL)
    }

    @objc private func restartBridge() {
        startNativeBridge(reloadConfiguration: true)
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

    private func refreshLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            stateItem.title = "AI Passport：启动项设置失败"
            detailItem.title = error.localizedDescription
        }
        refreshLoginItem()
    }

    @objc private func quitApp() {
        nativeBridge?.stop()
        NSApp.terminate(nil)
    }

    private func startNativeBridge(reloadConfiguration: Bool) {
        if reloadConfiguration || nativeBridge == nil {
            nativeBridge?.stop()
            do {
                let bridge = NativeBridge(
                    configuration: try AppConfiguration.load(from: configURL)
                )
                bridge.onStateChange = { [weak self] state in
                    self?.applyNativeState(state)
                }
                nativeBridge = bridge
            } catch {
                nativeBridge = nil
                applyNativeState(.error(error.localizedDescription))
                return
            }
        }
        nativeBridge?.start()
    }

    @objc private func toggleBridge() {
        if nativeBridge?.isRunning == true { nativeBridge?.stop() }
        else { startNativeBridge(reloadConfiguration: true) }
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
        if CommandLine.arguments.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
            return
        }
        if let option = CommandLine.arguments.firstIndex(of: "--validate-config"),
           CommandLine.arguments.indices.contains(option + 1) {
            do {
                _ = try AppConfiguration.load(
                    from: URL(fileURLWithPath: CommandLine.arguments[option + 1])
                )
                print("Configuration: PASS")
            } catch {
                FileHandle.standardError.write(Data("Configuration: \(error)\n".utf8))
                exit(1)
            }
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

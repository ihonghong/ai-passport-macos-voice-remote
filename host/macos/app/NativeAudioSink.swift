import AudioToolbox
import AudioUnit
import CoreAudio
import Foundation

private func audioPropertyString(
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
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
          let value
    else { return nil }
    return value.takeUnretainedValue() as String
}

private func outputDevices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    ) == noErr else { return [] }
    var devices = [AudioDeviceID](
        repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size
    )
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
    ) == noErr else { return [] }
    return devices.filter { device in
        var streams = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamBytes: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamBytes) == noErr
            && streamBytes >= MemoryLayout<AudioStreamID>.size
    }
}

final class NativeAudioSink {
    private let lock = NSLock()
    private var queued = Data()
    private var audioUnit: AudioUnit?
    private let maximumQueuedBytes = 48_000 * 4 / 2

    init(deviceName: String) throws {
        guard let device = outputDevices().first(where: {
            audioPropertyString(device: $0, selector: kAudioObjectPropertyName)?
                .localizedCaseInsensitiveContains(deviceName) == true
        }) else { throw BridgeError.audioDeviceMissing(deviceName) }

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw BridgeError.coreAudio("Find HAL output", -1)
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "Create HAL output")
        guard let unit else { throw BridgeError.coreAudio("Create HAL output", -1) }
        audioUnit = unit

        do {
            var enabled: UInt32 = 1
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &enabled, UInt32(MemoryLayout<UInt32>.size)
            ), "Enable HAL output")
            var disabled: UInt32 = 0
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                &disabled, UInt32(MemoryLayout<UInt32>.size)
            ), "Disable HAL input")

            var selected = device
            try check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &selected, UInt32(MemoryLayout<AudioDeviceID>.size)
            ), "Select \(deviceName)")

            var format = AudioStreamBasicDescription(
                mSampleRate: 48_000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 16,
                mReserved: 0
            )
            try check(AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ), "Set bridge audio format")

            var callback = AURenderCallbackStruct(
                inputProc: nativeAudioRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(AudioUnitSetProperty(
                unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), "Set bridge render callback")
            try check(AudioUnitInitialize(unit), "Initialize bridge audio")
            try check(AudioOutputUnitStart(unit), "Start bridge audio")
        } catch {
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
            throw error
        }
    }

    deinit { close() }

    func startSegment() {
        lock.lock()
        queued.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func write(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        queued.append(bytes)
        if queued.count > maximumQueuedBytes {
            queued.removeFirst(queued.count - maximumQueuedBytes)
        }
        lock.unlock()
    }

    fileprivate func render(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) {
        let expected = Int(frames) * 4
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        lock.lock()
        let available = min(expected, queued.count)
        let chunk = queued.prefix(available)
        if available > 0 { queued.removeFirst(available) }
        lock.unlock()

        for buffer in list {
            guard let destination = buffer.mData else { continue }
            let capacity = Int(buffer.mDataByteSize)
            memset(destination, 0, capacity)
            let copied = min(capacity, chunk.count)
            if copied > 0 {
                chunk.withUnsafeBytes { source in
                    if let base = source.baseAddress { memcpy(destination, base, copied) }
                }
            }
        }
    }

    func close() {
        guard let unit = audioUnit else { return }
        audioUnit = nil
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw BridgeError.coreAudio(operation, status) }
    }
}

private let nativeAudioRenderCallback: AURenderCallback = {
    reference, _, _, _, frames, buffers in
    guard let buffers else { return noErr }
    Unmanaged<NativeAudioSink>.fromOpaque(reference).takeUnretainedValue()
        .render(buffers, frames: frames)
    return noErr
}

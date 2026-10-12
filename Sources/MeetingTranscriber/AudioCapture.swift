import AVFoundation
import CoreAudio

private func checked(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw MeetingError.message("\(operation)失败（\(status)）。请检查“系统设置 → 隐私与安全”中的会记音频权限。")
    }
}

func copiedBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
    copy.frameLength = buffer.frameLength
    let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (source, destination) in zip(src, dst) {
        guard let s = source.mData, let d = destination.mData else { return nil }
        memcpy(d, s, Int(source.mDataByteSize))
    }
    return copy
}

func audioLevel(_ buffer: AVAudioPCMBuffer) -> Double {
    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    var sum: Float = 0
    for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
    let rms = sqrt(Double(sum) / Double(buffer.frameLength))
    return min(1, max(0, (20 * log10(max(rms, 0.000001)) + 60) / 60))
}

final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var tapped = false

    func start(receive: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingError.message("没有可用的麦克风，请连接麦克风后重试。")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let copy = copiedBuffer(buffer) { receive(copy) }
        }
        tapped = true
        engine.prepare()
        do { try engine.start() } catch { stop(); throw error }
    }

    func stop() {
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
    }
    deinit { stop() }
}

final class SystemAudioCapture {
    private var tap: AudioObjectID = kAudioObjectUnknown
    private var device: AudioObjectID = kAudioObjectUnknown
    private var io: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "local.huiji.system-audio")

    func start(receive: @escaping (AVAudioPCMBuffer) -> Void) throws {
        do {
            let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            description.name = "会记电脑音频"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try checked(AudioHardwareCreateProcessTap(description, &tap), "创建电脑音频采集")
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
            var streamDescription = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checked(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &streamDescription), "读取电脑音频格式")
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw MeetingError.message("电脑音频格式暂不支持。")
            }
            let bytesPerFrame = streamDescription.mBytesPerFrame
            let settings: [String: Any] = [
                kAudioAggregateDeviceNameKey: "会记临时音频采集",
                kAudioAggregateDeviceUIDKey: "local.huiji.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try checked(AudioHardwareCreateAggregateDevice(settings as CFDictionary, &device), "连接电脑音频")
            try checked(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { _, list, _, _, _ in
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
                guard let first = buffers.first, first.mDataByteSize > 0, bytesPerFrame > 0 else { return }
                let frames = first.mDataByteSize / bytesPerFrame
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
                buffer.frameLength = frames
                let destinations = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                guard buffers.count == destinations.count else { return }
                for (source, destination) in zip(buffers, destinations) {
                    guard let s = source.mData, let d = destination.mData else { return }
                    memcpy(d, s, min(Int(source.mDataByteSize), Int(destination.mDataByteSize)))
                }
                receive(buffer)
            }, "启动电脑音频回调")
            try checked(AudioDeviceStart(device, io), "开始采集电脑音频")
        } catch { stop(); throw error }
    }

    func stop() {
        if device != kAudioObjectUnknown {
            if let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        io = nil
        device = kAudioObjectUnknown
        tap = kAudioObjectUnknown
    }
    deinit { stop() }
}

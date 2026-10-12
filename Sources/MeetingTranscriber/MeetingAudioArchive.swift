import AVFoundation

// Writes on a separate serial queue; a storage error must not stop speech recognition.
final class MeetingAudioArchive: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.huiji.audio-archive")
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var frames: AVAudioFramePosition = 0
    private var failure: Error?
    private var closed = false

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func submit(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in append(buffer) }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
            guard !closed, failure == nil else { return }
            do {
                if inputFormat != buffer.format {
                    inputFormat = buffer.format
                    converter = AVAudioConverter(from: buffer.format, to: Self.format)
                    converter?.primeMethod = .none
                }
                guard let converter else { throw MeetingError.message("无法转换会议录音格式。") }
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 64)
                let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity)!
                var supplied = false
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, state in
                    if supplied { state.pointee = .noDataNow; return nil }
                    supplied = true; state.pointee = .haveData; return buffer
                }
                if let conversionError { throw conversionError }
                if status == .error { throw MeetingError.message("会议录音格式转换失败。") }
                try write(output)
            } catch { failure = error }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        if buffer.frameLength > 0 { try file?.write(from: buffer); frames += AVAudioFramePosition(buffer.frameLength) }
    }

    func finish() throws -> TimeInterval {
        try queue.sync {
            if !closed {
                closed = true
                defer { file = nil }
                if let converter, failure == nil {
                    let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 1024)!
                    var error: NSError?
                    converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                    if let error { failure = error }
                    else { do { try write(output) } catch { failure = error } }
                }
            }
            if let failure { throw failure }
            return Double(frames) / 16000
        }
    }

    static func copyFile(_ input: URL, to output: URL) async throws -> TimeInterval {
        let task = Task.detached(priority: .utility) {
            let file = try AVAudioFile(forReading: input)
            let archive = try MeetingAudioArchive(url: output)
            do {
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
                    try file.read(into: buffer)
                    if buffer.frameLength == 0 { break }
                    archive.queue.sync { archive.append(buffer) }
                }
                return try archive.finish()
            } catch { _ = try? archive.finish(); throw error }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

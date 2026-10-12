import AVFoundation

@MainActor
final class LocalSpeakerDiarizer {
    private let resources: URL

    init(resources: URL = Bundle.main.resourceURL!.appendingPathComponent("SpeakerModels")) {
        self.resources = resources
    }

    func analyze(_ record: MeetingRecord, store: MeetingStore, speakerCount: Int = 0) async throws -> [SpeakerTurn] {
        guard let assets = record.audioSegments, !assets.isEmpty else {
            throw MeetingError.message("这场会议没有保存音频，不能补做声音分离。新录制或导入的会议会保存本地音频。")
        }
        let executable = resources.appendingPathComponent("speaker-helper")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("segmentation.onnx").path),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("embedding.onnx").path),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("vad.onnx").path) else {
            throw MeetingError.message("本地说话人模型缺失，请重新安装完整的会记应用。")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("huiji-speakers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let combined = temporary.appendingPathComponent("combined.wav")
        let result = temporary.appendingPathComponent("result.json")
        let urls = try assets.map { try store.audioURL(for: $0, in: record) }
        let assembly = Task.detached(priority: .utility) { () throws -> [(Double, Double)] in
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
            let output = try AVAudioFile(forWriting: combined, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            var ranges: [(Double, Double)] = []
            for url in urls {
                try Task.checkCancellation()
                let input = try AVAudioFile(forReading: url)
                guard input.processingFormat.sampleRate == 16000, input.processingFormat.channelCount == 1 else {
                    throw MeetingError.message("会议音频格式无效。原文件已保留。")
                }
                let start = Double(output.length) / 16000
                let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192)!
                while input.framePosition < input.length {
                    try Task.checkCancellation()
                    try input.read(into: buffer)
                    if buffer.frameLength == 0 { break }
                    try output.write(from: buffer)
                }
                ranges.append((start, Double(output.length) / 16000))
                let silence = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8000)!
                silence.frameLength = 8000
                memset(silence.floatChannelData![0], 0, 8000 * MemoryLayout<Float>.size)
                try output.write(from: silence)
            }
            return ranges
        }
        let ranges = try await withTaskCancellationHandler { try await assembly.value } onCancel: { assembly.cancel() }
        try Task.checkCancellation()
        let worker = Process()
        worker.executableURL = executable
        worker.arguments = [resources.appendingPathComponent("segmentation.onnx").path,
            resources.appendingPathComponent("embedding.onnx").path, combined.path, result.path, resources.appendingPathComponent("vad.onnx").path]
        let log = temporary.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        worker.standardOutput = handle; worker.standardError = handle
        try worker.run()
        do {
            while worker.isRunning { try await Task.sleep(for: .milliseconds(100)); try Task.checkCancellation() }
        } catch {
            worker.terminate()
            // Only the child we created is stopped; wait before removing its working files.
            await Task.detached { worker.waitUntilExit() }.value
            throw error
        }
        guard worker.terminationStatus == 0 else { throw MeetingError.message("本地说话人分离未完成（\(worker.terminationStatus)），原转写与音频已保留，可以重试。") }
        let fragments = try JSONDecoder().decode([SpeakerEmbeddingSegment].self, from: Data(contentsOf: result))
        let clustering = Task.detached(priority: .utility) { try SpeakerClustering.assign(fragments, speakerCount: speakerCount) }
        let speakers = try await withTaskCancellationHandler { try await clustering.value } onCancel: { clustering.cancel() }
        try Task.checkCancellation()
        let runID = UUID().uuidString
        var turns: [SpeakerTurn] = []
        for (fragmentIndex, segment) in fragments.enumerated() {
            guard let speaker = speakers[fragmentIndex] else { continue }
            // Small padding absorbs ASR timing drift. Midpoints between different
            // voices and unknown fragments prevent padding across a change.
            var paddedStart = max(0, segment.start - 0.2), paddedEnd = segment.end + 0.2
            if fragmentIndex > 0, speakers[fragmentIndex - 1] != speaker {
                paddedStart = max(paddedStart, (fragments[fragmentIndex - 1].end + segment.start) / 2)
            }
            if fragmentIndex + 1 < fragments.count, speakers[fragmentIndex + 1] != speaker {
                paddedEnd = min(paddedEnd, (segment.end + fragments[fragmentIndex + 1].start) / 2)
            }
            guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start else { continue }
            for (index, range) in ranges.enumerated() {
                let start = max(paddedStart, range.0), end = min(paddedEnd, range.1)
                if end > start {
                    turns.append(SpeakerTurn(source: assets[index].source,
                        start: assets[index].start + start - range.0, end: assets[index].start + end - range.0,
                        speakerID: runID + "-" + String(speaker)))
                }
            }
        }
        return turns
    }
}

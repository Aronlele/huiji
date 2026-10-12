import AVFoundation
import Speech

@MainActor
enum ChineseModel {
    static func transcriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            throw MeetingError.message("这台 Mac 暂不支持系统中文离线识别。需要 Apple Silicon 和 macOS 26 或更新版本。")
        }
        return SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
    }

    static func isInstalled() async throws -> Bool {
        let module = try await transcriber()
        return await AssetInventory.status(forModules: [module]) == .installed
    }

    static func prepare(progress: @escaping (Double?) -> Void = { _ in }) async throws {
        let module = try await transcriber()
        if await AssetInventory.status(forModules: [module]) == .installed { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let updates = Task {
                while !Task.isCancelled {
                    progress(request.progress.totalUnitCount > 0 ? request.progress.fractionCompleted : nil)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { updates.cancel() }
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: { request.progress.cancel() }
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw MeetingError.message("中文模型尚未准备好，请联网后重试。会议音频不会用于模型下载。")
        }
    }
}

// Each channel owns a serial conversion queue; borrowed audio memory is copied by the capture layer.
final class AudioInput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.huiji.audio-conversion")
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let errorHandler: @Sendable (Error) -> Void
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var closed = false

    init(target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         errorHandler: @escaping @Sendable (Error) -> Void) {
        self.target = target
        self.continuation = continuation
        self.errorHandler = errorHandler
    }

    func submit(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard !closed else { return }
            do {
                if buffer.format != sourceFormat {
                    sourceFormat = buffer.format
                    converter = AVAudioConverter(from: buffer.format, to: target)
                    converter?.primeMethod = .none
                }
                guard let converter else { throw MeetingError.message("无法转换输入音频格式。") }
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32)
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                    throw MeetingError.message("无法分配音频缓冲区。")
                }
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, state in
                    if supplied { state.pointee = .noDataNow; return nil }
                    supplied = true
                    state.pointee = .haveData
                    return buffer
                }
                if let error { throw error }
                guard status != .error else { throw MeetingError.message("音频转换失败。") }
                if output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
            } catch {
                closed = true
                continuation.finish()
                errorHandler(error)
            }
        }
    }

    func finish() {
        queue.sync {
            guard !closed else { return }
            closed = true
            if let converter, let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1024) {
                var error: NSError?
                converter.convert(to: buffer, error: &error) { _, state in
                    state.pointee = .endOfStream
                    return nil
                }
                if let error { errorHandler(error) }
                if buffer.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: buffer)) }
            }
            continuation.finish()
        }
    }
}

@MainActor
final class SpeechSession {
    private let analyzer: SpeechAnalyzer
    private var resultTask: Task<Void, Never>?
    let input: AudioInput

    private init(analyzer: SpeechAnalyzer, input: AudioInput) {
        self.analyzer = analyzer
        self.input = input
    }

    static func start(onResult: @escaping @MainActor (SpeechTranscriber.Result) -> Void,
                      onError: @escaping @MainActor (Error) -> Void) async throws -> SpeechSession {
        let transcriber = try await ChineseModel.transcriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MeetingError.message("中文识别器没有可用的音频格式。")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let input = AudioInput(target: format, continuation: continuation) { error in
            Task { @MainActor in onError(error) }
        }
        let session = SpeechSession(analyzer: analyzer, input: input)
        session.resultTask = Task {
            do {
                for try await result in transcriber.results { onResult(result) }
            } catch {
                if !Task.isCancelled { onError(error) }
            }
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        } catch {
            input.finish()
            await analyzer.cancelAndFinishNow()
            session.resultTask?.cancel()
            throw error
        }
        return session
    }

    static func transcribeFile(url: URL, onResult: @escaping @MainActor (SpeechTranscriber.Result) -> Void) async throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let transcriber = try await ChineseModel.transcriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task {
            for try await result in transcriber.results { onResult(result) }
        }
        do {
            try await withTaskCancellationHandler {
                let end = try await analyzer.analyzeSequence(from: file)
                if let end { try await analyzer.finalizeAndFinish(through: end) }
                else { try await analyzer.finalizeAndFinishThroughEndOfInput() }
                try await results.value
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            return duration
        } catch {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
    }

    func finish() async throws {
        input.finish()
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            await analyzer.cancelAndFinishNow()
        }
        defer { watchdog.cancel() }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await resultTask?.value
        } catch {
            await analyzer.cancelAndFinishNow()
            resultTask?.cancel()
            throw error
        }
    }
}

import Foundation
import Combine

@MainActor
final class EnvironmentSetup: ObservableObject {
    struct Item {
        var ready = false
        var detail = "等待检查"
        var failed = false
    }
    struct Actions {
        var speechInstalled: () async throws -> Bool
        var prepareSpeech: (@escaping (Double?) -> Void) async throws -> Void
        var speakersInstalled: () -> Bool
        var inspectAI: () async throws -> LocalMeetingAI.EnvironmentStatus
        var installRuntime: (@escaping (String, Double?) -> Void) async throws -> Void
        var prepareAI: (@escaping (String, Double?) -> Void) async throws -> Void

        static var live: Actions {
            Actions(speechInstalled: { try await ChineseModel.isInstalled() },
                prepareSpeech: { try await ChineseModel.prepare(progress: $0) },
                speakersInstalled: {
                    guard let resources = Bundle.main.resourceURL?.appendingPathComponent("SpeakerModels") else { return false }
                    return ["speaker-helper", "embedding.onnx", "segmentation.onnx", "vad.onnx", "libsherpa-onnx-c-api.dylib", "libonnxruntime.dylib"].allSatisfy {
                        FileManager.default.fileExists(atPath: resources.appendingPathComponent($0).path)
                    }
                }, inspectAI: { try await LocalMeetingAI.shared.inspectEnvironment() },
                installRuntime: { try await LocalAIRuntime.install(progress: $0) },
                prepareAI: { try await LocalMeetingAI.shared.prepareModel(progress: $0) })
        }
    }

    @Published var isPresented = false
    @Published var includeAI = true
    @Published private(set) var speech = Item()
    @Published private(set) var speakers = Item()
    @Published private(set) var runtime = Item()
    @Published private(set) var aiModel = Item()
    @Published private(set) var busy = false
    @Published private(set) var checking = false
    @Published private(set) var checked = false
    @Published private(set) var message = "先检查这台 Mac 的已有环境"
    @Published private(set) var fraction: Double?
    @Published private(set) var error: String?
    private let actions: Actions
    private var task: Task<Void, Never>?
    var baseReady: Bool { speech.ready && speakers.ready }
    var allReady: Bool { baseReady && runtime.ready && aiModel.ready }
    var selectionReady: Bool { baseReady && (!includeAI || (runtime.ready && aiModel.ready)) }

    init(actions: Actions = .live) { self.actions = actions }

    func check() async {
        guard !busy, !checking else { return }
        checking = true
        defer { checking = false; checked = true }
        error = nil
        await inspect()
        message = allReady ? "全部就绪 · 已有环境自动复用" : "只需准备缺少的项目"
    }

    private func inspect() async {
        do {
            let installed = try await actions.speechInstalled()
            speech = Item(ready: installed, detail: installed ? "已安装 · 复用系统中文模型" : "首次需要联网下载，由 macOS 管理")
        } catch { speech = Item(detail: error.localizedDescription, failed: true) }
        let bundled = actions.speakersInstalled()
        speakers = Item(ready: bundled, detail: bundled ? "已包含模型与运行库，无需另外安装" : "安装包不完整，请重新安装完整的会记", failed: !bundled)
        do {
            let ai = try await actions.inspectAI()
            runtime = Item(ready: ai.runtimeReady, detail: ai.runtimeReady ? ai.detail : "缺少时自动安装到会记自己的目录（约 206 MB）")
            aiModel = Item(ready: ai.modelReady, detail: ai.modelReady ? ai.detail : "Qwen3 中文模型约 2.5 GB；已有模型直接复用")
        } catch {
            runtime = Item(detail: error.localizedDescription, failed: true)
            aiModel = Item(detail: "本地 AI 服务恢复后重新检查", failed: true)
        }
    }

    func start() {
        guard checked, !busy, !checking, !selectionReady else { return }
        busy = true; error = nil; fraction = nil
        let prepareAI = includeAI
        task = Task { [self] in
            defer { busy = false; fraction = nil; task = nil }
            do {
                // Recheck immediately before installation, including environments installed by another app.
                await inspect()
                try Task.checkCancellation()
                guard !speech.failed, speakers.ready else {
                    throw MeetingError.message(speech.failed ? speech.detail : speakers.detail)
                }
                if !speech.ready {
                    message = "正在下载中文识别模型…"
                    try await actions.prepareSpeech { [weak self] in self?.fraction = $0 }
                    speech = Item(ready: true, detail: "中文离线识别已就绪")
                }
                try Task.checkCancellation()
                if prepareAI {
                    if runtime.failed { throw MeetingError.message(runtime.detail) }
                    if !runtime.ready {
                        try await actions.installRuntime { [weak self] in self?.update($0, $1) }
                        runtime = Item(ready: true, detail: "本地 AI 运行环境已安装")
                    }
                    try Task.checkCancellation()
                    if !aiModel.ready {
                        try await actions.prepareAI { [weak self] in self?.update($0, $1) }
                    }
                }
                try Task.checkCancellation()
                await inspect()
                guard selectionReady else { throw MeetingError.message("部分项目未就绪，请重新检查并重试。") }
                message = prepareAI ? "准备完成 · 转写、说话人分离与纪要均可在本机使用" : "转写与说话人分离已就绪，稍后可补齐 AI 纪要"
            } catch {
                if Task.isCancelled { message = "已停止准备 · 已完成的项目保留，下次可继续" }
                else { await inspect(); self.error = error.localizedDescription; message = "准备未完成，已完成的项目保留" }
            }
        }
    }

    private func update(_ text: String, _ progress: Double?) {
        guard busy, task?.isCancelled != true else { return }
        message = text; fraction = progress
    }
    func cancel() { task?.cancel() }
    func waitUntilFinished() async { await task?.value }
}

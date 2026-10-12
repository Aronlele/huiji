import Foundation

@MainActor
private final class Fixture {
    var speech = false
    var speakers = true
    var runtime = false
    var model = false
    var calls: [String] = []
    var failModelOnce = false
    var pauseModel = false
    var failInspection = false
    var actions: EnvironmentSetup.Actions {
        .init(speechInstalled: { self.speech }, prepareSpeech: { progress in
            self.calls.append("speech"); progress(0.5); self.speech = true
        }, speakersInstalled: { self.speakers }, inspectAI: {
            if self.failInspection { throw MeetingError.message("模拟端口占用") }
            return .init(runtimeReady: self.runtime, modelReady: self.model, detail: "测试已有环境")
        }, installRuntime: { progress in
            self.calls.append("runtime"); progress("安装中", 0.5); self.runtime = true
        }, prepareAI: { progress in
            self.calls.append("model"); progress("下载中", 0.5)
            if self.pauseModel { try await Task.sleep(for: .seconds(300)) }
            if self.failModelOnce { self.failModelOnce = false; throw MeetingError.message("模拟网络中断") }
            self.model = true
        })
    }
}

@main
struct EnvironmentSetupTests {
    @MainActor static func main() async throws {
        let existing = Fixture()
        existing.speech = true; existing.runtime = true; existing.model = true
        let reuse = EnvironmentSetup(actions: existing.actions)
        await reuse.check(); reuse.start(); await reuse.waitUntilFinished()
        precondition(reuse.allReady && existing.calls.isEmpty, "已有环境不得重新下载")

        let fresh = Fixture()
        let setup = EnvironmentSetup(actions: fresh.actions)
        await setup.check(); setup.start(); await setup.waitUntilFinished()
        precondition(setup.allReady && fresh.calls == ["speech", "runtime", "model"])
        precondition(!setup.busy && setup.error == nil)

        let partial = Fixture()
        partial.speech = true; partial.runtime = true
        let missingModel = EnvironmentSetup(actions: partial.actions)
        await missingModel.check(); missingModel.start(); await missingModel.waitUntilFinished()
        precondition(missingModel.allReady && partial.calls == ["model"])

        let later = Fixture()
        let base = EnvironmentSetup(actions: later.actions)
        base.includeAI = false
        await base.check(); base.start(); await base.waitUntilFinished()
        precondition(base.baseReady && !base.allReady && later.calls == ["speech"])
        base.includeAI = true; base.start(); await base.waitUntilFinished()
        precondition(base.allReady && later.calls == ["speech", "runtime", "model"])

        let interrupted = Fixture()
        interrupted.failModelOnce = true
        let retry = EnvironmentSetup(actions: interrupted.actions)
        await retry.check(); retry.start(); await retry.waitUntilFinished()
        precondition(retry.error != nil && retry.speech.ready && retry.runtime.ready && !retry.aiModel.ready)
        retry.start(); await retry.waitUntilFinished()
        precondition(retry.allReady && interrupted.calls == ["speech", "runtime", "model", "model"])

        let cancelled = Fixture()
        cancelled.pauseModel = true
        let cancel = EnvironmentSetup(actions: cancelled.actions)
        await cancel.check(); cancel.start()
        while !cancelled.calls.contains("model") { await Task.yield() }
        cancel.cancel(); await cancel.waitUntilFinished()
        precondition(!cancel.busy && cancel.error == nil && cancel.speech.ready && cancel.runtime.ready)
        precondition(!cancel.aiModel.ready && cancel.message.contains("已停止"))
        cancelled.pauseModel = false
        cancel.start(); await cancel.waitUntilFinished()
        precondition(cancel.allReady && cancelled.calls == ["speech", "runtime", "model", "model"])

        let broken = Fixture()
        broken.speakers = false
        let damagedPackage = EnvironmentSetup(actions: broken.actions)
        await damagedPackage.check(); damagedPackage.start(); await damagedPackage.waitUntilFinished()
        precondition(damagedPackage.error != nil && broken.calls.isEmpty)

        let occupied = Fixture()
        occupied.failInspection = true
        let noOverwrite = EnvironmentSetup(actions: occupied.actions)
        await noOverwrite.check(); noOverwrite.start(); await noOverwrite.waitUntilFinished()
        precondition(noOverwrite.error != nil && occupied.calls == ["speech"])

        let changed = Fixture()
        let race = EnvironmentSetup(actions: changed.actions)
        await race.check()
        changed.speech = true; changed.runtime = true; changed.model = true
        race.start(); await race.waitUntilFinished()
        precondition(race.allReady && changed.calls.isEmpty, "安装前必须再次检测")

        let tags = Data("""
        {"models":[{"name":"qwen3:4b-instruct","remote_model":"qwen3:4b-instruct","remote_host":"https://ollama.com"}]}
        """.utf8)
        let remoteTags = try JSONDecoder().decode(LocalMeetingAI.ModelList.self, from: tags)
        precondition(!remoteTags.hasLocalQwen)
        let local = Data("{\"models\":[{\"name\":\"qwen3:4b-instruct\"}]}".utf8)
        let localTags = try JSONDecoder().decode(LocalMeetingAI.ModelList.self, from: local)
        precondition(localTags.hasLocalQwen)
        let event = try JSONDecoder().decode(LocalMeetingAI.PullEvent.self, from: Data("{\"total\":100,\"completed\":200}".utf8))
        precondition(event.fraction == 1)

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("huiji-environment-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let invalid = temporary.appendingPathComponent("invalid.zip")
        try Data("invalid official download".utf8).write(to: invalid)
        let destination = temporary.appendingPathComponent("Ollama.app")
        do { try await LocalAIRuntime.installArchive(invalid, destination: destination) { _, _ in }; preconditionFailure("无效校验值不能安装") }
        catch { precondition(!FileManager.default.fileExists(atPath: destination.path)) }
        do { try LocalAIRuntime.requireSpace(at: temporary, bytes: Int64.max); preconditionFailure("磁盘不足不能继续") }
        catch { precondition(error.localizedDescription.contains("磁盘空间不足")) }
        precondition(LocalAIRuntime.executable(in: [invalid, destination]) == nil)
        print("PASS: 全新环境顺序准备、已有环境零下载、缺少单项、稍后补齐、断网重试、取消续作、坏安装包、端口错误、安装前重检、拒绝云模型、进度边界、SHA256 失败与磁盘不足")

        if let index = CommandLine.arguments.firstIndex(of: "--download-progress"), CommandLine.arguments.count > index + 1 {
            var received = false
            let delegate = RuntimeDownloadDelegate { fraction in if (fraction ?? 0) > 0 { received = true } }
            let (downloaded, response) = try await delegate.download(from: URL(string: CommandLine.arguments[index + 1])!)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            await Task.yield()
            precondition((response as? HTTPURLResponse)?.statusCode == 200 && received)
            let downloadedBytes = try Data(contentsOf: downloaded).count
            precondition(downloadedBytes == 2_097_152)
            print("PASS: 实际文件传输触发进度回调，下载文件完整")
        }

        if CommandLine.arguments.contains("--cancel-download") {
            var receivedProgress = false
            let download = Task {
                try await LocalAIRuntime.install(destination: destination) { _, fraction in
                    if fraction != nil { receivedProgress = true }
                }
            }
            try await Task.sleep(for: .seconds(45))
            download.cancel()
            do { try await download.value; preconditionFailure("取消下载不应安装完成") }
            catch { precondition(!FileManager.default.fileExists(atPath: destination.path)) }
            print("PASS: 官方下载实际取消，未安装文件；收到下载进度:", receivedProgress)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--runtime-integration"), CommandLine.arguments.count > index + 1 {
            let archive = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            if CommandLine.arguments.contains("--download-runtime") {
                try await LocalAIRuntime.install(destination: destination) { text, fraction in
                    if fraction == nil { print(text) }
                }
            } else {
                try await LocalAIRuntime.installArchive(archive, destination: destination) { print($0, $1 as Any) }
            }
            let cli = destination.appendingPathComponent("Contents/Resources/ollama")
            precondition(LocalAIRuntime.executable(in: [cli]) != nil)
            let cleanServer = Process()
            if CommandLine.arguments.contains("--fresh-models") {
                let tagsURL = URL(string: "http://127.0.0.1:11434/api/tags")!
                if (try? await URLSession.shared.data(from: tagsURL)) != nil {
                    throw MeetingError.message("本机端口正在使用，不能执行隔离模型下载测试。")
                }
                cleanServer.executableURL = cli
                cleanServer.arguments = ["serve"]
                var variables = ProcessInfo.processInfo.environment
                variables["OLLAMA_HOST"] = "127.0.0.1:11434"
                variables["OLLAMA_NO_CLOUD"] = "1"
                variables["OLLAMA_MODELS"] = temporary.appendingPathComponent("models").path
                cleanServer.environment = variables
                cleanServer.standardOutput = FileHandle.nullDevice
                cleanServer.standardError = FileHandle.nullDevice
                try cleanServer.run()
                for _ in 0..<100 {
                    if (try? await URLSession.shared.data(from: tagsURL)) != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { if cleanServer.isRunning { cleanServer.terminate(); cleanServer.waitUntilExit() } }
            let ai = LocalMeetingAI(runtimeExecutable: { cli })
            defer { ai.shutdown() }
            let status = try await ai.inspectEnvironment()
            precondition(status.runtimeReady)
            if CommandLine.arguments.contains("--fresh-models") {
                precondition(!status.modelReady)
                var bucket = -1
                try await ai.prepareModel { text, fraction in
                    if let fraction {
                        let next = Int(fraction * 10)
                        if next != bucket { bucket = next; print("新模型实际下载:", next * 10, "%", text) }
                    } else { print(text) }
                }
                let prepared = try await ai.inspectEnvironment()
                precondition(prepared.modelReady)
            } else { precondition(status.modelReady) }
            var downloaded = false
            try await ai.prepareModel { _, _ in downloaded = true }
            precondition(!downloaded, "已有模型不允许再次下载")
            let material = "产品会议：我们决定采用本机离线转写，会议内容不上传。王明负责接口开发，周五完成。李华负责检查中文识别结果，下周一提交报告。预算还未决定。"
            let summary = try await ai.summarize(material) { print($0) }
            print(String(decoding: try JSONEncoder().encode(summary), as: UTF8.self))
            guard !summary.summary.isEmpty, summary.tasks.contains(where: { $0.owner.contains("王明") && $0.due.contains("周五") }) else {
                throw MeetingError.message("真实本地纪要未提取测试任务，请检查模型效果。")
            }
            let chineseInstalled = try await ChineseModel.isInstalled()
            print("系统中文识别模型当前已安装:", chineseInstalled)
            print("PASS: 官方完整压缩包 SHA256、签名校验、独立目录实际安装、新安装运行环境启动、本机既有模型跳过下载、真实中文本地纪要")
        }
    }
}

import Foundation
import AVFoundation
import Speech

// Compile the real MeetingModel against controlled devices and recognizers, without recording audio.
@MainActor
enum ChineseModel {
    static func transcriber() async throws -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: "zh_CN"), preset: .timeIndexedProgressiveTranscription)
    }
    static func prepare() async throws {}
}

final class AudioInput {
    func submit(_ buffer: AVAudioPCMBuffer) {}
    func finish() {}
}

@MainActor
final class SpeechSession {
    static var instances: [SpeechSession] = []
    static var pauseNextStart = false
    static var startGate: CheckedContinuation<Void, Never>?
    let input = AudioInput()
    var finishCount = 0
    var failFinish = false
    var pauseFinish = false
    var finishGate: CheckedContinuation<Void, Never>?
    var onError: (@MainActor (Error) -> Void)?

    static func start(onResult: @escaping @MainActor (SpeechTranscriber.Result) -> Void,
                      onError: @escaping @MainActor (Error) -> Void) async throws -> SpeechSession {
        let session = SpeechSession()
        session.onError = onError
        instances.append(session)
        if pauseNextStart {
            pauseNextStart = false
            await withCheckedContinuation { startGate = $0 }
        }
        return session
    }

    static func transcribeFile(url: URL, onResult: @escaping @MainActor (SpeechTranscriber.Result) -> Void) async throws -> TimeInterval { 1 }

    func finish() async throws {
        finishCount += 1
        if pauseFinish { await withCheckedContinuation { finishGate = $0 } }
        if failFinish { throw MeetingError.message("模拟麦克风识别失败") }
    }
}

final class MicrophoneCapture {
    static var instances: [MicrophoneCapture] = []
    static var failNextStart = false
    var startCount = 0
    var stopCount = 0
    var receive: ((AVAudioPCMBuffer) -> Void)?
    init() { Self.instances.append(self) }
    func start(receive: @escaping (AVAudioPCMBuffer) -> Void) throws {
        if Self.failNextStart {
            Self.failNextStart = false
            throw MeetingError.message("模拟设备启动失败")
        }
        startCount += 1
        self.receive = receive
    }
    func stop() { stopCount += 1 }
}

final class SystemAudioCapture {
    static var instances: [SystemAudioCapture] = []
    var startCount = 0
    var stopCount = 0
    var receive: ((AVAudioPCMBuffer) -> Void)?
    init() { Self.instances.append(self) }
    func start(receive: @escaping (AVAudioPCMBuffer) -> Void) throws { startCount += 1; self.receive = receive }
    func stop() { stopCount += 1 }
}

func audioLevel(_ buffer: AVAudioPCMBuffer) -> Double { 0 }

@main
struct MicrophoneSwitchTests {
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("麦克风切换未完成")
    }

    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var allowed = true
        let model = MeetingModel(directory: directory, microphoneAccess: { allowed })
        model.modelReady = true
        model.useMicrophone = false
        await model.start()
        precondition(!model.recording && SystemAudioCapture.instances.isEmpty)
        precondition(model.createMeeting(title: "会议 A"))
        await model.start()
        precondition(model.recording)
        let system = SystemAudioCapture.instances.last!
        let systemSession = SpeechSession.instances.last!
        let savedURL = model.savedURL
        let startedAt = model.document.startedAt

        for _ in 0..<3 {
            model.setMicrophoneEnabled(true)
            await waitUntil { !model.microphoneChanging }
            precondition(model.useMicrophone && model.recording)
            let mic = MicrophoneCapture.instances.last!
            let micSession = SpeechSession.instances.last!
            precondition(mic.startCount == 1)
            model.setMicrophoneEnabled(false)
            precondition(mic.stopCount == 1 && model.microphoneLevel == 0)
            await waitUntil { !model.microphoneChanging }
            precondition(!model.useMicrophone && model.recording)
            precondition(micSession.finishCount == 1)
            precondition(system.stopCount == 0 && systemSession.finishCount == 0)
            precondition(model.savedURL == savedURL && model.document.startedAt == startedAt)
            micSession.onError?(MeetingError.message("已经关闭的识别器延迟报错"))
            precondition(model.error == nil && model.recording)
        }

        model.setMicrophoneEnabled(true)
        await waitUntil { !model.microphoneChanging }
        let failedMic = MicrophoneCapture.instances.last!
        SpeechSession.instances.last!.onError?(MeetingError.message("运行中的麦克风识别失败"))
        precondition(failedMic.stopCount == 1)
        await waitUntil { !model.useMicrophone && !model.microphoneChanging }
        precondition(model.recording && system.stopCount == 0)

        model.setMicrophoneEnabled(true)
        await waitUntil { !model.microphoneChanging }
        precondition(model.error == nil)
        SpeechSession.instances.last!.failFinish = true
        model.setMicrophoneEnabled(false)
        await waitUntil { !model.microphoneChanging }
        precondition(model.recording && model.error != nil && system.stopCount == 0)

        allowed = false
        model.setMicrophoneEnabled(true)
        await waitUntil { !model.microphoneChanging }
        precondition(!model.useMicrophone && model.recording && model.error != nil)
        precondition(system.stopCount == 0)

        allowed = true
        MicrophoneCapture.failNextStart = true
        model.setMicrophoneEnabled(true)
        await waitUntil { !model.microphoneChanging }
        precondition(!model.useMicrophone && model.recording)
        precondition(SpeechSession.instances.last!.finishCount == 1 && system.stopCount == 0)

        SpeechSession.pauseNextStart = true
        model.setMicrophoneEnabled(true)
        await waitUntil { SpeechSession.startGate != nil }
        let micCount = MicrophoneCapture.instances.count
        let stopping = Task { await model.stop(summarize: false) }
        await waitUntil { !model.recording }
        SpeechSession.startGate?.resume()
        SpeechSession.startGate = nil
        await stopping.value
        precondition(!model.microphoneChanging && !model.finishing)
        precondition(MicrophoneCapture.instances.count == micCount)
        precondition(system.stopCount == 1 && systemSession.finishCount == 1)

        model.setMicrophoneEnabled(false)
        await model.start()
        let nextSystem = SystemAudioCapture.instances.last!
        model.setMicrophoneEnabled(true)
        await waitUntil { !model.microphoneChanging }
        let closingMic = SpeechSession.instances.last!
        closingMic.pauseFinish = true
        model.setMicrophoneEnabled(false)
        await waitUntil { closingMic.finishGate != nil }
        let stoppingDuringClose = Task { await model.stop(summarize: false) }
        await waitUntil { !model.recording }
        precondition(nextSystem.stopCount == 1)
        closingMic.finishGate?.resume()
        await stoppingDuringClose.value
        precondition(closingMic.finishCount == 1 && !model.finishing && !model.microphoneChanging)
        precondition(savedURL != nil && FileManager.default.fileExists(atPath: savedURL!.path))
        print("PASS: 连续切换不停止电脑声音、同一份记录、权限和设备及识别失败隔离、过期回调隔离、切换中停止安全退出")

        let firstID = model.selectedMeetingID!
        model.document.update(source: .system, start: 90, end: 100, text: "会议 A 的中文记录", isFinal: true)
        model.setMicrophoneEnabled(false)
        await model.start()
        precondition(model.document.lines.contains { $0.text == "会议 A 的中文记录" })
        precondition(!model.createMeeting(title: "不应在转写中创建"))
        await model.stop(summarize: false)
        precondition(model.selectedMeeting!.elapsed >= 100)
        precondition(model.createMeeting(title: "会议 B"))
        precondition(model.document.lines.isEmpty && model.selectedMeeting!.elapsed == 0)
        let secondID = model.selectedMeetingID!
        precondition(secondID != firstID && model.savedURL != savedURL)
        let emptyMeetingText = try String(contentsOf: model.savedURL!, encoding: .utf8)
        precondition(!emptyMeetingText.contains("会议 A 的中文记录"))
        model.selectMeeting(firstID)
        precondition(model.document.lines.contains { $0.text == "会议 A 的中文记录" })
        let reopened = MeetingModel(directory: directory, microphoneAccess: { true })
        reopened.loadMeetings()
        precondition(reopened.meetings.count == 2)
        reopened.selectMeeting(firstID)
        precondition(reopened.document.lines.contains { $0.text == "会议 A 的中文记录" })
        reopened.selectMeeting(secondID)
        precondition(reopened.document.lines.isEmpty)
        model.renameSelected("项目测试")
        model.setNotes("预算讨论")
        model.addTask(text: "跟进接口", owner: "王明", due: "周五")
        model.toggleFavorite()
        model.setFolder("项目")
        model.libraryQuery = "预算"
        precondition(model.visibleMeetings.count == 1)
        model.libraryScope = .favorites
        precondition(model.visibleMeetings.count == 1)
        model.libraryQuery = ""
        let deleted = model.selectedMeetingID!
        model.deleteSelected()
        precondition(model.visibleMeetings.isEmpty && model.selectedMeeting?.deletedAt != nil)
        model.libraryScope = .trash
        precondition(model.visibleMeetings.count == 1)
        model.restore(deleted)
        precondition(model.selectedMeeting?.deletedAt == nil && model.visibleMeetings.count == 2)
        let reload = MeetingModel(directory: directory, microphoneAccess: { true })
        reload.loadMeetings(); reload.selectMeeting(deleted)
        precondition(reload.selectedMeeting?.notes == "预算讨论")
        precondition(reload.selectedMeeting?.tasks?.first?.owner == "王明")
        precondition(reload.selectedMeeting?.folder == "项目" && reload.selectedMeeting?.isFavorite == true)
        let date = reload.selectedMeeting!.updatedAt
        reload.selectMeeting(firstID); reload.selectMeeting(deleted)
        precondition(reload.selectedMeeting!.updatedAt == date)
        reload.modelReady = true; reload.useMicrophone = false
        await reload.start()
        let pausingSystem = SystemAudioCapture.instances.last!
        let continuationID = reload.selectedMeetingID
        await reload.stop(pausing: true, summarize: false)
        precondition(reload.paused && !reload.recording && pausingSystem.stopCount == 1)
        await reload.start()
        precondition(reload.recording && !reload.paused && reload.selectedMeetingID == continuationID)
        await reload.stop(summarize: false)
        precondition(reload.createMeeting(title: "自动纪要验证"))
        reload.document.update(source: .system, start: 0, end: 2, text: "会议决定采用本机离线转写。", isFinal: true)
        await reload.start()
        await reload.stop()
        precondition(reload.summaryGenerating && reload.tab == .summary)
        reload.cancelSummary()
        await waitUntil { !reload.summaryGenerating }
        precondition(reload.selectedMeeting?.summary == nil && reload.document.lines.count == 1)
        print("PASS: 结束后自动整理、取消不覆盖原始转写")
        print("PASS: 暂停停止采集、继续沿用同一会议")
        print("PASS: 全文搜索、收藏、文件夹、笔记待办持久化、删除恢复、仅查看不改变更新时间")
        print("PASS: 先创建再转写、结束后继续追加、累计时间轴、新会议空记录、会议隔离、重启恢复")
        let archiveModel = MeetingModel(directory: directory, microphoneAccess: { true })
        archiveModel.modelReady = true
        precondition(archiveModel.createMeeting(title: "双路音频归档验证"))
        await archiveModel.start()
        let computer = SystemAudioCapture.instances.last!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        func tone() -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600)!
            buffer.frameLength = 9600
            for channel in 0..<2 {
                for index in 0..<9600 { buffer.floatChannelData![channel][index] = sin(Float(index) * 0.1) * 0.2 }
            }
            return buffer
        }
        computer.receive?(tone())
        archiveModel.setMicrophoneEnabled(true)
        await waitUntil { !archiveModel.microphoneChanging }
        let mic = MicrophoneCapture.instances.last!
        mic.receive?(tone()); computer.receive?(tone())
        archiveModel.setMicrophoneEnabled(false)
        await waitUntil { !archiveModel.microphoneChanging }
        mic.receive?(tone()) // A callback from the closed microphone cannot append audio.
        computer.receive?(tone())
        await archiveModel.stop(summarize: false)
        let audio = archiveModel.selectedMeeting!.audioSegments!
        precondition(audio.count == 2)
        precondition(abs(audio.first { $0.source == .system }!.duration - 0.6) < 0.002)
        precondition(abs(audio.first { $0.source == .microphone }!.duration - 0.2) < 0.002)
        let audioStore = MeetingStore(directory: directory)
        for segment in audio {
            let file = try AVAudioFile(forReading: audioStore.audioURL(for: segment, in: archiveModel.selectedMeeting!))
            precondition(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
        }
        await archiveModel.start(); computer.receive?(tone())
        SystemAudioCapture.instances.last!.receive?(tone())
        await archiveModel.stop(pausing: true, summarize: false)
        precondition(archiveModel.selectedMeeting!.audioSegments!.count == 3)
        print("PASS: 本地双路音频保存、48k双声道归一化、关麦后电脑音频仍保存、过期回调不追加、暂停继续音频不覆盖")
        archiveModel.setSpeakerCount(2)
        archiveModel.setSpeakerCount(-1)
        precondition(archiveModel.expectedSpeakerCount == 2 && archiveModel.selectedMeeting!.speakerCountHint == 2)
        archiveModel.document.update(source: .system, start: 0, end: 0.2, text: "用于受控设备验证的文字", isFinal: true)
        await archiveModel.stop()
        precondition(archiveModel.speakersGenerating, "暂停后结束也必须安排会后声音分离")
        archiveModel.cancelSpeakerSeparation()
        await waitUntil { !archiveModel.speakersGenerating }
        precondition(!archiveModel.summaryGenerating && archiveModel.document.lines.count == 1)
        let archiveReload = MeetingModel(directory: directory, microphoneAccess: { true })
        archiveReload.loadMeetings()
        archiveReload.selectMeeting(archiveModel.selectedMeetingID!)
        precondition(archiveReload.expectedSpeakerCount == 2)
        print("PASS: 结束安排会后分离（含先暂停再结束）、取消保留原文、人数异常输入不修改及重启保持")
        let testAI = LocalMeetingAI(responseGenerator: { _, _ in
            try await Task.sleep(for: .milliseconds(80))
            return "{\"answer\":\"本机保存。\",\"citations\":[{\"id\":\"E1\",\"quote\":\"记录在本机保存。\"}]}"
        })
        let qaDirectory = directory.appendingPathComponent("qa-tests")
        let qaModel = MeetingModel(directory: qaDirectory, ai: testAI, microphoneAccess: { true })
        qaModel.createMeeting(title: "问答隔离一")
        qaModel.document.update(source: .system, start: 0, end: 1, text: "记录在本机保存。", isFinal: true)
        qaModel.saveSafely()
        let qaFirstID = qaModel.selectedMeetingID!
        qaModel.createMeeting(title: "问答隔离二")
        let qaSecondID = qaModel.selectedMeetingID!
        qaModel.selectMeeting(qaFirstID)
        qaModel.questionText = "在哪里保存？"; qaModel.askQuestion()
        precondition(qaModel.questioning && !qaModel.canManage && !qaModel.canTranscribe)
        qaModel.selectMeeting(qaSecondID); precondition(qaModel.selectedMeetingID == qaFirstID)
        await waitUntil { !qaModel.questioning }
        precondition(qaModel.selectedMeeting!.answers!.count == 1)
        qaModel.questionText = "在哪里保存？"; qaModel.askQuestion(); qaModel.cancelQuestion()
        await waitUntil { !qaModel.questioning }
        precondition(qaModel.selectedMeeting!.answers!.count == 1)
        let reference = qaModel.selectedMeeting!.answers![0].citations[0]
        qaModel.tab = .questions; qaModel.transcriptQuery = "不存在"; qaModel.sourceFilter = .microphone
        qaModel.locateCitation(reference)
        precondition(qaModel.tab == .transcript && qaModel.focusedLineID == qaModel.document.lines[0].id && qaModel.transcriptQuery.isEmpty && qaModel.sourceFilter == nil)
        qaModel.setNotes("验收方法：人工核对中文。")
        qaModel.locateCitation(MeetingCitation(lineID: nil, quote: "人工核对中文。", start: nil, source: nil, speaker: "会议笔记"))
        precondition(qaModel.tab == .notes)
        let qaReload = MeetingModel(directory: qaDirectory, ai: testAI)
        qaReload.loadMeetings(); qaReload.selectMeeting(qaFirstID)
        precondition(qaReload.selectedMeeting?.answers?.count == 1)
        qaModel.selectMeeting(qaSecondID); precondition(qaModel.selectedMeeting!.answers == nil)
        qaModel.selectMeeting(qaFirstID); qaModel.removeAnswer(qaModel.selectedMeeting!.answers![0].id)
        precondition(qaModel.selectedMeeting!.answers!.isEmpty)
        print("PASS: 原文问答保存、取消不追加、会议隔离、处理期禁切换和录制、引用定位清筛选、重启和删除问答")

    }
}

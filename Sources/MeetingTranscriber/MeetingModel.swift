import AppKit
import Combine
import AVFoundation
import Speech
import UniformTypeIdentifiers

enum LibraryScope: String, CaseIterable { case all = "全部会议", favorites = "收藏", trash = "最近删除" }
enum MeetingTab: String, CaseIterable { case transcript = "转写", notes = "笔记与待办", important = "重点", summary = "纪要", questions = "问答" }
enum ExportKind: String, CaseIterable { case text = "文本 TXT", markdown = "Markdown", subtitles = "字幕 SRT" }

@MainActor
final class MeetingModel: ObservableObject {
    @Published var document = TranscriptDocument()
    @Published var recording = false
    @Published var busy = false
    @Published var finishing = false
    @Published var modelReady = false
    @Published var status = "正在检查中文离线模型…"
    @Published var error: String?
    @Published var useMicrophone = false
    @Published var microphoneChanging = false
    @Published var systemLevel: Double = 0
    @Published var microphoneLevel: Double = 0
    @Published var savedURL: URL?
    @Published private(set) var meetings: [MeetingRecord] = []
    @Published private(set) var selectedMeetingID: UUID?
    @Published var libraryQuery = ""
    @Published var libraryScope: LibraryScope = .all
    @Published var folderFilter = ""
    @Published var tab: MeetingTab = .transcript
    @Published var transcriptQuery = ""
    @Published var sourceFilter: AudioSource?
    @Published var followLive = true
    @Published var elapsed: TimeInterval = 0
    @Published var paused = false
    @Published var lastSavedAt: Date?
    @Published var pendingSave = false
    @Published var undoDeletedID: UUID?
    @Published var importing = false
    @Published var summaryGenerating = false
    @Published var speakersGenerating = false
    @Published var questioning = false
    @Published var questionText = ""
    @Published var questionStatus = "依据本场原文与笔记回答，内容只在本机处理。"
    @Published var focusedLineID: UUID?
    let playback = MeetingPlayback()
    @Published var speakerStatus = "中文增强分离 · 在本机处理，可改名和逐段纠正。"
    @Published var expectedSpeakerCount = 0
    @Published var aiStatus = "正在检查本地 AI…"
    @Published var suggestedTasks: [SuggestedTask] = []
    @Published var taskText = ""
    @Published var taskOwner = ""
    @Published var taskDue = ""
    private var playbackObservation: AnyCancellable?
    private var saveTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var questionTask: Task<Void, Never>?
    private var speakerTask: Task<Void, Never>?
    private var archives: [AudioSource: (MeetingAudioSegment, MeetingAudioArchive)] = [:]
    private let preferences: UserDefaults?
    private var sessions: [AudioSource: SpeechSession] = [:]
    private var microphone: MicrophoneCapture?
    private var system: SystemAudioCapture?
    private var meterUpdates: [AudioSource: TimeInterval] = [:]
    private var saveTimer: Timer?
    private var startedUptime: TimeInterval = 0
    private var segmentOffset: TimeInterval = 0
    private var sourceOffsets: [AudioSource: TimeInterval] = [:]
    private var sessionIDs: [AudioSource: UUID] = [:]
    private var microphoneTask: Task<Void, Never>?
    private let directory: URL
    private let ai: LocalMeetingAI
    private let microphoneAccess: () async -> Bool
    private var store: MeetingStore { MeetingStore(directory: directory) }

    var selectedMeeting: MeetingRecord? { meetings.first { $0.id == selectedMeetingID } }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.huiji.meetingtranscriber/Meetings", isDirectory: true),
         preferences: UserDefaults? = nil,
         ai: LocalMeetingAI? = nil,
         microphoneAccess: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.directory = directory
        self.ai = ai ?? .shared
        self.microphoneAccess = microphoneAccess
        self.preferences = preferences
        playbackObservation = playback.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if let choice = preferences?.object(forKey: "useMicrophone") as? Bool { useMicrophone = choice }
    }

    func loadMeetings() {
        guard !recording, !busy else { return }
        do {
            let result = try store.loadReportingProblems()
            meetings = result.records
            let remembered = preferences?.string(forKey: "selectedMeetingID").flatMap(UUID.init(uuidString:))
            if let first = meetings.first(where: { $0.id == remembered && $0.deletedAt == nil }) ?? meetings.first(where: { $0.deletedAt == nil }) { selectMeeting(first.id) }
            if !result.warnings.isEmpty { error = result.warnings.joined(separator: "\n") }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func createMeeting(title: String) -> Bool {
        guard canManage else { return false }
        do {
            try save()
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            var meeting = MeetingRecord(title: name.isEmpty ? "会议 " + Date().formatted(date: .abbreviated, time: .shortened) : name,
                                        textFileName: "")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            meeting.textFileName = "会议_\(formatter.string(from: meeting.document.startedAt))_\(meeting.id.uuidString).txt"
            try store.save(meeting)
            meetings.insert(meeting, at: 0)
            playback.reset(); questionText = ""; questionStatus = "依据本场原文与笔记回答，内容只在本机处理。"; focusedLineID = nil
            selectedMeetingID = meeting.id
            preferences?.set(meeting.id.uuidString, forKey: "selectedMeetingID")
            elapsed = meeting.elapsed
            lastSavedAt = meeting.updatedAt
            sourceOffsets = [:]; segmentOffset = 0
            paused = false
            pendingSave = false
            suggestedTasks = meeting.suggestedTasks ?? []
            expectedSpeakerCount = meeting.speakerCountHint ?? 0
            speakerStatus = "中文增强分离 · 在本机处理，可改名和逐段纠正。"
            document = meeting.document
            savedURL = store.textURL(for: meeting)
            libraryScope = .all
            folderFilter = ""
            libraryQuery = ""
            tab = .transcript
            error = nil
            status = "会议已创建 · 点击开始转写"
            return true
        } catch { self.error = "会议创建失败：\(error.localizedDescription)"; return false }
    }

    func promptNewMeeting() {
        guard !recording, !busy, !microphoneChanging else { return }
        let alert = NSAlert()
        alert.messageText = "新建会议"
        alert.informativeText = "新会议从空记录开始，已有会议会继续保留。"
        let field = NSTextField(string: "会议 " + Date().formatted(date: .abbreviated, time: .shortened))
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.placeholderString = "会议名称"
        alert.accessoryView = field
        alert.addButton(withTitle: "创建会议")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { createMeeting(title: field.stringValue) }
    }

    func selectMeeting(_ id: UUID) {
        guard !recording, !busy, !microphoneChanging, id != selectedMeetingID,
              !summaryGenerating, !speakersGenerating, !questioning, let meeting = meetings.first(where: { $0.id == id }) else { return }
        do {
            try save()
            playback.reset(); questionText = ""; questionStatus = "依据本场原文与笔记回答，内容只在本机处理。"; focusedLineID = nil
            selectedMeetingID = id
            preferences?.set(id.uuidString, forKey: "selectedMeetingID")
            elapsed = meeting.elapsed
            lastSavedAt = meeting.updatedAt
            sourceOffsets = [:]; segmentOffset = 0
            paused = false
            pendingSave = false
            suggestedTasks = meeting.suggestedTasks ?? []
            transcriptQuery = ""; sourceFilter = nil
            taskText = ""; taskOwner = ""; taskDue = ""
            expectedSpeakerCount = meeting.speakerCountHint ?? 0
            speakerStatus = "中文增强分离 · 在本机处理，可改名和逐段纠正。"
            document = meeting.document
            savedURL = store.textURL(for: meeting)
            error = nil
            status = "已打开会议 · 记录保存在本机"
        } catch { self.error = "会议切换失败：\(error.localizedDescription)" }
    }

    func checkModel() async {
        do {
            let module = try await ChineseModel.transcriber()
            modelReady = await AssetInventory.status(forModules: [module]) == .installed
            status = modelReady ? "中文模型已就绪 · 可离线使用" : "首次使用，请先准备中文离线模型"
        } catch { self.error = error.localizedDescription; status = "中文模型不可用" }
    }

    func prepareModel() async {
        guard !busy, !recording else { return }
        busy = true
        error = nil
        status = "正在准备中文模型，首次下载需要联网…"
        defer { busy = false }
        do { try await ChineseModel.prepare(); await checkModel() }
        catch { self.error = error.localizedDescription; status = "模型准备失败，请联网后重试" }
    }

    func start() async {
        guard !busy, !recording, modelReady, canTranscribe, let meeting = selectedMeeting else { return }
        playback.reset()
        busy = true
        error = nil
        defer { busy = false }
        do {
            if useMicrophone {
                let allowed = await microphoneAccess()
                guard allowed else { throw MeetingError.message("麦克风权限未开启。请在系统设置中允许会记使用麦克风，或关闭“我的麦克风”开关。") }
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            status = "正在启动中文识别…"
            try await startSession(for: .system)
            try save()
            segmentOffset = max(meeting.elapsed, document.lines.map(\.end).max() ?? 0)
            startedUptime = ProcessInfo.processInfo.systemUptime
            sourceOffsets = [.system: segmentOffset]
            try startArchive(for: .system)
            let systemCapture = SystemAudioCapture()
            system = systemCapture
            try systemCapture.start(receive: handler(for: .system))
            if useMicrophone {
                try await startMicrophone(onlyWhileRecording: false)
            }
            if let error { throw MeetingError.message(error) }
            recording = true
            paused = false
            elapsed = segmentOffset
            status = "正在转写 · 中文（简体）· 本机离线"
            saveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.elapsed = self.segmentOffset + ProcessInfo.processInfo.systemUptime - self.startedUptime
                    if Int(self.elapsed) % 5 == 0 { self.saveSafely() }
                }
            }
        } catch {
            self.error = error.localizedDescription
            await stop()
            status = "未能开始转写"
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        guard !busy, !microphoneChanging else { return }
        useMicrophone = enabled
        preferences?.set(enabled, forKey: "useMicrophone")
        guard recording else { return }
        if enabled { error = nil }
        microphoneChanging = true
        if !enabled {
            // Release the device immediately; only already captured audio is finalized below.
            microphone?.stop()
            microphone = nil
            microphoneLevel = 0
        }
        microphoneTask = Task {
            defer { microphoneChanging = false; microphoneTask = nil }
            if enabled {
                do { try await startMicrophone(onlyWhileRecording: true) }
                catch {
                    useMicrophone = false
                    microphone?.stop()
                    microphone = nil
                    await finishMicrophone()
                    self.error = "麦克风未能开启：\(error.localizedDescription) 电脑声音继续转写。"
                }
            } else {
                await finishMicrophone()
            }
        }
    }

    private func startSession(for source: AudioSource) async throws {
        let id = UUID()
        sessionIDs[source] = id
        sessions[source] = try await SpeechSession.start { [weak self] result in
            guard let self, self.sessionIDs[source] == id else { return }
            self.received(result, source: source)
        } onError: { [weak self] error in
            guard let self, self.sessionIDs[source] == id else { return }
            if source == .microphone, self.recording {
                self.error = "麦克风识别失败：\(error.localizedDescription) 电脑声音继续转写。"
                self.microphone?.stop()
                self.microphone = nil
                self.microphoneLevel = 0
                Task {
                    await self.microphoneTask?.value
                    guard self.recording, self.sessionIDs[source] == id else { return }
                    self.setMicrophoneEnabled(false)
                }
            } else { self.failed(error) }
        }
    }

    private func startMicrophone(onlyWhileRecording: Bool) async throws {
        guard !onlyWhileRecording || recording else { return }
        let allowed = await microphoneAccess()
        guard !onlyWhileRecording || recording else { return }
        guard allowed else {
            throw MeetingError.message("请在系统设置中允许会记使用麦克风。")
        }
        try await startSession(for: .microphone)
        guard !onlyWhileRecording || recording else { return }
        sourceOffsets[.microphone] = segmentOffset + ProcessInfo.processInfo.systemUptime - startedUptime
        try startArchive(for: .microphone)
        meterUpdates[.microphone] = nil
        let capture = MicrophoneCapture()
        microphone = capture
        try capture.start(receive: handler(for: .microphone))
    }

    private func finishMicrophone() async {
        finishArchive(for: .microphone)
        let session = sessions[.microphone]
        do { try await session?.finish() }
        catch { self.error = "麦克风最后的文字未能完成：\(error.localizedDescription) 电脑声音继续转写。" }
        sessions[.microphone] = nil
        sessionIDs[.microphone] = nil
        microphoneLevel = 0
        do { try save() } catch { failed(error) }
    }

    private func handler(for source: AudioSource) -> (AVAudioPCMBuffer) -> Void {
        let input = sessions[source]!.input
        let archive = archives[source]?.1
        return { [weak self] buffer in
            let level = audioLevel(buffer)
            let receivedAt = ProcessInfo.processInfo.systemUptime
            input.submit(buffer)
            archive?.submit(buffer)
            Task { @MainActor in
                guard let self, self.sessions[source]?.input === input,
                      source != .microphone || self.microphone != nil else { return }
                if self.sourceOffsets[source] == nil { self.sourceOffsets[source] = self.segmentOffset + receivedAt - self.startedUptime }
                if receivedAt - (self.meterUpdates[source] ?? 0) > 0.1 {
                    self.meterUpdates[source] = receivedAt
                    if source == .system { self.systemLevel = level } else { self.microphoneLevel = level }
                }
            }
        }
    }

    private func received(_ result: SpeechTranscriber.Result, source: AudioSource) {
        let offset = sourceOffsets[source] ?? segmentOffset
        let tokens = result.isFinal ? result.text.runs.map { run -> TranscriptToken in
                let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] ?? result.range
                return TranscriptToken(text: String(result.text[run.range].characters), start: range.start.seconds + offset,
                                       end: range.end.seconds + offset)
            } : nil
        document.update(source: source, start: result.range.start.seconds + offset, end: result.range.end.seconds + offset,
                        text: String(result.text.characters), isFinal: result.isFinal, tokens: tokens)
        pendingSave = true
        if result.isFinal { saveSafely() }
    }

    private func failed(_ error: Error) {
        self.error = error.localizedDescription
        if recording && !busy { Task { await stop(summarize: false) } }
    }

    func stop(pausing: Bool = false, summarize: Bool = true) async {
        let wasRecording = recording
        let wasPaused = paused
        guard !finishing else { return }
        finishing = true
        defer { finishing = false }
        let previouslyBusy = busy
        if system != nil, let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }) {
            meetings[index].elapsed = max(meetings[index].elapsed, segmentOffset + ProcessInfo.processInfo.systemUptime - startedUptime)
        }
        busy = true
        recording = false
        status = "正在保存最后的转写文字…"
        saveTimer?.invalidate()
        saveTimer = nil
        system?.stop()
        microphone?.stop()
        system = nil
        microphone = nil
        finishArchive(for: .system)
        finishArchive(for: .microphone)
        await microphoneTask?.value
        let active = sessions
        sessions = [:]
        // End both channels before awaiting either one, so neither microphone nor tap stays open.
        for session in active.values { session.input.finish() }
        for session in active.values {
            do { try await session.finish() }
            catch { if self.error == nil { self.error = error.localizedDescription } }
        }
        sessionIDs = [:]
        do { try save() } catch { self.error = "记录保存失败：\(error.localizedDescription)" }
        systemLevel = 0
        microphoneLevel = 0
        elapsed = selectedMeeting?.elapsed ?? elapsed
        paused = pausing
        status = error == nil ? (pausing ? "已暂停 · 两路声音均已停止采集" : "会议已结束 · 记录已保存在本机") : "已停止 · 请查看提示"
        busy = previouslyBusy
        if (wasRecording || wasPaused) && !pausing && summarize && error == nil && selectedMeeting?.hasContent == true {
            if hasSpeakerAudio { separateSpeakers(summarizeAfter: true) }
            else { generateSummary() }
        }
    }

    func shutdown() async {
        playback.reset()
        questionTask?.cancel()
        await questionTask?.value
        importTask?.cancel()
        summaryTask?.cancel()
        speakerTask?.cancel()
        await importTask?.value
        await summaryTask?.value
        await speakerTask?.value
        if !finishing { await stop(summarize: false) }
        saveTask?.cancel()
        saveSafely()
        ai.shutdown()
        while finishing { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func save() throws {
        guard let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }) else { return }
        saveTask?.cancel()
        if pendingSave || meetings[index].document != document { meetings[index].updatedAt = Date() }
        meetings[index].document = document
        if recording {
            meetings[index].elapsed = max(meetings[index].elapsed, segmentOffset + ProcessInfo.processInfo.systemUptime - startedUptime)
        }
        try store.save(meetings[index])
        pendingSave = false
        lastSavedAt = Date()
    }

    var visibleMeetings: [MeetingRecord] {
        let query = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return meetings.filter { record in
            let scope = libraryScope == .trash ? record.deletedAt != nil : record.deletedAt == nil
            return scope && (libraryScope != .favorites || record.isFavorite == true)
                && (folderFilter.isEmpty || record.folder == folderFilter)
                && (query.isEmpty || record.searchableText.localizedCaseInsensitiveContains(query))
        }.sorted { libraryScope == .trash ? ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) : $0.updatedAt > $1.updatedAt }
    }
    var folders: [String] { Array(Set(meetings.filter { $0.deletedAt == nil }.compactMap(\.folder).filter { !$0.isEmpty })).sorted() }
    var canManage: Bool { !recording && !busy && !microphoneChanging && !summaryGenerating && !speakersGenerating && !questioning }
    var canTranscribe: Bool { selectedMeeting != nil && selectedMeeting?.deletedAt == nil && !summaryGenerating && !speakersGenerating && !questioning }
    var filteredLines: [TranscriptLine] {
        document.lines.filter { (sourceFilter == nil || $0.source == sourceFilter)
            && (transcriptQuery.isEmpty || $0.text.localizedCaseInsensitiveContains(transcriptQuery))
            && (tab != .important || $0.isImportant == true) }
    }
    var inputHint: String? {
        if recording && elapsed - segmentOffset > 20 && systemLevel < 0.001 && document.lines.last.map({ elapsed - $0.end > 20 }) != false {
            return "暂未检测到电脑语音。确认 Zoom 正在播放声音，并查看上方音量指示。"
        }
        return nil
    }

    func saveSafely() {
        do { try save() } catch { self.error = "保存失败：\(error.localizedDescription)。请重试保存或先导出记录。"; pendingSave = true }
    }
    private func changed(debounce: Bool = false) {
        pendingSave = true
        saveTask?.cancel()
        if debounce {
            saveTask = Task {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                saveSafely()
            }
        } else { saveSafely() }
    }
    private func modifySelected(_ operation: (inout MeetingRecord) -> Void, debounce: Bool = false) {
        guard let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }), meetings[index].deletedAt == nil else { return }
        operation(&meetings[index])
        changed(debounce: debounce)
    }
    func setNotes(_ value: String) { modifySelected({ $0.notes = value }, debounce: true) }
    func setSummary(_ value: String) { modifySelected({ $0.summary = value }, debounce: true) }
    func toggleFavorite() { modifySelected { $0.isFavorite = !($0.isFavorite ?? false) } }
    func renameSelected(_ name: String) {
        guard canManage, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        modifySelected { $0.title = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    func setFolder(_ name: String) { modifySelected { $0.folder = name.trimmingCharacters(in: .whitespacesAndNewlines) } }
    func promptRename() {
        guard let record = selectedMeeting, canManage,
            let name = prompt("重命名会议", value: record.title) else { return }
        renameSelected(name)
    }
    func promptFolder() {
        guard selectedMeeting != nil, canManage,
            let name = prompt("移入文件夹", detail: "输入已有或新文件夹名称，留空可移出文件夹。", value: selectedMeeting?.folder ?? "") else { return }
        setFolder(name)
    }
    private func prompt(_ title: String, detail: String = "", value: String) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    func deleteSelected() {
        guard canManage, let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }), meetings[index].deletedAt == nil else { return }
        do {
            try save()
            var record = meetings[index]; record.deletedAt = Date()
            try store.save(record); playback.reset(); meetings[index] = record; undoDeletedID = record.id
            status = "已移入最近删除，可撤销或恢复"
        } catch { self.error = "删除失败：\(error.localizedDescription)" }
    }
    func restore(_ id: UUID) {
        guard canManage, let index = meetings.firstIndex(where: { $0.id == id }), meetings[index].deletedAt != nil else { return }
        do {
            var record = meetings[index]; record.deletedAt = nil
            try store.save(record); meetings[index] = record; undoDeletedID = nil
            libraryScope = .all; folderFilter = ""; libraryQuery = ""
            if selectedMeetingID != id { selectMeeting(id) }
            status = "会议已恢复"
        } catch { self.error = "恢复失败：\(error.localizedDescription)" }
    }
    func permanentlyDeleteSelected() {
        guard canManage, let record = selectedMeeting, record.deletedAt != nil else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "永久删除“\(record.title)”？"
        alert.informativeText = "转写、本地音频、笔记、待办和纪要都会从本机删除，无法恢复。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "永久删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try store.permanentlyDelete(record)
            meetings.removeAll { $0.id == record.id }
            selectedMeetingID = nil; document = TranscriptDocument(); savedURL = nil
            if undoDeletedID == record.id { undoDeletedID = nil }
            status = "会议已永久删除"
        } catch { self.error = "永久删除未完成：\(error.localizedDescription)" }
    }
    func toggleImportant(_ id: UUID) { document.toggleImportant(id); changed() }
    func editLine(_ id: UUID, text: String) { guard canManage else { return }; document.edit(id, text: text); changed() }
    func promptEditLine(_ line: TranscriptLine) {
        guard canManage, line.isFinal else { return }
        let alert = NSAlert(); alert.messageText = "校对转写"; alert.informativeText = "修改后保留识别原文，可恢复。"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 150)); scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.string = line.text; text.font = .systemFont(ofSize: 15)
        scroll.documentView = text; alert.accessoryView = scroll; alert.window.initialFirstResponder = text
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { editLine(line.id, text: text.string) }
    }
    func restoreOriginal(_ line: TranscriptLine) { if let original = line.originalText { editLine(line.id, text: original) } }
    func addTask(text: String, owner: String = "", due: String = "") {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        modifySelected { record in
            var tasks = record.tasks ?? []
            tasks.append(MeetingTask(text: text.trimmingCharacters(in: .whitespacesAndNewlines), owner: owner, due: due))
            record.tasks = tasks
        }
    }
    func addDraftTask() { addTask(text: taskText, owner: taskOwner, due: taskDue); taskText = ""; taskOwner = ""; taskDue = "" }
    func toggleTask(_ id: UUID) { modifySelected { record in
        if let index = record.tasks?.firstIndex(where: { $0.id == id }) { record.tasks![index].done.toggle() }
    } }
    func removeTask(_ id: UUID) { modifySelected { $0.tasks?.removeAll { $0.id == id } } }
    func promptEditTask(_ task: MeetingTask) {
        guard let text = prompt("编辑待办", value: task.text), !text.isEmpty,
              let owner = prompt("负责人", value: task.owner), let due = prompt("截止时间", value: task.due) else { return }
        modifySelected { record in
            if let index = record.tasks?.firstIndex(where: { $0.id == task.id }) {
                record.tasks![index].text = text; record.tasks![index].owner = owner; record.tasks![index].due = due
            }
        }
    }
    func acceptSuggested(_ task: SuggestedTask) {
        addTask(text: task.text, owner: task.owner, due: task.due)
        suggestedTasks.removeAll { $0.id == task.id }
        modifySelected { $0.suggestedTasks = suggestedTasks }
    }
    func dismissSuggested(_ task: SuggestedTask) { suggestedTasks.removeAll { $0.id == task.id }; modifySelected { $0.suggestedTasks = suggestedTasks } }
    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedMeeting?.transcriptText ?? document.plainText, forType: .string)
        status = "转写内容已复制"
    }
    func export(_ kind: ExportKind = .text) {
        guard let record = selectedMeeting else { return }
        if kind == .subtitles && (record.legacyText != nil || document.lines.isEmpty) {
            error = "旧版文本缺少完整结束时间，不能导出准确字幕；请选择 TXT 或 Markdown。"; return
        }
        let panel = NSSavePanel()
        let ext = kind == .text ? "txt" : kind == .markdown ? "md" : "srt"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = record.title.replacingOccurrences(of: "/", with: "-") + "." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try save()
            let updated = selectedMeeting!
            let output = kind == .text ? updated.plainText : kind == .markdown ? updated.markdown : document.subtitles
            try output.write(to: url, atomically: true, encoding: .utf8)
            status = "\(kind.rawValue) 已导出"
        } catch { self.error = "导出失败：\(error.localizedDescription)" }
    }
    func promptImport() {
        guard canManage else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.message = "选择录音文件，本机中文识别。会记会保存本地音频副本，用于会后分离说话人；原文件不移动，音频不上传。"
        if panel.runModal() == .OK, let url = panel.url { importAudio(url) }
    }
    func importAudio(_ url: URL) {
        guard canManage, modelReady, createMeeting(title: url.deletingPathExtension().lastPathComponent) else { return }
        busy = true; importing = true; error = nil; status = "正在本机转写录音…"
        importTask = Task { [self] in
            var completed = false
            defer {
                busy = false; importing = false; importTask = nil
                if completed { separateSpeakers() }
            }
            do {
                guard let record = selectedMeeting else { return }
                var segment = MeetingAudioSegment(source: .imported, start: 0, fileName: UUID().uuidString + ".wav")
                let audioURL = try store.audioURL(for: segment, in: record)
                do {
                    segment.duration = try await MeetingAudioArchive.copyFile(url, to: audioURL)
                    try Task.checkCancellation()
                } catch { try? FileManager.default.removeItem(at: audioURL); throw error }
                modifySelected { $0.audioSegments = [segment] }
                let length = try await SpeechSession.transcribeFile(url: url) { [weak self] result in
                    guard let self else { return }
                    self.received(result, source: .imported)
                    self.elapsed = max(self.elapsed, result.range.end.seconds)
                }
                if let index = meetings.firstIndex(where: { $0.id == selectedMeetingID }) { meetings[index].elapsed = length }
                elapsed = length; saveSafely(); status = "录音转写完成 · 记录已保存"
                completed = true
            } catch {
                saveSafely()
                if Task.isCancelled { status = "导入已取消 · 已识别文字保留" }
                else { self.error = "录音转写失败：\(error.localizedDescription)" }
            }
        }
    }
    func cancelImport() { importTask?.cancel() }

    private func startArchive(for source: AudioSource) throws {
        guard let record = selectedMeeting else { return }
        let segment = MeetingAudioSegment(source: source, start: sourceOffsets[source] ?? segmentOffset,
                                          fileName: UUID().uuidString + ".wav")
        let archive = try MeetingAudioArchive(url: store.audioURL(for: segment, in: record))
        archives[source] = (segment, archive)
        modifySelected { if $0.audioSegments == nil { $0.audioSegments = [] }; $0.audioSegments!.append(segment) }
    }

    private func finishArchive(for source: AudioSource) {
        guard var pair = archives.removeValue(forKey: source), let record = selectedMeeting else { return }
        do {
            pair.0.duration = try pair.1.finish()
            if pair.0.duration == 0 {
                try? FileManager.default.removeItem(at: store.audioURL(for: pair.0, in: record))
                modifySelected { $0.audioSegments?.removeAll { $0.id == pair.0.id } }
            } else {
                modifySelected { meeting in
                    if let index = meeting.audioSegments?.firstIndex(where: { $0.id == pair.0.id }) { meeting.audioSegments![index] = pair.0 }
                }
            }
        } catch { self.error = "本地音频保存未完成：\(error.localizedDescription)。转写文字已保留，声音分离可能不完整。" }
    }

    var hasSpeakerAudio: Bool { !(selectedMeeting?.audioSegments ?? []).isEmpty }
    var meetingSpeakers: [MeetingSpeaker] { document.speakers ?? [] }

    func separateSpeakers(summarizeAfter: Bool = false) {
        guard canManage, hasSpeakerAudio, let record = selectedMeeting, record.deletedAt == nil else { return }
        saveSafely(); speakersGenerating = true; error = nil
        speakerStatus = "正在本机分离说话人，音频不上传…"
        let count = expectedSpeakerCount
        speakerTask = Task { [self] in
            do {
                let turns = try await LocalSpeakerDiarizer().analyze(record, store: store, speakerCount: count)
                try Task.checkCancellation()
                guard !turns.isEmpty else { throw MeetingError.message("未检测到可分离的发言，请检查录音。原有归属保留。") }
                document.applySpeakerTurns(document.reconciledSpeakerTurns(turns))
                changed()
                speakerStatus = "分离完成 · 请校对姓名和归属；若人数不准，选人数重新分离。重叠或不明确的发言可能标为未确定。"
            } catch {
                if Task.isCancelled { speakerStatus = "已取消分离 · 原有姓名和归属保留" }
                else { self.error = error.localizedDescription; speakerStatus = "分离未完成，转写和音频保留，可重试。" }
            }
            speakersGenerating = false; speakerTask = nil
            if summarizeAfter && !Task.isCancelled { generateSummary() }
        }
    }
    func cancelSpeakerSeparation() { speakerTask?.cancel() }
    func setSpeakerCount(_ count: Int) {
        guard canManage, (0...12).contains(count) else { return }
        expectedSpeakerCount = count
        modifySelected { $0.speakerCountHint = count }
    }
    func renameSpeaker(_ id: String, name: String) {
        guard canManage else { return }
        document.renameSpeaker(id, name: name); changed()
    }
    func promptSpeakerName(_ speaker: MeetingSpeaker) {
        guard canManage, let name = prompt("修改说话人姓名", detail: "本场会议中属于此人的段落会同步更新；不会修改其他会议。", value: speaker.name) else { return }
        renameSpeaker(speaker.id, name: name)
    }
    func assignSpeaker(_ line: TranscriptLine, id: String?) {
        guard canManage else { return }
        document.assignSpeaker(line.id, speakerID: id); changed()
    }
    func promptNewSpeaker(for line: TranscriptLine) {
        guard canManage, let name = prompt("新增说话人", detail: "为这一段指定新说话人，之后可用于纠正其他段落。", value: ""),
              let id = document.addSpeaker(name: name) else { return }
        document.assignSpeaker(line.id, speakerID: id); changed()
    }
    func checkAI() async { aiStatus = await ai.availability() }
    func generateSummary() {
        guard canManage, let record = selectedMeeting, record.deletedAt == nil else { return }
        guard record.hasContent || !(record.notes ?? "").isEmpty else { error = "请先转写会议或填写笔记。"; return }
        saveSafely(); summaryGenerating = true; tab = .summary; error = nil
        let input = record.transcriptText + "\n会议笔记：\n" + (record.notes ?? "")
        summaryTask = Task { [self] in
            defer { summaryGenerating = false; summaryTask = nil }
            do {
                let result = try await ai.summarize(input, template: record.summaryTemplate ?? .work) { [weak self] in self?.aiStatus = $0 }
                try Task.checkCancellation()
                suggestedTasks = result.tasks
                modifySelected { $0.summary = result.formatted; $0.summaryGeneratedAt = Date(); $0.summaryGeneratedTemplate = record.summaryTemplate ?? .work; $0.suggestedTasks = result.tasks }
                aiStatus = "已在本机生成 · 请校对纪要，确认待办后加入列表"
            } catch {
                if Task.isCancelled { aiStatus = "已取消整理 · 原有纪要保留" }
                else { self.error = error.localizedDescription; aiStatus = "整理未完成，可以重试" }
            }
        }
    }
    func cancelSummary() { summaryTask?.cancel() }

    var canReviewAudio: Bool { !recording && !busy && !microphoneChanging }
    func refreshPlayback() {
        guard canReviewAudio else { return }
        playback.configure(selectedMeeting, store: store)
    }
    func playLine(_ line: TranscriptLine) {
        guard canReviewAudio else { return }
        focusedLineID = nil
        refreshPlayback()
        guard playback.sources.contains(line.source) else { error = "这一段没有保存对应的声音来源。"; return }
        playback.pause()
        playback.selectSource(line.source)
        if playback.seek(line.start) { playback.play() }
    }
    var activePlaybackLineID: UUID? {
        guard playback.isPlaying else { return nil }
        return document.lines.last { $0.source == playback.source && $0.start <= playback.position && $0.end > playback.position }?.id
    }
    func locateCitation(_ citation: MeetingCitation) {
        if citation.lineID == nil {
            if citation.speaker == "会议笔记", selectedMeeting?.notes?.contains(citation.quote) == true {
                tab = .notes; status = "已定位会议笔记 · 该引用没有录音时间"; return
            }
            if selectedMeeting?.legacyText?.contains(citation.quote) == true {
                transcriptQuery = citation.quote; sourceFilter = nil; focusedLineID = nil; tab = .transcript
                status = "已定位历史原文 · 该引用没有录音时间"; return
            }
        }
        let line = document.lines.first { $0.id == citation.lineID && $0.text.contains(citation.quote) }
            ?? document.lines.first { $0.text.contains(citation.quote) }
        guard let line else { error = "引用来自笔记、历史原文，或原文已修改；请直接核对引用内容。"; return }
        transcriptQuery = ""; sourceFilter = nil; focusedLineID = line.id; tab = .transcript
        if canReviewAudio {
            refreshPlayback(); playback.pause()
            if playback.sources.contains(line.source) { playback.selectSource(line.source); playback.seek(line.start) }
        }
    }
    func setSummaryTemplate(_ value: SummaryTemplate) {
        guard canManage else { return }
        modifySelected { $0.summaryTemplate = value }
    }
    func askQuestion() {
        guard canManage, let record = selectedMeeting, record.deletedAt == nil else { return }
        let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 500 else { error = "请输入 1–500 字的问题。"; return }
        saveSafely(); questioning = true; error = nil
        questionTask = Task { [self] in
            defer { questioning = false; questionTask = nil }
            do {
                let result = try await ai.answer(question, record: record) { [weak self] in self?.questionStatus = $0 }
                try Task.checkCancellation()
                guard selectedMeetingID == record.id else { return }
                modifySelected { if $0.answers == nil { $0.answers = [] }; $0.answers!.append(result) }
                questionText = ""; questionStatus = "回答已保存在本场会议 · 点击引用定位原文"
            } catch {
                if Task.isCancelled { questionStatus = "已取消问答 · 已保存的回答保留" }
                else { self.error = error.localizedDescription; questionStatus = "问答未完成，可重试" }
            }
        }
    }
    func cancelQuestion() { questionTask?.cancel() }
    func removeAnswer(_ id: UUID) { guard canManage else { return }; modifySelected { $0.answers?.removeAll { $0.id == id } } }

    func showRecords() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch { self.error = error.localizedDescription }
    }
}

import AppKit
import SwiftUI
import Speech
import AVFoundation

@main
struct MeetingTranscriberApp {
    static var isDiagnostic: Bool {
        CommandLine.arguments.contains { ["--prepare-model", "--check-model", "--transcribe-file"].contains($0) }
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(isDiagnostic ? .prohibited : .regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MeetingModel(preferences: .standard)
    let environment = EnvironmentSetup()
    private var window: NSWindow?
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if MeetingTranscriberApp.isDiagnostic {
            Task {
                do { try await runDiagnostic(); exit(0) }
                catch { fputs("ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            return
        }
        if let iconURL = Bundle.main.url(forResource: "HuijiIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) { NSApplication.shared.applicationIconImage = icon }
        model.loadMeetings()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "会记"
        window.minSize = NSSize(width: 980, height: 520)
        window.contentView = NSHostingView(rootView: MeetingView(model: model, environment: environment))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: "关于会记", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        let environmentItem = appMenu.addItem(withTitle: "模型与环境…", action: #selector(showEnvironment), keyEquivalent: ",")
        environmentItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出会记", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApplication.shared.mainMenu = menu
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task {
            await model.checkModel()
            await environment.check()
            await model.checkAI()
            if !UserDefaults.standard.bool(forKey: "environmentGuideShown") {
                UserDefaults.standard.set(true, forKey: "environmentGuideShown")
                environment.isPresented = true
            }
        }
    }

    @objc private func showEnvironment() {
        guard !model.recording, !model.busy, !model.paused, !model.summaryGenerating, !model.speakersGenerating, !model.questioning else { return }
        environment.isPresented = true
        Task { await environment.check() }
    }

    @objc private func showAbout() {
        if let aboutWindow { aboutWindow.makeKeyAndOrderFront(nil); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "关于会记"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: AboutView(onClose: { [weak panel] in panel?.close() }))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        aboutWindow = panel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        environment.cancel()
        Task { await environment.waitUntilFinished(); await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    private func runDiagnostic() async throws {
        let arguments = CommandLine.arguments
        if arguments.contains("--prepare-model") {
            try await ChineseModel.prepare()
            print("CHINESE_MODEL_INSTALLED")
        } else if arguments.contains("--check-model") {
            let module = try await ChineseModel.transcriber()
            print("CHINESE_MODEL_STATUS \(await AssetInventory.status(forModules: [module]))")
        } else if let index = arguments.firstIndex(of: "--transcribe-file"), arguments.count > index + 1 {
            let module = try await ChineseModel.transcriber()
            guard await AssetInventory.status(forModules: [module]) == .installed else {
                throw MeetingError.message("请先准备中文模型。")
            }
            var document = TranscriptDocument()
            var failure: Error?
            var sessions: [SpeechSession] = []
            do {
                let sources: [AudioSource] = arguments.contains("--two-channels") ? [.system, .microphone] : [.system]
                for source in sources {
                    sessions.append(try await SpeechSession.start { result in
                        document.update(source: source, start: result.range.start.seconds, end: result.range.end.seconds,
                                        text: String(result.text.characters), isFinal: result.isFinal)
                    } onError: { failure = $0 })
                }
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[index + 1]))
                while file.framePosition < file.length {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                        throw MeetingError.message("无法读取测试音频。")
                    }
                    try file.read(into: buffer)
                    for session in sessions { session.input.submit(buffer) }
                }
                for session in sessions { session.input.finish() }
                for session in sessions { try await session.finish() }
                if let failure { throw failure }
                if let exportIndex = arguments.firstIndex(of: "--export"), arguments.count > exportIndex + 1 {
                    try document.save(to: URL(fileURLWithPath: arguments[exportIndex + 1]))
                }
                print(document.plainText)
            } catch {
                for session in sessions { try? await session.finish() }
                throw error
            }
        } else { throw MeetingError.message("未知的诊断参数。") }
    }
}

struct AboutView: View {
    let onClose: () -> Void
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "版本 \(info["CFBundleShortVersionString"] as? String ?? "—")（\(info["CFBundleVersion"] as? String ?? "—")）"
    }

    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 88, height: 88)
                    .accessibilityLabel("会记图标")
            }
            VStack(spacing: 5) {
                Text("会记").font(.system(size: 26, weight: .bold))
                Text(version).font(.caption).foregroundStyle(.secondary)
            }
            Text("让每场会议留下清晰记录").font(.headline)
            VStack(spacing: 6) {
                Text("中文实时转写 · 笔记与待办 · 本地 AI 纪要")
                Text("会后说话人分离 · 人工校对 · 带姓名导出")
            }.font(.callout).foregroundStyle(.secondary)
            Divider()
            VStack(spacing: 6) {
                Label("会议音频和记录只在这台 Mac 上处理与保存", systemImage: "lock.shield")
                    .foregroundStyle(.teal)
                Text("模型首次下载需要联网，转写与分析可离线使用。")
                Text("自动分人和 AI 纪要可能出错，请结合原文校对。")
                    .foregroundStyle(.secondary)
            }.font(.caption)
            Spacer(minLength: 0)
            HStack {
                Link("GitHub 源码与使用说明", destination: URL(string: "https://github.com/Aronlele/huiji")!)
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
            }.font(.callout)
        }.padding(30).frame(width: 520, height: 470)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct MeetingView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var environment: EnvironmentSetup
    private var accent: Color { .teal }

    var body: some View {
        HStack(spacing: 0) {
            library.frame(width: 250)
            Divider()
            VStack(spacing: 0) {
                if let meeting = model.selectedMeeting {
                    header(meeting)
                    Divider()
                    if meeting.deletedAt != nil { deletedMeeting(meeting) }
                    else {
                        audioBar
                        Divider()
                        tabs
                        Divider()
                        MeetingPlaybackView(model: model, playback: model.playback)
                        Divider()
                        Group {
                            switch model.tab {
                            case .transcript, .important: transcript
                            case .notes: notes
                            case .summary: summary
                            case .questions: MeetingQuestionsView(model: model, environment: environment)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ContentUnavailableView {
                        Label("让每场会议留下清晰记录", systemImage: "waveform.and.mic")
                    } description: {
                        Text("先创建会议，再开始中文转写。电脑声音、笔记与待办保存在一起，内容只在本机处理。")
                    } actions: {
                        Button("新建会议") { model.promptNewMeeting() }.buttonStyle(.borderedProminent).tint(accent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                footer
            }
        }.background(Color(nsColor: .windowBackgroundColor))
            .sheet(isPresented: $environment.isPresented) { EnvironmentView(setup: environment) }
            .onChange(of: environment.isPresented) { _, presented in
                if !presented { Task { await model.checkModel(); await model.checkAI() } }
            }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("会记", systemImage: "waveform").font(.title2.bold()).foregroundStyle(accent)
                Spacer()
                Button { model.promptNewMeeting() } label: { Image(systemName: "plus") }
                    .help("新建会议").disabled(!model.canManage).keyboardShortcut("n", modifiers: .command)
            }.padding(.top, 22)
            TextField("搜索会议、转写、笔记…", text: $model.libraryQuery).textFieldStyle(.roundedBorder)
            VStack(spacing: 4) {
                ForEach(LibraryScope.allCases, id: \.self) { scope in
                    Button {
                        model.libraryScope = scope; model.folderFilter = ""
                    } label: {
                        HStack {
                            Image(systemName: scope == .all ? "tray.full" : scope == .favorites ? "star" : "trash")
                            Text(scope.rawValue); Spacer()
                            Text("\(model.meetings.filter { scope == .trash ? $0.deletedAt != nil : $0.deletedAt == nil && (scope != .favorites || $0.isFavorite == true) }.count)").foregroundStyle(.secondary)
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                            .background(model.libraryScope == scope && model.folderFilter.isEmpty ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                if !model.folders.isEmpty {
                    Menu {
                        Button("全部文件夹") { model.folderFilter = "" }
                        ForEach(model.folders, id: \.self) { folder in Button(folder) { model.libraryScope = .all; model.folderFilter = folder } }
                    } label: {
                        HStack { Label(model.folderFilter.isEmpty ? "文件夹" : model.folderFilter, systemImage: "folder"); Spacer(); Image(systemName: "chevron.down") }
                    }.padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
            Divider()
            HStack { Text(model.folderFilter.isEmpty ? model.libraryScope.rawValue : model.folderFilter).font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Text("\(model.visibleMeetings.count)").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.visibleMeetings) { meeting in
                        Button { model.selectMeeting(meeting.id) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .top) {
                                    Text(meeting.title).font(.callout.weight(.medium)).lineLimit(2)
                                    Spacer(minLength: 0)
                                    if meeting.isFavorite == true { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) }
                                }
                                HStack { Text(meeting.document.startedAt.formatted(date: .abbreviated, time: .shortened)); Spacer(); Text(durationText(meeting.elapsed)) }.font(.caption2).foregroundStyle(.secondary)
                                if let folder = meeting.folder, !folder.isEmpty { Label(folder, systemImage: "folder").font(.caption2).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(meeting.id == model.selectedMeetingID ? accent.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(!model.canManage)
                    }
                    if model.visibleMeetings.isEmpty {
                        Text(model.libraryQuery.isEmpty ? "这里还没有会议" : "没有找到匹配内容").font(.callout).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                }
            }
            Button("导入录音", systemImage: "square.and.arrow.down") { model.promptImport() }
                .frame(maxWidth: .infinity).disabled(!model.canManage || !model.modelReady)
            Button("打开本机记录目录", systemImage: "folder") { model.showRecords() }.font(.caption)
            Button("模型与环境", systemImage: "arrow.down.circle") {
                environment.isPresented = true
                Task { await environment.check() }
            }.font(.caption).disabled(!model.canManage || model.paused)
            Label("内容仅在本机处理", systemImage: "lock.shield").font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.bottom, 18).background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private func header(_ meeting: MeetingRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title).font(.title2.bold()).lineLimit(1)
                HStack(spacing: 12) {
                    Text(meeting.document.startedAt.formatted(date: .long, time: .shortened))
                    if let folder = meeting.folder, !folder.isEmpty { Label(folder, systemImage: "folder") }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if meeting.deletedAt == nil {
                Button { model.toggleFavorite() } label: { Image(systemName: meeting.isFavorite == true ? "star.fill" : "star") }.help("收藏会议").disabled(model.summaryGenerating || model.questioning)
                Menu {
                    ForEach(ExportKind.allCases, id: \.self) { kind in Button(kind.rawValue) { model.export(kind) } }
                    Divider(); Button("复制全部转写") { model.copyTranscript() }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }.disabled(model.busy)
                Menu {
                    Button("重命名") { model.promptRename() }
                    Button("移入文件夹") { model.promptFolder() }
                    Divider()
                    Button("移入最近删除", role: .destructive) { model.deleteSelected() }
                } label: { Label("更多", systemImage: "ellipsis") }.disabled(!model.canManage)
            }
        }.padding(.horizontal, 24).padding(.vertical, 20)
    }

    private var audioBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 22) {
                meter("电脑声音", value: model.systemLevel, icon: "speaker.wave.2")
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("我的麦克风", isOn: Binding(get: { model.useMicrophone }, set: { model.setMicrophoneEnabled($0) }))
                        .toggleStyle(.switch).controlSize(.small).disabled(model.busy || model.microphoneChanging)
                    ProgressView(value: model.microphoneLevel).tint(accent).frame(width: 150)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(durationText(model.elapsed)).font(.title3.monospacedDigit().weight(.medium))
                    Text(model.importing ? "录音导入中" : model.recording ? "转写中" : model.paused ? "已暂停" : "中文 · 离线").font(.caption).foregroundStyle(model.recording ? accent : .secondary)
                }
                if model.recording || model.paused {
                    Button(model.recording ? "暂停" : "继续", systemImage: model.recording ? "pause.fill" : "play.fill") {
                        Task { if model.recording { await model.stop(pausing: true) } else { await model.start() } }
                    }.disabled(model.busy)
                    Button("结束", systemImage: "stop.fill") { Task { await model.stop() } }.disabled(model.busy)
                } else if model.importing {
                    Button("取消导入") { model.cancelImport() }
                } else {
                    Button(model.selectedMeeting?.hasContent == true ? "继续转写" : "开始转写", systemImage: "play.fill") { Task { await model.start() } }
                        .buttonStyle(.borderedProminent).tint(accent)
                        .disabled(model.busy || !model.modelReady || !model.canTranscribe)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            if !model.modelReady {
                HStack { Text("先准备中文离线识别模型").font(.caption).foregroundStyle(.secondary); Button("一键准备环境") { environment.isPresented = true; Task { await environment.check() } }.disabled(model.busy) }
            } else {
                Text(model.useMicrophone ? "Zoom 静音不会关闭这里的麦克风；使用外放时建议关闭，避免重复转写。" : "麦克风已关闭，只记录电脑播放的声音。转写中也可随时开启。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let hint = model.inputHint { Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
            Text("新会议音频保存在本机，用于会后分离说话人；永久删除会议时一并删除。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }
    private func meter(_ title: String, value: Double, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Label(title, systemImage: icon).font(.callout); ProgressView(value: value).tint(accent).frame(width: 150) }
    }

    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(MeetingTab.allCases, id: \.self) { tab in
                Button { model.tab = tab } label: {
                    VStack(spacing: 10) { Text(tab.rawValue).font(.callout.weight(model.tab == tab ? .semibold : .regular)); Rectangle().fill(model.tab == tab ? accent : .clear).frame(height: 2) }
                }.buttonStyle(.plain).foregroundStyle(model.tab == tab ? accent : .secondary)
            }
            Spacer()
            if model.recording { Toggle("跟随最新", isOn: $model.followLive).font(.caption).toggleStyle(.switch).controlSize(.mini) }
        }.padding(.horizontal, 24).padding(.top, 14)
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            speakerBar
            HStack {
                TextField("在本场会议中查找…", text: $model.transcriptQuery).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Picker("来源", selection: $model.sourceFilter) {
                    Text("全部声音").tag(Optional<AudioSource>.none)
                    ForEach(AudioSource.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }.labelsHidden().frame(width: 145)
                Spacer()
                Text("\(model.filteredLines.count) 段").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.tab == .transcript, let legacy = model.selectedMeeting?.legacyText,
                           model.sourceFilter == nil, model.transcriptQuery.isEmpty || legacy.localizedCaseInsensitiveContains(model.transcriptQuery) {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("历史原始记录", systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                                Text(legacy).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Text("旧版原文完整保留；新记录支持逐段校对与标记重点。").font(.caption).foregroundStyle(.secondary)
                            }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10)).id("legacy")
                        }
                        ForEach(model.filteredLines) { line in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 9) {
                                    Button { model.playLine(line) } label: { Label(durationText(line.start), systemImage: "play.circle").monospacedDigit() }.buttonStyle(.plain).help("从这一段回听").disabled(!model.canReviewAudio)
                                    Text(line.source.rawValue)
                                    if line.isFinal {
                                        Menu {
                                            ForEach(model.meetingSpeakers) { speaker in
                                                Button(speaker.name) { model.assignSpeaker(line, id: speaker.id) }
                                            }
                                            Button("未确定") { model.assignSpeaker(line, id: nil) }
                                            Divider()
                                            Button("新增说话人…") { model.promptNewSpeaker(for: line) }
                                        } label: {
                                            Label(model.document.speakerName(line.speakerID), systemImage: "person.crop.circle")
                                        }.menuStyle(.borderlessButton).fixedSize().disabled(!model.canManage)
                                            .foregroundStyle(speakerColor(line.speakerID))
                                            .help("纠正这一段的说话人")
                                        if line.speakerManuallyAssigned == true { Text("归属已校对") }
                                    }
                                    if !line.isFinal { Text("识别中…").foregroundStyle(accent) }
                                    if line.originalText != nil { Text("已校对") }
                                    Spacer()
                                    if line.isFinal {
                                        Button { model.toggleImportant(line.id) } label: { Image(systemName: line.isImportant == true ? "star.fill" : "star") }.buttonStyle(.plain).help("标记重点").foregroundStyle(line.isImportant == true ? .orange : .secondary)
                                        Button { model.promptEditLine(line) } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("校对文字").disabled(!model.canManage)
                                    }
                                }.font(.caption).foregroundStyle(.secondary)
                                Text(line.text).font(.system(size: 16)).foregroundStyle(line.isFinal ? .primary : .secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(16).background((model.playback.isPlaying ? model.activePlaybackLineID : model.focusedLineID) == line.id ? accent.opacity(0.12) : line.isImportant == true ? Color.orange.opacity(0.07) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .contextMenu {
                                    Button("复制这一段") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(line.text, forType: .string) }
                                    if let original = line.originalText {
                                        Button("查看识别原文") { let alert = NSAlert(); alert.messageText = "识别原文"; alert.informativeText = original; alert.runModal() }
                                        Button("恢复识别原文") { model.restoreOriginal(line) }.disabled(!model.canManage)
                                    }
                                }.id(line.id)
                        }
                        if model.filteredLines.isEmpty && (model.tab == .important || model.selectedMeeting?.legacyText == nil) {
                            ContentUnavailableView(model.tab == .important ? "还没有标记重点" : model.recording ? "等待中文语音…" : model.transcriptQuery.isEmpty ? "会议记录从这里开始" : "没有匹配文字", systemImage: model.tab == .important ? "star" : "text.alignleft", description: Text(model.tab == .important ? "点击转写段落的星标，方便会后回顾。" : "开始转写，或导入一段录音。"))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(24)
                }.onAppear {
                    if let id = model.focusedLineID { proxy.scrollTo(id, anchor: .center) }
                    else if model.selectedMeeting?.legacyText?.contains(model.transcriptQuery) == true { proxy.scrollTo("legacy", anchor: .top) }
                }
                .onChange(of: model.focusedLineID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: model.activePlaybackLineID) { _, id in
                    if model.playback.followText, model.transcriptQuery.isEmpty, let id, model.filteredLines.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: model.document.lines) { _, _ in
                    if model.recording && model.followLive && model.transcriptQuery.isEmpty { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    private var speakerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("说话人", systemImage: "person.2").font(.headline)
                Spacer()
                if model.speakersGenerating {
                    ProgressView().controlSize(.small)
                    Button("取消分离") { model.cancelSpeakerSeparation() }
                } else if model.hasSpeakerAudio {
                    Picker("发言人数", selection: Binding(get: { model.expectedSpeakerCount }, set: model.setSpeakerCount)) {
                        Text("自动估计").tag(0)
                        ForEach(1...12, id: \.self) { Text("\($0) 人").tag($0) }
                    }.frame(width: 180).disabled(!model.canManage)
                        .help("选择录音中实际发言的人数，未发言的参会人不计入；不确定时选自动估计。")
                    Button(model.document.speakerAnalysisAt == nil ? "分离说话人" : "重新分离") { model.separateSpeakers() }
                        .disabled(!model.canManage).help("重新分析会保留姓名和手动纠正的段落")
                }
            }
            if !model.meetingSpeakers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.meetingSpeakers) { speaker in
                            Button { model.promptSpeakerName(speaker) } label: {
                                Label(speaker.name, systemImage: "pencil")
                            }.controlSize(.small).tint(speakerColor(speaker.id)).disabled(!model.canManage).help("修改此人的姓名，整场同步更新")
                        }
                    }
                }
            }
            Text(!model.hasSpeakerAudio && model.selectedMeeting?.hasContent == true
                 ? model.document.lines.isEmpty ? "旧版纯文本没有音频和逐段时间；新录制或导入的会议支持说话人分离。" : "这场会议没有保存音频，可手动指定说话人；新会议支持自动分离。"
                 : model.speakerStatus).font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.vertical, 10)
    }

    private func speakerColor(_ id: String?) -> Color {
        guard let id, let index = model.meetingSpeakers.firstIndex(where: { $0.id == id }) else { return .secondary }
        let colors: [Color] = [.teal, .indigo, .orange, .pink, .blue, .purple]
        return colors[index % colors.count]
    }

    private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("会议笔记").font(.headline)
                    Text("可先写议程，转写时随手记录要点；内容自动保存。").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { model.selectedMeeting?.notes ?? "" }, set: model.setNotes)).font(.body).frame(minHeight: 180).padding(8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                Divider()
                HStack { Text("待办事项").font(.headline); Spacer(); Text("\((model.selectedMeeting?.tasks ?? []).filter(\.done).count)/\(model.selectedMeeting?.tasks?.count ?? 0) 已完成").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    TextField("需要跟进的事项", text: $model.taskText).textFieldStyle(.roundedBorder)
                    TextField("负责人", text: $model.taskOwner).textFieldStyle(.roundedBorder).frame(width: 100)
                    TextField("截止时间", text: $model.taskDue).textFieldStyle(.roundedBorder).frame(width: 110)
                    Button("添加") { model.addDraftTask() }.disabled(model.taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(model.selectedMeeting?.tasks ?? []) { task in
                    HStack(alignment: .top, spacing: 12) {
                        Button { model.toggleTask(task.id) } label: { Image(systemName: task.done ? "checkmark.circle.fill" : "circle").foregroundStyle(task.done ? accent : .secondary) }.buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.text).strikethrough(task.done).foregroundStyle(task.done ? .secondary : .primary)
                            if !task.owner.isEmpty || !task.due.isEmpty { Text([task.owner, task.due].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { model.promptEditTask(task) } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("编辑待办")
                        Button { model.removeTask(task.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("移除待办")
                    }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                if model.selectedMeeting?.tasks?.isEmpty != false { Text("手动添加待办，或在“纪要”里由本地 AI 提取后确认。没有负责人和期限的事项可留空。").font(.callout).foregroundStyle(.secondary) }
            }.padding(24)
        }
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) { Text("会议纪要").font(.headline); Text(model.aiStatus).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if model.summaryGenerating {
                        ProgressView().controlSize(.small)
                        Button("取消") { model.cancelSummary() }
                    } else {
                        Button(model.selectedMeeting?.summary == nil ? "生成纪要与待办" : "重新生成", systemImage: "sparkles") { model.generateSummary() }
                            .buttonStyle(.borderedProminent).tint(accent).disabled(!model.canManage)
                    }
                }
                Picker("纪要场景", selection: Binding(get: { model.selectedMeeting?.summaryTemplate ?? .work }, set: model.setSummaryTemplate)) {
                    ForEach(SummaryTemplate.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).disabled(!model.canManage)
                Text((model.selectedMeeting?.summaryTemplate ?? .work).guidance).font(.caption).foregroundStyle(.secondary)
                if let generated = model.selectedMeeting?.summaryGeneratedTemplate, generated != (model.selectedMeeting?.summaryTemplate ?? .work) {
                    Text("当前纪要由“" + generated.title + "”模板生成，重新生成后应用新模板。").font(.caption).foregroundStyle(.orange)
                }
                if let date = model.selectedMeeting?.summaryGeneratedAt {
                    Text("生成于 " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                if !environment.aiModel.ready {
                    Button("一键准备本地 AI") { environment.isPresented = true; Task { await environment.check() } }
                        .disabled(!model.canManage || model.paused)
                }
                Label("AI 可能遗漏或误解内容，请与原文核对。确认后的待办才会加入列表。", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                if model.selectedMeeting?.summary != nil {
                    TextEditor(text: Binding(get: { model.selectedMeeting?.summary ?? "" }, set: model.setSummary)).font(.body).frame(minHeight: 240).padding(8)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).disabled(model.summaryGenerating || model.questioning)
                } else { Text("结束转写后，点击生成。长会议会分段整理；会议内容只发送到这台 Mac 上的本地 AI 服务。").foregroundStyle(.secondary).padding(.vertical, 30) }
                if !model.suggestedTasks.isEmpty {
                    Divider(); Text("待确认的 AI 建议").font(.headline)
                    ForEach(model.suggestedTasks) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(task.text).font(.body.weight(.medium))
                            Text([task.owner, task.due].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            Text("依据：\(task.evidence)").font(.caption).textSelection(.enabled)
                            HStack { Button("加入待办") { model.acceptSuggested(task) }; Button("忽略") { model.dismissSuggested(task) }; Spacer() }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.padding(24)
        }
    }
    private func deletedMeeting(_ meeting: MeetingRecord) -> some View {
        ContentUnavailableView {
            Label("会议已移入最近删除", systemImage: "trash")
        } description: {
            Text("记录仍保存在本机。恢复后可继续查看、编辑和转写。永久删除不会自动发生。")
        } actions: {
            Button("恢复会议") { model.restore(meeting.id) }.buttonStyle(.borderedProminent).tint(accent)
            Button("永久删除", role: .destructive) { model.permanentlyDeleteSelected() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示")
                }
            }
            HStack(spacing: 12) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).lineLimit(2)
                if let id = model.undoDeletedID { Button("撤销删除") { model.restore(id) }.font(.caption) }
                Spacer()
                if model.pendingSave { Button("重试保存") { model.saveSafely() }.font(.caption) }
                else if let date = model.lastSavedAt { Label("已保存 " + date.formatted(date: .omitted, time: .shortened), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.horizontal, 24).padding(.vertical, 14).background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }
}

import SwiftUI

struct MeetingPlaybackView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var playback: MeetingPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if playback.sources.isEmpty {
                Label(playback.message.isEmpty ? "录音结束后可在这里回听，并点击文字定位声音。" : playback.message, systemImage: "headphones")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Button { playback.toggle() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill") }
                        .help(playback.isPlaying ? "暂停回放" : "播放录音")
                    Button { _ = playback.seek(playback.position - 10) } label: { Image(systemName: "gobackward.10") }.help("后退 10 秒")
                    Slider(value: Binding(get: { playback.position }, set: { _ = playback.seek($0) }), in: 0...max(1, playback.duration))
                        .accessibilityLabel("录音进度")
                    Text(durationText(playback.position) + " / " + durationText(playback.duration)).font(.caption.monospacedDigit())
                    Button { _ = playback.seek(playback.position + 10) } label: { Image(systemName: "goforward.10") }.help("前进 10 秒")
                    Picker("回放来源", selection: Binding(get: { playback.source }, set: playback.selectSource)) {
                        ForEach(playback.sources) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 130)
                    Picker("播放速度", selection: $playback.rate) {
                        ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }.labelsHidden().frame(width: 76)
                }
                Toggle("跟随回放定位文字", isOn: $playback.followText).toggleStyle(.checkbox).font(.caption).controlSize(.small)
                if !playback.message.isEmpty { Text(playback.message).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.horizontal, 24).padding(.vertical, 10)
            .background(Color.teal.opacity(0.04))
            .disabled(!model.canReviewAudio)
            .onAppear { model.refreshPlayback() }
            .onChange(of: model.selectedMeetingID) { _, _ in model.refreshPlayback() }
            .onChange(of: model.selectedMeeting?.audioSegments) { _, _ in model.refreshPlayback() }
            .onChange(of: model.canReviewAudio) { _, ready in if ready { model.refreshPlayback() } }
    }
}

struct MeetingQuestionsView: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var environment: EnvironmentSetup
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack { Label("向这场会议提问", systemImage: "text.bubble").font(.headline); Spacer(); Label("本地 AI", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary) }
                    Text("只查阅本场转写和笔记。AI 回答需校对，引用可定位原文；回答会随会议保存和导出。").font(.callout).foregroundStyle(.secondary)
                    if model.selectedMeeting?.answers?.isEmpty != false {
                        HStack {
                            ForEach(["有哪些明确决定？", "谁需要做什么，什么时候完成？", "还有哪些问题未解决？"], id: \.self) { question in
                                Button(question) { model.questionText = question }.controlSize(.small)
                            }
                        }.disabled(model.questioning)
                    }
                    ForEach(model.selectedMeeting?.answers ?? []) { answer in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                Text(answer.question).font(.headline)
                                Spacer()
                                Button { model.removeAnswer(answer.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("删除这条问答").disabled(!model.canManage)
                            }
                            Text(answer.answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            if answer.sourceFingerprint != model.selectedMeeting?.evidenceFingerprint {
                                Label("原文或笔记已变更，建议重新提问核对。", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                            }
                            ForEach(answer.citations) { citation in
                                Button { model.locateCitation(citation) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label((citation.start.map { durationText($0) + " · " } ?? "") + (model.selectedMeeting?.citationSpeaker(citation) ?? citation.speaker), systemImage: "quote.opening").font(.caption.weight(.medium))
                                        Text(citation.quote).font(.callout).lineLimit(5)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).help("定位引用原文")
                            }
                            Text(answer.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if model.questioning { HStack { ProgressView().controlSize(.small); Text(model.questionStatus).font(.callout); Spacer(); Button("取消") { model.cancelQuestion() } } }
                }.padding(24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom) {
                    TextField("例如：接口验收由谁负责？截止时间是什么？", text: $model.questionText, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder).disabled(model.questioning)
                        .onSubmit { if model.canManage { model.askQuestion() } }
                    Button("提问", systemImage: "arrow.up") { model.askQuestion() }.buttonStyle(.borderedProminent).tint(.teal)
                        .disabled(!model.canManage || model.questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.questionText.count > 500)
                }
                HStack {
                    Text(model.questionStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer(); Text("\(model.questionText.count)/500").font(.caption).foregroundStyle(model.questionText.count > 500 ? .orange : .secondary)
                    if !environment.aiModel.ready { Button("准备本地 AI") { environment.isPresented = true; Task { await environment.check() } }.disabled(!model.canManage) }
                }
            }.padding(20)
        }
    }
}

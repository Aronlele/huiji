import SwiftUI

struct EnvironmentView: View {
    @ObservedObject var setup: EnvironmentSetup
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 38)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 6) {
                    Text("准备好，再开始记录").font(.title2.bold())
                    Text("自动检测已有环境，只下载缺少的部分。").foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                row("中文离线转写", item: setup.speech)
                Divider().padding(.leading, 44)
                row("会后说话人分离", item: setup.speakers)
                Divider().padding(.leading, 44)
                row("本地 AI 运行环境", item: setup.runtime)
                Divider().padding(.leading, 44)
                row("中文纪要与待办模型", item: setup.aiModel)
            }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            if !setup.runtime.ready || !setup.aiModel.ready {
                Toggle("同时准备自动纪要与待办", isOn: $setup.includeAI).disabled(setup.busy || setup.checking)
                Text(setup.includeAI ? "缺少 AI 环境时将下载约 2.7 GB，建议预留 6 GB 空间。可以停止，稍后重试；模型支持续传。" : "先使用中文转写和说话人分离；以后可随时在这里补齐 AI。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    if setup.busy || setup.checking { ProgressView().controlSize(.small) }
                    Text(setup.checking ? "正在检查这台 Mac…" : setup.message).font(.callout)
                    Spacer()
                    if let fraction = setup.fraction, setup.busy { Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit().font(.caption) }
                }
                if setup.busy, let fraction = setup.fraction { ProgressView(value: fraction).tint(.teal) }
                if let error = setup.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }.frame(minHeight: 38, alignment: .top)
            Label("下载只获取模型和运行环境。会议音频与文字始终在本机处理。", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("重新检查") { Task { await setup.check() } }.disabled(setup.busy || setup.checking)
                Spacer()
                if setup.busy {
                    Button("停止准备") { setup.cancel() }
                } else {
                    Button(setup.selectionReady ? "完成" : "稍后准备") { setup.isPresented = false }
                        .keyboardShortcut(.cancelAction)
                    if !setup.selectionReady {
                        Button(setup.error == nil ? "一键准备" : "重试") { setup.start() }
                            .buttonStyle(.borderedProminent).tint(.teal)
                            .disabled(!setup.checked || setup.checking)
                    }
                }
            }
        }.padding(28).frame(width: 620).fixedSize(horizontal: false, vertical: true)
            .interactiveDismissDisabled(setup.busy)
    }

    private func row(_ title: String, item: EnvironmentSetup.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.ready ? "checkmark.circle.fill" : item.failed ? "exclamationmark.circle.fill" : "circle.dashed")
                .foregroundStyle(item.ready ? .teal : item.failed ? .orange : .secondary).font(.title3).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text(title).font(.callout.weight(.medium)); Spacer(); Text(item.ready ? "已就绪" : item.failed ? "需要处理" : "待准备").font(.caption).foregroundStyle(.secondary) }
                Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(10)
    }
}

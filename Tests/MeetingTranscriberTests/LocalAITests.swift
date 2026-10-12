import Foundation

@main
struct LocalAITests {
    @MainActor static func main() async throws {
        let short = "产品会议：我们决定采用本机离线转写，会议内容不上传。王明负责接口开发，周五完成。李华负责检查中文识别结果，下周一提交报告。预算还未决定。"
        let long = CommandLine.arguments.contains("--long")
        let text = long ? "王明负责接口开发，周五完成。\n" + String(repeating: "今天讨论会议资料的保存方式，保持本机处理，内容不上传，预算仍未决定。\n", count: 240) + "李华负责检查中文识别结果，下周一提交报告。\n我们决定采用本机离线转写。" : short
        let parts = LocalMeetingAI.chunks(text)
        if long { precondition(parts.count > 1) }
        precondition(parts.joined().contains("王明") && parts.joined().contains("李华"))
        defer { LocalMeetingAI.shared.shutdown() }
        let start = Date()
        let result = try await LocalMeetingAI.shared.summarize(text) { print($0) }
        let data = try JSONEncoder().encode(result)
        try data.write(to: URL(fileURLWithPath: long ? "verification/local-ai-long-result.json" : "verification/local-ai-result.json"))
        precondition(!result.summary.isEmpty)
        guard result.tasks.contains(where: { $0.text.contains("接口") && $0.owner.contains("王明") && $0.due.contains("周五") }) else { throw MeetingError.message("长会议遗漏前场接口任务") }
        guard result.tasks.contains(where: { $0.owner.contains("李华") && $0.due.contains("下周一") }) else { throw MeetingError.message("长会议遗漏后场验收任务") }
        guard result.tasks.allSatisfy({ text.contains($0.evidence) && !$0.text.contains("预算") }) else { throw MeetingError.message("待办依据或未决事项校验失败") }
        print("PASS: 中文本地摘要、两条任务及负责人期限、原文依据、未决定事项不造待办；耗时 \(Int(Date().timeIntervalSince(start))) 秒")
    }
}

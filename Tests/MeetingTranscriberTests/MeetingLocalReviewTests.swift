import Foundation

@main
struct MeetingLocalReviewTests {
    @MainActor static func main() async throws {
        let ai = LocalMeetingAI()
        defer { ai.shutdown() }
        var record = MeetingRecord(title: "合成中文产品会议", textFileName: "fixture.txt")
        record.document.update(source: .system, start: 0, end: 8, text: "我们决定采用本机离线转写，会议内容不上传。王明负责接口开发，周五完成。", isFinal: true)
        record.document.update(source: .system, start: 8, end: 12, text: "预算仍未决定。客户提出希望先试用，再讨论采购。", isFinal: true)
        record.document.update(source: .system, start: 12, end: 20, text: "李华负责检查中文识别结果，下周一提交报告。", isFinal: true)
        let grounded = try await ai.answer("接口开发由谁负责，什么时候完成？", record: record) { print($0) }
        precondition(grounded.answer.contains("王明") && grounded.answer.contains("周五") && !grounded.citations.isEmpty)
        let absent = try await ai.answer("王明的手机号是多少？", record: record) { print($0) }
        precondition(absent.citations.isEmpty && absent.answer.contains("未找到"))
        let budget = try await ai.answer("预算确定了吗？", record: record) { print($0) }
        precondition(budget.answer.contains("未") && budget.citations.contains { $0.quote.contains("预算") })
        // An answer located beyond the first context must remain discoverable.
        var long = record
        long.notes = (0..<95).map { "背景资料\($0)：此次讨论记录保存方式，要求在本机处理，音频文字均不上传，无新增采购决定。" }.joined(separator: "\n") + "\n最终确认：赵强负责打包安装程序，下周三完成。"
        precondition(LocalMeetingAI.evidenceGroups(long.evidence).count > 1)
        let tail = try await ai.answer("打包安装程序由谁负责，什么时候完成？", record: long) { print($0) }
        precondition(tail.answer.contains("赵强") && tail.answer.contains("下周三") && tail.citations.contains { $0.quote.contains("赵强") })
        var summaries: [String: MeetingAIResult] = [:]
        for template in SummaryTemplate.allCases {
            print("验证模板：" + template.title)
            let result = try await ai.summarize(record.transcriptText, template: template) { print($0) }
            precondition(!result.summary.isEmpty)
            precondition(result.tasks.contains { $0.owner.contains("王明") && $0.due.contains("周五") })
            precondition(result.tasks.contains { $0.owner.contains("李华") && $0.due.contains("下周一") })
            precondition(result.tasks.allSatisfy { record.transcriptText.contains($0.evidence) && !$0.text.contains("预算") })
            summaries[template.rawValue] = result
        }
        struct Report: Codable { let answers: [MeetingAnswer]; let summaries: [String: MeetingAIResult] }
        try FileManager.default.createDirectory(atPath: "verification", withIntermediateDirectories: true)
        try JSONEncoder().encode(Report(answers: [grounded, absent, budget, tail], summaries: summaries)).write(to: URL(fileURLWithPath: "verification/local-review-result.json"))
        print("PASS: 真实本机 Qwen 中文问答、可核验引用、未知电话拒答、未决预算、长尾查阅、四种模板与任务证据")
    }
}

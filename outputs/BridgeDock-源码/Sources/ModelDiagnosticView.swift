import SwiftUI

struct ModelDiagnosticResultView: View {
    let report: ModelTestReport

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(report.mode.title + "结果").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(report.cancelled ? "已取消" : (report.finished ? "已完成" : "测试中"))
                    .font(.system(size: 11)).foregroundStyle(mutedInk)
            }
            Text(report.model + " · " + report.wire).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(mutedInk).textSelection(.enabled)
            HStack(alignment: .top, spacing: 16) {
                metric("成功率 · \(report.successful)/\(report.samples.count)", report.samples.isEmpty ? "—" : String(format: "%.0f%%", Double(report.successful) / Double(report.samples.count) * 100))
                metric("平均首字延迟", seconds(report.averageFirstText))
                metric("平均总耗时", seconds(report.averageDuration))
                if report.mode == .routing { metric("答对 / 可评分", "\(report.correct) / \(report.scored.count)") }
            }
            Text("计划 \(report.plannedCount) 次 · 延迟统计仅包含成功请求 · 首字从发起请求到收到正文计算，经过当前反代链路。")
                .font(.system(size: 11)).foregroundStyle(mutedInk)
            if report.mode == .routing { routingEvidence }
            ForEach(report.samples) { sample in sampleRow(sample) }
        }
        .padding(18).background(insetSurface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var routingEvidence: some View {
        let finding = report.route.finding(for: report.returnedModels)
        return VStack(alignment: .leading, spacing: 10) {
            Label(finding.title, systemImage: finding.warning ? "exclamationmark.triangle" : "doc.text.magnifyingglass")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(finding.warning ? warning : ink)
            Text(finding.detail).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text("来源渠道 · " + report.route.source)
                Text("内核路由 · " + report.route.coreID)
                Text("配置上游模型 · " + report.route.upstreamIDs.joined(separator: "、"))
                Text("响应 model 字段 · " + (report.returnedModels.isEmpty ? "未提供" : report.returnedModels.joined(separator: "、")))
            }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text("中转服务可以改写 model 字段。此处用于发现路由差异，模型真实身份仍需上游可核验记录。")
                .font(.system(size: 11)).foregroundStyle(mutedInk)
            Divider().opacity(0.4)
            Text(capabilitySummary).font(.system(size: 12, weight: .medium))
            Text("题目每轮随机生成。得分反映本轮计算、逻辑和提取表现。请求失败不计为答错，单轮分数不足以判定降智或模型被替换。")
                .font(.system(size: 11)).foregroundStyle(mutedInk)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(panel, in: RoundedRectangle(cornerRadius: 9))
    }

    private var capabilitySummary: String {
        guard !report.scored.isEmpty else { return report.finished ? "能力检测 · 无可评分结果" : "能力检测 · 等待可评分结果" }
        if report.correct == report.scored.count { return "能力检测 · 已完成题目全部答对" }
        return "能力检测 · \(report.scored.count - report.correct) 题未通过，可展开核对题目与回答"
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(mutedInk)
            Text(value).font(.system(size: 19, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sampleRow(_ sample: ModelTestSample) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if let error = sample.error { Text(error).foregroundStyle(warning) }
                Text("返回模型 · " + (sample.returnedModels.isEmpty ? "未提供" : sample.returnedModels.joined(separator: "、")))
                Text(sample.streaming ? "首字延迟 · " + seconds(sample.firstTextSeconds) : "本次返回完整 JSON，首字延迟未测量。")
                if let tokens = sample.outputTokens { Text("上游报告输出 token · \(tokens)") }
                if let expected = sample.probe.expectedJSON { Text("标准答案\n" + expected) }
                Text("模型回答\n" + (sample.text.isEmpty ? "无正文" : sample.text))
                if sample.probe.expectedJSON != nil {
                    DisclosureGroup("查看测试题目") { Text(sample.probe.prompt).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: sample.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(sample.succeeded ? healthy : warning)
                Text(sample.probe.title).fontWeight(.medium)
                if let correct = sample.answerCorrect {
                    Text(correct ? "答对" : "未通过").foregroundStyle(correct ? healthy : warning)
                }
                Spacer()
                if let status = sample.httpStatus { Text("HTTP \(status)").foregroundStyle(mutedInk) }
                Text(seconds(sample.duration)).monospacedDigit()
            }.font(.system(size: 12))
        }
    }

    private func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f 秒", $0) } ?? "—"
    }
}

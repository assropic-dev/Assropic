import SwiftUI

struct ModelDiagnosticResultView: View {
    let report: ModelTestReport

    private var graded: Bool { report.mode == .reasoning || report.mode == .longContext }

    var body: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.mode.title + "结果").sectionTitle()
                        Text(report.model + " · " + report.wire + (report.mode == .reasoning ? " · 推理强度 " + report.effort.title : ""))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(mutedInk).textSelection(.enabled)
                    }
                    Spacer()
                    Pill(text: statusTitle, tint: statusColor)
                }
                HStack(alignment: .top, spacing: 10) {
                    metric("成功率 · \(report.successful)/\(report.samples.count)", report.samples.isEmpty ? "—" : String(format: "%.0f%%", Double(report.successful) / Double(report.samples.count) * 100))
                    if report.mode.streaming { metric("平均首字延迟", seconds(report.averageFirstText)) }
                    metric("平均总耗时", seconds(report.averageDuration))
                    if graded { metric("答对 / 可评分", "\(report.correct) / \(report.scored.count)") }
                    if report.mode == .reasoning { metric("平均推理 token", report.averageReasoningTokens.map(String.init) ?? "未提供") }
                }
                if report.mode == .reasoning { routingEvidence }
                if report.mode == .longContext { longContextSummary }
                if !report.samples.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("逐次明细").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("点击展开查看回答").captionText(10)
                        }.padding(.bottom, 8)
                        ForEach(Array(report.samples.enumerated()), id: \.element.id) { index, sample in
                            if index > 0 { Divider().opacity(0.4) }
                            sampleRow(sample).padding(.vertical, 8)
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 12)
                        .background(insetSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                }
                Text(footnote).captionText(10)
            }
        }
    }

    private var allPassed: Bool { !report.samples.isEmpty && report.successful == report.samples.count }
    private var statusTitle: String {
        if report.cancelled { return "已取消" }
        if !report.finished { return "测试中" }
        return allPassed ? "全部成功" : "\(report.samples.count - report.successful) 次失败"
    }
    private var statusColor: Color {
        if report.cancelled || !report.finished { return mutedInk }
        return allPassed ? healthy : failureTint
    }

    private var footnote: String {
        let base = "计划 \(report.plannedCount) 次 · 延迟统计仅包含成功请求"
        return report.mode.streaming ? base + " · 首字从发起请求到收到正文计算，经过当前反代链路。" : base + " · 使用非流式请求，完整保留 usage 与 thinking 签名。"
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
            if let thinking = thinkingSummary {
                Divider().opacity(0.4)
                Label(thinking.title, systemImage: thinking.warning ? "exclamationmark.triangle" : "signature")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(thinking.warning ? warning : ink)
                Text("Claude 的 thinking 块带有 Anthropic 服务端签名，中转站难以伪造。缺失或过短说明 thinking 被剥离、或上游不是 Claude。")
                    .font(.system(size: 11)).foregroundStyle(mutedInk)
            }
            Divider().opacity(0.4)
            Text(capabilitySummary).font(.system(size: 12, weight: .medium))
            Text("糖果题源自 GitHub 降智测试 codex-candy-eval，数量和口味每轮随机。降智常表现为同一推理强度下推理 token 明显偏少、正确率下降；请与官方渠道同强度结果对照。请求失败不计为答错。")
                .font(.system(size: 11)).foregroundStyle(mutedInk)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(insetSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }

    private var thinkingSummary: (title: String, warning: Bool)? {
        let samples = report.thinkingSamples
        guard !samples.isEmpty else { return nil }
        let signed = samples.filter { $0.thinking.isSigned }.count
        if signed == samples.count { return ("thinking 签名 · \(signed)/\(samples.count) 次均返回有效签名", false) }
        let issues = Set(samples.filter { !$0.thinking.isSigned }.map(\.thinking.summary)).sorted().joined(separator: "、")
        return ("thinking 签名 · \(signed)/\(samples.count) 次有效 · " + issues, true)
    }

    private var longContextSummary: some View {
        let failed = report.samples.first { !$0.succeeded || $0.answerCorrect == false }
        let text: String
        if let failed { text = failed.probe.title + " 未通过，已停止更长档位。渠道可能截断上下文或转发到小窗口模型。" }
        else if report.finished && !report.cancelled { text = "全部档位通过，三处埋点均被准确取回；已记录为可选上下文。" }
        else { text = "等待结果。" }
        return Text("长上下文 · " + text).font(.system(size: 12, weight: .medium))
            .foregroundStyle(failed == nil ? ink : warning)
    }

    private var capabilitySummary: String {
        guard !report.scored.isEmpty else { return report.finished ? "降智检测 · 无可评分结果" : "降智检测 · 等待可评分结果" }
        if report.correct == report.scored.count { return "降智检测 · 已完成题目全部答对" }
        return "降智检测 · \(report.scored.count - report.correct) 题未通过，可展开核对题目与回答"
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(mutedInk).lineLimit(1)
            Text(value).font(.system(size: 19, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(insetSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sampleRow(_ sample: ModelTestSample) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if let error = sample.error { Text(error).foregroundStyle(warning) }
                Text("返回模型 · " + (sample.returnedModels.isEmpty ? "未提供" : sample.returnedModels.joined(separator: "、")))
                if report.mode.streaming { Text(sample.streaming ? "首字延迟 · " + seconds(sample.firstTextSeconds) : "本次返回完整 JSON，首字延迟未测量。") }
                if let tokens = sample.inputTokens { Text("上游报告输入 token · \(tokens)") }
                if let tokens = sample.outputTokens { Text("上游报告输出 token · \(tokens)") }
                if let tokens = sample.reasoningTokens { Text("上游报告推理 token · \(tokens)") }
                if sample.thinking != .notRequested { Text("thinking · " + sample.thinking.summary).foregroundStyle(sample.thinking.warning ? warning : ink) }
                if let expected = sample.probe.expectedJSON { Text("标准答案\n" + expected) }
                Text("模型回答\n" + (sample.text.isEmpty ? "无正文" : String(sample.text.suffix(2000))))
                if sample.probe.expectedJSON != nil && sample.probe.estimatedInputTokens == nil {
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
                if let tokens = sample.reasoningTokens { Text("推理 \(tokens)").foregroundStyle(mutedInk) }
                if let status = sample.httpStatus { Text("HTTP \(status)").foregroundStyle(mutedInk) }
                Text(seconds(sample.duration)).monospacedDigit()
            }.font(.system(size: 12))
        }
    }

    private func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f 秒", $0) } ?? "—"
    }
}

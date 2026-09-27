import Charts
import SwiftUI

enum UsagePeriod: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }
    var title: String { "\(rawValue)日" }

    /// Spacing between x-axis labels, in days.
    var labelStride: Int {
        switch self {
        case .week: 1
        case .month: 5
        case .quarter: 15
        }
    }
}

enum UsageMetric: String, CaseIterable, Identifiable {
    case dictations
    case minutes
    case characters
    case cost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictations: "回数"
        case .minutes: "時間"
        case .characters: "文字数"
        case .cost: "料金"
        }
    }

    /// Cost is in yen.
    func value(_ day: DailyUsage, yenPerUSD: Double) -> Double {
        switch self {
        case .dictations: Double(day.dictations)
        case .minutes: day.audioSeconds / 60
        case .characters: Double(day.characters)
        case .cost: UsagePricing.estimate([day]).totalUSD * yenPerUSD
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .dictations: "\(Int(value)) 回"
        case .minutes: UsageFormat.duration(seconds: value * 60)
        case .characters: "\(Int(value).formatted()) 文字"
        case .cost: UsageFormat.yen(value)
        }
    }
}

enum UsageFormat {
    static func duration(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        if hours > 0 { return "\(hours)時間\(minutes)分" }
        if minutes > 0 { return "\(minutes)分\(secs)秒" }
        return "\(secs)秒"
    }

    /// Estimates are often fractions of a yen, so small amounts keep a decimal.
    static func yen(_ value: Double) -> String {
        if value == 0 { return "0円" }
        if value < 0.1 { return "0.1円未満" }
        if value < 10 { return "\(value.formatted(.number.precision(.fractionLength(1))))円" }
        return "\(Int(value.rounded()).formatted())円"
    }

    static func yen(usd: Double, rate: Double) -> String { yen(usd * rate) }
}

struct UsageView: View {
    let env: AppEnvironment
    @State private var period: UsagePeriod = .month
    @State private var metric: UsageMetric = .dictations

    var body: some View {
        let series = env.usage.series(days: period.rawValue)
        let days = series.map(\.usage)
        let estimate = UsagePricing.estimate(days)
        let rate = env.settings.usdJPYRate
        SettingsPage {
            Picker("期間", selection: $period) {
                ForEach(UsagePeriod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            StatTiles(days: days, estimate: estimate, yenPerUSD: rate)

            SettingsSection(title: "日別の推移") {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("指標", selection: $metric) {
                            ForEach(UsageMetric.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        DailyChart(series: series, metric: metric, period: period, yenPerUSD: rate)
                            .frame(height: 200)
                    }
                    .padding(.vertical, 6)
                }
            }

            CostBreakdown(settings: env.settings, days: days, estimate: estimate)
        }
    }
}

/// Shown in the page header next to the title.
struct UsageHeaderActions: View {
    let usage: UsageStore
    @State private var confirming = false

    var body: some View {
        Button("リセット", role: .destructive) { confirming = true }
            .disabled(usage.days.isEmpty)
            .confirmationDialog("利用状況をリセットしますか？", isPresented: $confirming) {
                Button("リセット", role: .destructive) { usage.removeAll() }
            } message: {
                Text("これまでの集計がすべて消えます。この操作は取り消せません。")
            }
    }
}

// MARK: - Stat tiles

private struct StatTiles: View {
    let days: [DailyUsage]
    let estimate: UsagePricing.Estimate
    let yenPerUSD: Double

    var body: some View {
        let dictations = days.reduce(0) { $0 + $1.dictations }
        let seconds = days.reduce(0) { $0 + $1.audioSeconds }
        let characters = days.reduce(0) { $0 + $1.characters }
        let activeDays = days.filter { $0.dictations > 0 }.count
        HStack(spacing: 12) {
            StatTile(
                title: "利用回数", value: "\(dictations.formatted()) 回",
                caption: activeDays > 0 ? "\(activeDays) 日利用" : nil)
            StatTile(
                title: "話した時間", value: UsageFormat.duration(seconds: seconds),
                caption: dictations > 0 ? "1 回あたり \(UsageFormat.duration(seconds: seconds / Double(dictations)))" : nil)
            StatTile(
                title: "文字数", value: "\(characters.formatted()) 文字",
                caption: seconds >= 1 ? "\(Int(Double(characters) / (seconds / 60)).formatted()) 文字/分" : nil)
            StatTile(
                title: "API 料金（概算）", value: UsageFormat.yen(usd: estimate.totalUSD, rate: yenPerUSD),
                caption: estimate.unpricedModels.isEmpty ? "公開価格から計算" : "一部のモデルは含まず")
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let caption: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: shape)
        .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chart

private struct DailyChart: View {
    let series: [(date: Date, usage: DailyUsage)]
    let metric: UsageMetric
    let period: UsagePeriod
    let yenPerUSD: Double
    @State private var hovered: Date? = nil

    var body: some View {
        let points = series.map { (date: $0.date, value: metric.value($0.usage, yenPerUSD: yenPerUSD)) }
        let selected = hovered.flatMap { hovered in
            points.first { Calendar.current.isDate($0.date, inSameDayAs: hovered) }
        }
        Chart {
            ForEach(points, id: \.date) { point in
                BarMark(
                    x: .value("日付", point.date, unit: .day),
                    y: .value(metric.title, point.value),
                    width: .ratio(0.7)
                )
                .cornerRadius(4)
                .foregroundStyle(.tint.opacity(selected == nil || selected?.date == point.date ? 1 : 0.45))
            }
            if let selected {
                RuleMark(x: .value("日付", selected.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .zIndex(-1)
                    .annotation(
                        position: .top, spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.date, format: .dateTime.month().day().weekday())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(metric.format(selected.value))
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
            }
        }
        .chartXSelection(value: $hovered)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: period.labelStride)) {
                AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.separator)
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(axisLabel(number)) }
                }
            }
        }
        .accessibilityLabel("日別の\(metric.title)")
    }

    private func axisLabel(_ value: Double) -> String {
        switch metric {
        case .cost: "\(value.formatted(.number.precision(.fractionLength(0...1))))円"
        case .minutes: "\(value.formatted(.number.precision(.fractionLength(0...1))))分"
        default: value.formatted(.number.notation(.compactName))
        }
    }
}

// MARK: - Cost breakdown

private struct CostBreakdown: View {
    let settings: SettingsStore
    let days: [DailyUsage]
    let estimate: UsagePricing.Estimate

    /// Ignores zero and negative rates, which would make every estimate meaningless.
    private var rateBinding: Binding<Double> {
        Binding(get: { settings.usdJPYRate }, set: { if $0 > 0 { settings.usdJPYRate = $0 } })
    }

    var body: some View {
        let stt = Self.merge(days.flatMap(\.transcription))
        let llm = Self.merge(days.flatMap(\.cleanup))
        let rate = settings.usdJPYRate
        SettingsSection(
            title: "API 料金の内訳",
            footer:
                "各サービスの公開価格（\(UsagePricing.pricesAsOf)時点、ドル建て）を上の為替レートで円に換算した目安です。Amazon Bedrock はリージョンや推論プロファイル（global / jp など）で価格が変わるため、記録したリージョンの価格で計算しています。実際の請求額は各サービスの管理画面で確認してください。"
        ) {
            LabeledRow("為替レート") {
                HStack(spacing: 6) {
                    Text("1 ドル =").foregroundStyle(.secondary)
                    TextField("為替レート", value: rateBinding, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    Text("円").foregroundStyle(.secondary)
                }
            }
            if stt.isEmpty && llm.isEmpty {
                NoteRow("この期間の利用はまだありません。")
            }
            ForEach(stt, id: \.self) { usage in
                BreakdownRow(
                    title: "文字起こし", model: usage.model,
                    detail: UsageFormat.duration(seconds: usage.seconds),
                    cost: UsagePricing.transcriptionUSD(usage).map { $0 * rate })
            }
            ForEach(llm, id: \.self) { usage in
                BreakdownRow(
                    title: "AI 整形", model: usage.region.map { "\(usage.model)（\($0)）" } ?? usage.model,
                    detail:
                        "\(usage.requests.formatted()) 回・入力 \(usage.tokens.input.formatted()) / 出力 \(usage.tokens.output.formatted()) トークン",
                    cost: UsagePricing.cleanupUSD(usage).map { $0 * rate })
            }
            if !estimate.unpricedModels.isEmpty {
                NoteRow("料金が登録されていないモデルは合計に含めていません。トークン数を各サービスの料金表と照らし合わせてください。")
            }
        }
    }

    /// Sums entries for the same provider and model across days.
    static func merge(_ items: [TranscriptionUsage]) -> [TranscriptionUsage] {
        var merged: [TranscriptionUsage] = []
        for item in items {
            if let index = merged.firstIndex(where: { $0.provider == item.provider && $0.model == item.model }) {
                merged[index].seconds += item.seconds
            } else {
                merged.append(item)
            }
        }
        return merged
    }

    static func merge(_ items: [CleanupUsage]) -> [CleanupUsage] {
        var merged: [CleanupUsage] = []
        for item in items {
            if let index = merged.firstIndex(where: { $0.isSameModel(as: item) }) {
                merged[index].requests += item.requests
                merged[index].tokens = merged[index].tokens + item.tokens
            } else {
                merged.append(item)
            }
        }
        return merged.sorted { $0.tokens.input + $0.tokens.output > $1.tokens.input + $1.tokens.output }
    }
}

private struct BreakdownRow: View {
    let title: String
    let model: String
    let detail: String
    /// In yen.
    let cost: Double?

    var body: some View {
        LabeledRow {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    Text(model).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } control: {
            Text(cost.map { UsageFormat.yen($0) } ?? "料金不明")
                .monospacedDigit()
                .foregroundStyle(cost == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }
}

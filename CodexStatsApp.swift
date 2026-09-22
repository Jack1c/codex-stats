// Codex 用量状态栏 app
// 数据源：~/.codex/sessions/**/*.jsonl（Codex 自己的会话文件）
// 构建见同目录 build.sh

import SwiftUI
import Foundation

let sessionsRoot = NSString(string: "~/.codex/sessions").expandingTildeInPath
let sessionIndexFile = NSString(string: "~/.codex/session_index.jsonl").expandingTildeInPath
let claudeProjectsRoot = NSString(string: "~/.claude/projects").expandingTildeInPath
let scanDays = 7

let isoFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
let isoPlain = ISO8601DateFormatter()

func parseTimestamp(_ text: String) -> Date? {
    isoFractional.date(from: text) ?? isoPlain.date(from: text)
}

// MARK: - 数据模型

struct TurnUsage {
    var ts: Date
    var threadID: String
    var project: String
    var label: String
    var model: String
    var input: Int
    var cached: Int
    var output: Int
    var total: Int
}

struct Totals {
    var input = 0
    var cached = 0
    var output = 0
    var total = 0

    mutating func add(_ turn: TurnUsage) {
        input += turn.input
        cached += turn.cached
        output += turn.output
        total += turn.total
    }
}

struct ModelTotals {
    var model: String
    var totals: Totals
    var cost = Cost()
}

struct SessionTotals {
    var name: String
    var totals: Totals
    var cost = Cost()
}

// DeepSeek 计费：单价为「元 / 百万 tokens」，空闲时段价格为高峰的一半
struct DeepSeekPrice {
    var hit: Double     // 输入（缓存命中）
    var miss: Double    // 输入（缓存未命中）
    var output: Double
}

struct Cost {
    var peak = 0.0
    var offpeak = 0.0

    var total: Double { peak + offpeak }

    mutating func add(_ amount: Double, peak isPeak: Bool) {
        if isPeak { peak += amount } else { offpeak += amount }
    }
}

let deepSeekPrices: [String: (peak: DeepSeekPrice, offpeak: DeepSeekPrice)] = [
    "flash": (
        peak: DeepSeekPrice(hit: 0.04, miss: 2.0, output: 8.0),
        offpeak: DeepSeekPrice(hit: 0.02, miss: 1.0, output: 4.0)
    ),
    "pro": (
        peak: DeepSeekPrice(hit: 0.30, miss: 9.0, output: 27.0),
        offpeak: DeepSeekPrice(hit: 0.15, miss: 4.5, output: 13.5)
    ),
]

// 高峰时段：北京时间周一至周五 9:00-12:00、14:00-18:00；其余（含周末）为空闲时段
// 说明：中国法定节假日全天算空闲，这里未做节假日判断
func isPeakHour(_ date: Date) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    let weekday = calendar.component(.weekday, from: date)
    guard (2...6).contains(weekday) else { return false }
    let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    return (540..<720).contains(minutes) || (840..<1080).contains(minutes)
}

// 官方定价对应的模型档位，deepseek-v4-flash 等旧名仍按 Flash 价格计费
let deepSeekTiers: [String: String] = [
    "deepseek-flash": "flash",
    "deepseek-v4-flash": "flash",
    "deepseek-v4-flash-vision-exp": "flash",
    "deepseek-v4-pro": "pro",
]

func deepSeekPrice(for model: String, peak: Bool) -> DeepSeekPrice? {
    let name = model.lowercased()
    var tier = deepSeekTiers[name]
    if tier == nil, name.hasPrefix("deepseek") {
        // 未登记的 deepseek 模型：pro 系走 pro 价，其余按 flash 价
        tier = name.contains("pro") ? "pro" : "flash"
    }
    guard let tier, let entry = deepSeekPrices[tier] else { return nil }
    return peak ? entry.peak : entry.offpeak
}

func turnCost(_ turn: TurnUsage) -> (amount: Double, peak: Bool)? {
    let peak = isPeakHour(turn.ts)
    guard let price = deepSeekPrice(for: turn.model, peak: peak) else { return nil }
    let hit = turn.cached
    let miss = max(turn.input - hit, 0)
    let amount = Double(hit) / 1_000_000 * price.hit
        + Double(miss) / 1_000_000 * price.miss
        + Double(turn.output) / 1_000_000 * price.output
    return (amount, peak)
}

struct Snapshot {
    var codex = SourceSnapshot()
    var claude = SourceSnapshot()

    // 菜单栏显示两个来源的今日合计
    var todayTotal: Int { codex.today.total + claude.today.total }
    var todayCost: Double { codex.todayCost.total + claude.todayCost.total }
}

struct SourceSnapshot {
    var today = Totals()
    var todayByModel: [ModelTotals] = []
    var weekByModel: [ModelTotals] = []
    var todayTopSessions: [SessionTotals] = []
    var todayCost = Cost()
    var weekCost = Cost()

    var weekTotalTokens: Int { weekByModel.reduce(0) { $0 + $1.totals.total } }

    // Top 5 这五个会话的费用合计
    var topSessionsCost: Cost {
        todayTopSessions.reduce(Cost()) { partial, item in
            var result = partial
            result.add(item.cost.peak, peak: true)
            result.add(item.cost.offpeak, peak: false)
            return result
        }
    }
}

// token 数量显示：1 亿以内用「万」（整数），超过 1 亿改用「亿」（两位小数）
func tokens(_ value: Int) -> String {
    if value >= 100_000_000 {
        return String(format: "%.2f亿", Double(value) / 100_000_000)
    }
    return String(format: "%.0f万", Double(value) / 10000)
}

// 金额保留两位小数
func money(_ value: Double) -> String {
    String(format: "%.2f", value)
}

// 金额只显示总额（高峰/空闲仍按官方两档价格分别计价，只是不再拆开展示）
func costText(_ cost: Cost) -> String {
    "¥\(money(cost.total))"
}

// MARK: - 扫描会话文件

// 会话标题存放在 session_index.jsonl，按 thread id 关联
func loadThreadNames() -> [String: String] {
    guard let text = try? String(contentsOfFile: sessionIndexFile, encoding: .utf8) else { return [:] }
    var names: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = object["id"] as? String,
              let name = object["thread_name"] as? String,
              !name.isEmpty else { continue }
        names[id] = name
    }
    return names
}

func threadIDFromStem(_ stem: String) -> String {
    guard let range = stem.range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
                                options: .regularExpression) else { return stem }
    return String(stem[range])
}

// 在文件字节流里定位含指定关键字的整行，避免逐行扫描整个文本
func forEachLine(in data: Data, containing marker: Data, _ body: (Data) -> Void) {
    var cursor = data.startIndex
    while cursor < data.endIndex,
          let hit = data.range(of: marker, options: [], in: cursor..<data.endIndex) {
        let lineStart = data[data.startIndex..<hit.lowerBound].lastIndex(of: 0x0A).map { data.index(after: $0) }
            ?? data.startIndex
        let lineEnd = data[hit.upperBound..<data.endIndex].firstIndex(of: 0x0A) ?? data.endIndex
        body(data[lineStart..<lineEnd])
        cursor = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
    }
}

func jsonlFiles(under root: String, newerThan cutoff: Date) -> [URL] {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey]
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: root),
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var files: [URL] = []
    for case let url as URL in enumerator {
        guard url.pathExtension == "jsonl" else { continue }
        guard let values = try? url.resourceValues(forKeys: keys),
              let modified = values.contentModificationDate,
              modified >= cutoff else { continue }
        files.append(url)
    }
    return files
}

func scanRecentTurns(days: Int) -> [TurnUsage] {
    let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
    let contextMarker = Data("\"turn_context\"".utf8)
    let usageMarker = Data("\"token_usage_record\"".utf8)

    // turn_id -> (model, cwd)
    var contexts: [String: (model: String, cwd: String)] = [:]
    // turn_id -> 该轮最后一次调用后的累计用量
    var records: [String: (ts: Date, stem: String, usage: [String: Int])] = [:]

    for url in jsonlFiles(under: sessionsRoot, newerThan: cutoff) {
        guard let data = try? Data(contentsOf: url) else { continue }
        let stem = url.deletingPathExtension().lastPathComponent

        forEachLine(in: data, containing: contextMarker) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let turnID = payload["turn_id"] as? String else { return }
            contexts[turnID] = (
                payload["model"] as? String ?? "未知",
                payload["cwd"] as? String ?? ""
            )
        }

        forEachLine(in: data, containing: usageMarker) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let turnID = payload["turn_id"] as? String,
                  let timestamp = object["timestamp"] as? String,
                  let date = parseTimestamp(timestamp) else { return }
            let raw = (payload["turn_token_usage"] as? [String: Any])
                ?? (payload["usage"] as? [String: Any]) ?? [:]
            var usage: [String: Int] = [:]
            for (key, value) in raw {
                if let number = value as? NSNumber { usage[key] = number.intValue }
            }
            // 同一轮可能有多次调用，turn_token_usage 是累计值，取最后一条即可
            records[turnID] = (date, stem, usage)
        }
    }

    return records.map { turnID, record in
        let context = contexts[turnID]
        let input = record.usage["input_tokens"] ?? 0
        let output = record.usage["output_tokens"] ?? 0
        let recorded = record.usage["total_tokens"] ?? 0
        return TurnUsage(
            ts: record.ts,
            threadID: threadIDFromStem(record.stem),
            project: (context?.cwd as NSString?)?.lastPathComponent ?? "",
            label: String(threadIDFromStem(record.stem).prefix(8)),
            model: context?.model ?? "未知",
            input: input,
            cached: record.usage["cached_input_tokens"] ?? 0,
            output: output,
            total: recorded > 0 ? recorded : input + output
        )
    }
}

// MARK: - 扫描 Claude Code 会话文件

func scanClaudeTurns(days: Int) -> (turns: [TurnUsage], titles: [String: String]) {
    let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
    let assistantMarker = Data("\"type\":\"assistant\"".utf8)
    let titleMarker = Data("\"ai-title\"".utf8)
    var records: [String: (ts: Date, session: String, cwd: String, model: String, input: Int, cached: Int, output: Int)] = [:]
    var titles: [String: String] = [:]

    for url in jsonlFiles(under: claudeProjectsRoot, newerThan: cutoff) {
        guard let data = try? Data(contentsOf: url) else { continue }

        forEachLine(in: data, containing: titleMarker) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let title = object["aiTitle"] as? String, !title.isEmpty,
                  let session = object["sessionId"] as? String else { return }
            titles[session] = title
        }

        forEachLine(in: data, containing: assistantMarker) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let messageID = message["id"] as? String,
                  let timestamp = object["timestamp"] as? String,
                  let date = parseTimestamp(timestamp) else { return }
            let usage = message["usage"] as? [String: Any] ?? [:]
            let fresh = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
            let cacheWrite = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
            let output = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
            // 跳过不消耗 token 的占位消息（例如 model 为 <synthetic> 的内部条目）
            guard fresh + cacheRead + cacheWrite + output > 0 else { return }
            let session = object["sessionId"] as? String ?? url.deletingPathExtension().lastPathComponent
            // 同一响应会被重复写多行，按 message.id 去重；输入口径对齐 Codex（含缓存）
            records["\(session)|\(messageID)"] = (
                date,
                session,
                object["cwd"] as? String ?? "",
                message["model"] as? String ?? "未知",
                fresh + cacheRead + cacheWrite,
                cacheRead,
                output
            )
        }
    }

    let turns = records.values.map { record in
        TurnUsage(
            ts: record.ts,
            threadID: record.session,
            project: (record.cwd as NSString).lastPathComponent,
            label: String(record.session.prefix(8)),
            model: record.model,
            input: record.input,
            cached: record.cached,
            output: record.output,
            total: record.input + record.output
        )
    }
    return (turns, titles)
}

// MARK: - 聚合

func aggregate(turns: [TurnUsage], names: [String: String], todayStart: Date, weekStart: Date) -> SourceSnapshot {
    var result = SourceSnapshot()
    var todayModels: [String: ModelTotals] = [:]
    var weekModels: [String: ModelTotals] = [:]
    var todayCost = Cost()
    var weekCost = Cost()
    // 按会话分组，展示名优先用会话标题，取不到标题时回退到 项目名/短号
    var sessions: [String: (project: String, entry: SessionTotals)] = [:]

    for turn in turns {
        let charged = turnCost(turn)
        if turn.ts >= weekStart {
            var entry = weekModels[turn.model] ?? ModelTotals(model: turn.model, totals: Totals())
            entry.totals.add(turn)
            if let charged {
                entry.cost.add(charged.amount, peak: charged.peak)
                weekCost.add(charged.amount, peak: charged.peak)
            }
            weekModels[turn.model] = entry
        }
        if turn.ts >= todayStart {
            result.today.add(turn)
            var modelEntry = todayModels[turn.model] ?? ModelTotals(model: turn.model, totals: Totals())
            modelEntry.totals.add(turn)
            if let charged {
                modelEntry.cost.add(charged.amount, peak: charged.peak)
                todayCost.add(charged.amount, peak: charged.peak)
            }
            todayModels[turn.model] = modelEntry
            var item = sessions[turn.threadID] ?? (turn.project, SessionTotals(name: "", totals: Totals()))
            if item.project.isEmpty {
                item.project = turn.project
            }
            item.entry.totals.add(turn)
            if let charged { item.entry.cost.add(charged.amount, peak: charged.peak) }
            sessions[turn.threadID] = item
        }
    }

    result.todayByModel = todayModels.values.sorted { $0.totals.total > $1.totals.total }
    result.weekByModel = weekModels.values.sorted { $0.totals.total > $1.totals.total }
    result.todayTopSessions = sessions
        .map { threadID, value in
            let fallback = value.project.isEmpty ? String(threadID.prefix(8)) : "\(value.project)/\(String(threadID.prefix(8)))"
            return SessionTotals(
                name: names[threadID] ?? fallback,
                totals: value.entry.totals,
                cost: value.entry.cost
            )
        }
        .sorted { $0.totals.total > $1.totals.total }
        .prefix(5)
        .map { $0 }
    result.todayCost = todayCost
    result.weekCost = weekCost
    return result
}

func buildSnapshot(days: Int = scanDays) -> Snapshot {
    let calendar = Calendar.current
    let todayStart = calendar.startOfDay(for: Date())
    let weekStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart

    let claudeScan = scanClaudeTurns(days: days)
    var snapshot = Snapshot()
    snapshot.codex = aggregate(
        turns: scanRecentTurns(days: days),
        names: loadThreadNames(),
        todayStart: todayStart,
        weekStart: weekStart
    )
    snapshot.claude = aggregate(
        turns: claudeScan.turns,
        names: claudeScan.titles,
        todayStart: todayStart,
        weekStart: weekStart
    )
    return snapshot
}

// --dump 模式下打印的纯文本，便于在终端里核对统计结果
func dumpText() -> String {
    let snapshot = buildSnapshot()
    var lines: [String] = []

    func append(_ name: String, _ source: SourceSnapshot) {
        lines.append("【\(name)】今日（合计 \(tokens(source.today.total))）  \(costText(source.todayCost))")
        for item in source.todayByModel {
            lines.append("  \(item.model)  输入 \(tokens(item.totals.input))  输出 \(tokens(item.totals.output))  "
                + "缓存 \(tokens(item.totals.cached))  合计 \(tokens(item.totals.total))  "
                + "金额 ¥\(money(item.cost.total))")
        }
        lines.append("【\(name)】一周汇总（近 7 天，共 \(tokens(source.weekTotalTokens))）  \(costText(source.weekCost))")
        for item in source.weekByModel {
            lines.append("  \(item.model)  输入 \(tokens(item.totals.input))  输出 \(tokens(item.totals.output))  "
                + "缓存 \(tokens(item.totals.cached))  合计 \(tokens(item.totals.total))  "
                + "金额 ¥\(money(item.cost.total))")
        }
        lines.append("【\(name)】今日会话 Top 5（按总 token 倒序）  \(costText(source.topSessionsCost))")
        for (index, item) in source.todayTopSessions.enumerated() {
            lines.append("  \(index + 1). \(item.name)  输入 \(tokens(item.totals.input))  "
                + "输出 \(tokens(item.totals.output))  缓存 \(tokens(item.totals.cached))  合计 \(tokens(item.totals.total))"
                + "  金额 ¥\(money(item.cost.total))")
        }
    }

    append("Codex", snapshot.codex)
    append("Claude", snapshot.claude)
    return lines.joined(separator: "\n")
}

// MARK: - 状态与视图

// 面板字号档位，各档位同时决定表格列宽和面板宽度
enum FontSize: String, CaseIterable {
    case small, medium, large

    var label: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    private var base: CGFloat {
        switch self {
        case .small: return 12
        case .medium: return 14
        case .large: return 16
        }
    }

    var group: CGFloat { base + 3 }
    var title: CGFloat { base }
    var header: CGFloat { base - 2 }
    var cell: CGFloat { base }
    var modelColumn: CGFloat { base * 12.5 }
    var sessionColumn: CGFloat { base * 21 }
}

final class Store: ObservableObject {
    @Published var snapshot = Snapshot()
    private let queue = DispatchQueue(label: "codexstats.scan")

    init() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        queue.async {
            let snapshot = buildSnapshot()
            DispatchQueue.main.async { self.snapshot = snapshot }
        }
    }
}

struct StatsTable: View {
    var headers: [String]
    var rows: [[String]]
    var firstColumnWidth: CGFloat? = nil
    var size: FontSize = .medium

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    Text(header)
                        .font(.system(size: size.header))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(index == 0 ? .leading : .trailing)
                        .frame(width: index == 0 ? firstColumnWidth : nil, alignment: .leading)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                        Text(cell)
                            .font(.system(size: size.cell, design: .monospaced))
                            .gridColumnAlignment(index == 0 ? .leading : .trailing)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: index == 0 ? firstColumnWidth : nil, alignment: .leading)
                    }
                }
            }
        }
    }
}

struct Panel: View {
    var snapshot: Snapshot
    var onAppear: () -> Void

    @AppStorage("fontSize") private var fontSizeRaw = FontSize.medium.rawValue

    private var size: FontSize { FontSize(rawValue: fontSizeRaw) ?? .medium }

    private var fontPicker: some View {
        Picker("字号", selection: $fontSizeRaw) {
            ForEach(FontSize.allCases, id: \.rawValue) { item in
                Text(item.label).tag(item.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 132)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SourceBlock(name: "Codex", source: snapshot.codex, size: size) {
                fontPicker
            }
            Divider()
            SourceBlock(name: "Claude", source: snapshot.claude, size: size) {
                EmptyView()
            }
        }
        .padding(14)
        .fixedSize()
        .onAppear(perform: onAppear)
    }
}

struct SourceBlock<Trailing: View>: View {
    var name: String
    var source: SourceSnapshot
    var size: FontSize
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(name).font(.system(size: size.group, weight: .semibold))
                Spacer(minLength: 16)
                trailing()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("今日（合计 \(tokens(source.today.total))）  \(costText(source.todayCost))")
                    .font(.system(size: size.title, weight: .bold))
                if source.todayByModel.isEmpty {
                    Text("今日暂无数据").font(.system(size: size.title)).foregroundStyle(.secondary)
                } else {
                    StatsTable(
                        headers: ["模型", "输入", "输出", "缓存", "金额¥"],
                        rows: source.todayByModel.map {
                            [$0.model, tokens($0.totals.input), tokens($0.totals.output), tokens($0.totals.cached),
                             money($0.cost.total)]
                        },
                        firstColumnWidth: size.modelColumn,
                        size: size
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("一周汇总（近 7 天，共 \(tokens(source.weekTotalTokens))）  \(costText(source.weekCost))")
                    .font(.system(size: size.title, weight: .bold))
                if source.weekByModel.isEmpty {
                    Text("近 7 天暂无数据").font(.system(size: size.title)).foregroundStyle(.secondary)
                } else {
                    StatsTable(
                        headers: ["模型", "输入", "输出", "缓存", "金额¥"],
                        rows: source.weekByModel.map {
                            [$0.model, tokens($0.totals.input), tokens($0.totals.output), tokens($0.totals.cached),
                             money($0.cost.total)]
                        },
                        firstColumnWidth: size.modelColumn,
                        size: size
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("今日会话 Top 5  \(costText(source.topSessionsCost))")
                    .font(.system(size: size.title, weight: .bold))
                if source.todayTopSessions.isEmpty {
                    Text("今日暂无数据").font(.system(size: size.title)).foregroundStyle(.secondary)
                } else {
                    StatsTable(
                        headers: ["会话", "输入", "输出", "缓存", "金额¥"],
                        rows: source.todayTopSessions.map {
                            [$0.name, tokens($0.totals.input), tokens($0.totals.output), tokens($0.totals.cached),
                             money($0.cost.total)]
                        },
                        firstColumnWidth: size.sessionColumn,
                        size: size
                    )
                }
            }
        }
    }
}

// MARK: - 入口

@main
struct CodexStatsApp: App {
    @StateObject private var store = Store()

    init() {
        if CommandLine.arguments.contains("--dump") {
            print(dumpText())
            exit(0)
        }
        // 调试用：按轮输出，便于和参考实现逐条比对
        if CommandLine.arguments.contains("--dump-turns") {
            let todayStart = Calendar.current.startOfDay(for: Date())
            let turns = scanRecentTurns(days: scanDays)
                .filter { $0.ts >= todayStart }
                .sorted { $0.ts < $1.ts }
            for turn in turns {
                print("\(turn.label)\t\(turn.total)\t\(Int(turn.ts.timeIntervalSince1970))")
            }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel(snapshot: store.snapshot) { store.refresh() }
        } label: {
            Text("今日 \(tokens(store.snapshot.todayTotal)) | ¥\(money(store.snapshot.todayCost))")
        }
        .menuBarExtraStyle(.window)
    }
}

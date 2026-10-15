import WidgetKit
import SwiftUI
import AppIntents
import os.log

struct FarmEntry: TimelineEntry {
    let date: Date
    let records: [CropRecord]
    let pageIndex: Int
}

struct Provider: TimelineProvider {
    private static let logger = Logger(
        subsystem: "com.yixin.farmharvest",
        category: "WidgetTimeline"
    )

    func placeholder(in context: Context) -> FarmEntry {
        FarmEntry(date: Date(), records: CropStore.load(), pageIndex: Self.savedPageIndex)
    }
    func getSnapshot(in context: Context, completion: @escaping (FarmEntry) -> Void) {
        if context.isPreview {
            let now = Date()
            let preview = CropStore.presets.map { p in
                CropRecord(id: p.id, name: p.name, colorHex: p.colorHex, minutes: p.minutes,
                           plantedAt: now,
                           harvests: [HarvestCycle(
                               date: now.addingTimeInterval(Double(p.minutes * 60)))],
                           note: nil)
            }
            completion(FarmEntry(date: now, records: preview, pageIndex: Self.savedPageIndex))
        } else {
            completion(FarmEntry(date: Date(), records: CropStore.load(), pageIndex: Self.savedPageIndex))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FarmEntry>) -> Void) {
        let records = CropStore.load()
        let now = Date()
        let pageIndex = Self.savedPageIndex
        Self.logger.info(
            "Providing timeline: pageIndex=\(pageIndex, privacy: .public), records=\(records.count, privacy: .public)"
        )

        // Interactive widget intents trigger a timeline reload when they finish.
        // Keep the archive to one entry so each tap doesn't serialize hundreds
        // of near-identical entries before the updated page can be displayed.
        let entry = FarmEntry(date: now, records: records, pageIndex: pageIndex)
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(60))))
    }

    private static var savedPageIndex: Int {
        WidgetPageNavigation.currentPageIndex
    }
}

struct FarmHarvestWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: expandedLargeRows ? 0 : (family == .systemSmall ? 6 : 2)) {
                if entry.records.isEmpty {
                    Text("暂无记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else if family == .systemSmall {
                    ForEach(pageRecords) { r in
                        FarmRow(r: r, now: entry.date, single: true)
                    }
                    Spacer(minLength: 0)
                } else if expandedLargeRows {
                    ForEach(pageRecords.indices, id: \.self) { index in
                        CompactFarmRow(r: pageRecords[index])
                        if index < pageRecords.count - 1 {
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    ForEach(pageRecords) { r in
                        CompactFarmRow(r: r)
                    }
                    Spacer(minLength: 0)
                }
            }
            // Keep the floating pager clear of row content without reserving
            // a full-width header row for the title and page controls.
            .padding(.trailing, totalPages > 1 ? 36 : 0)

            if totalPages > 1 {
                pageControls
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // macOS 26+ 强制要求：必须用 containerBackground 声明背景，
        // 否则渲染失败并显示 "Please adopt container/Background API"。
        .containerBackground(.background, for: .widget)
    }

    private var totalPages: Int {
        max(1, recordPages.count)
    }

    private var currentPage: Int {
        let page = entry.pageIndex % totalPages
        return page >= 0 ? page : page + totalPages
    }

    private var pageRecords: [CropRecord] {
        recordPages[currentPage]
    }

    private var expandedLargeRows: Bool {
        family == .systemLarge && pageRecords.count == 5
    }

    /// 中/大组件按完整作物记录分页，并根据组件尺寸增加可显示行数；
    /// 同一条记录的多茬时间始终放在一起，不拆成独立记录或跨页。
    private var recordPages: [[CropRecord]] {
        guard family != .systemSmall else {
            return entry.records.map { [$0] }
        }

        // Large 组件每页固定 5 条记录，记录卡均分高度铺满组件；
        // Medium 组件按完整记录分组，每页约 5 行收菜时间。
        if family == .systemLarge {
            let pageSize = 5
            let pages = stride(from: 0, to: entry.records.count, by: pageSize).map { start in
                Array(entry.records[start..<min(start + pageSize, entry.records.count)])
            }
            return pages.isEmpty ? [[]] : pages
        }

        let lineCapacity = 5
        var pages: [[CropRecord]] = []
        var page: [CropRecord] = []
        var usedLines = 0

        for record in entry.records {
            let lines = max(1, record.harvests.count)
            if !page.isEmpty, usedLines + lines > lineCapacity {
                pages.append(page)
                page = []
                usedLines = 0
            }
            page.append(record)
            usedLines += lines
        }

        if !page.isEmpty {
            pages.append(page)
        }
        return pages.isEmpty ? [[]] : pages
    }

    private var pageControls: some View {
        VStack(spacing: 4) {
            pageButton(
                symbol: "chevron.up",
                intent: PreviousWidgetPageIntent(),
                label: "上一页"
            )

            Text("\(currentPage + 1)/\(totalPages)")
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 30, minHeight: 18)
                .background(Color.primary.opacity(0.07), in: Capsule())

            pageButton(
                symbol: "chevron.down",
                intent: NextWidgetPageIntent(),
                label: "下一页"
            )
        }
        .padding(3)
        .background(Color.primary.opacity(0.045), in: Capsule())
    }

    private func pageButton<I: AppIntent>(
        symbol: String,
        intent: I,
        label: String
    ) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.09), in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 中/大组件专用的紧凑记录卡；同一条记录的多茬收菜时间分行显示。
private struct CompactFarmRow: View {
    let r: CropRecord

    private var cycles: [HarvestCycle] {
        r.harvests.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if cycles.isEmpty {
                HStack(spacing: 7) {
                    cropBadge
                    cropName
                    Spacer(minLength: 3)
                    Text("未设置收菜时间")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(height: 18)
            } else {
                ForEach(Array(cycles.enumerated()), id: \.element.id) { index, cycle in
                    cycleLine(cycle, showsName: index == 0)
                }
            }

            if let note = r.note, !note.isEmpty {
                NotePresetRecordNote(note: note)
                    .font(.system(size: 9))
                    .padding(.leading, 24)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    private var cropBadge: some View {
        Circle()
            .fill(Color(hex: r.colorHex))
            .frame(width: 17, height: 17)
            .overlay(
                Text(String(r.name.prefix(1)))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white)
            )
    }

    private var cropName: some View {
        Text(r.name)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func cycleLine(_ cycle: HarvestCycle, showsName: Bool) -> some View {
        HStack(spacing: 7) {
            if showsName {
                cropBadge
                cropName
            } else {
                Color.clear
                    .frame(width: 17, height: 17)
            }

            Spacer(minLength: 3)
            Text(fmt(cycle.date))
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            compactStatus(cycle)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private func compactStatus(_ cycle: HarvestCycle) -> some View {
        if cycle.harvested {
            Text("已收")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.green)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = cycle.date.timeIntervalSince(context.date)
                if left <= 0 {
                    Text("可收")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                } else {
                    Text(remainText(cycle.date, now: context.date))
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(left <= 20 * 60 ? .orange : .secondary)
                }
            }
        }
    }
}

/// 单行：与 App 主界面 RecordRow 完全一致的结构 ——
/// 名字 + 每茬收菜时间单独一行（MM-dd HH:mm 徽标 + 该茬倒计时/状态）+ 2 行备注。
struct FarmRow: View {
    let r: CropRecord
    let now: Date
    let single: Bool

    // 字号基准：single（systemSmall，只显示 1 条）时整体放大一档，
    // 中/大组件按桌面空间用 caption/caption2 档，保证与 App 行结构一致。
    private var nameFont: Font { single ? .subheadline.bold() : .caption.bold() }
    private var timeFont: Font { single ? .callout.weight(.semibold) : .caption2.weight(.semibold) }
    private var countFont: Font { single ? .callout : .caption2 }

    var body: some View {
        HStack(spacing: single ? 8 : 10) {
            Circle()
                .fill(Color(hex: r.colorHex))
                .frame(width: single ? 30 : 22, height: single ? 30 : 22)
                .overlay(Text(String(r.name.prefix(1)))
                    .font(single ? .system(size: 14) : .system(size: 10))
                    .foregroundColor(.white))
            VStack(alignment: .leading, spacing: single ? 3 : 4) {
                Text(r.name).font(nameFont)

                // 每茬收菜时间单独一行：多茬时全部时间点直接铺开，
                // 一眼看清哪几茬已收、哪几茬还等着（与 App 记录行一致）
                if r.harvests.isEmpty {
                    Text("未设置收菜时间")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    ForEach(r.harvests) { c in harvestLine(c) }
                }

                if let note = r.note, !note.isEmpty {
                    // 与主界面记录行同一渲染（NotePresets.highlighted）：
                    // 命中分组的词组色 + 色点，其余灰色，保证两端展示一致
                    NotePresetRecordNote(note: note)
                        .font(.caption2)
                }
            }
            Spacer(minLength: 2)
        }
        .padding(single ? 10 : 8)
        // Widget 内不宜用 glassEffect（材质在小组件里渲染不稳定），改半透明底色
        .background(Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 单茬收菜时间的一行：MM-dd HH:mm 徽标 + 该茬倒计时/状态（与 App 一致）
    private func harvestLine(_ c: HarvestCycle) -> some View {
        HStack(spacing: 6) {
            let left = c.date.timeIntervalSince(now)
            let tint: Color = c.harvested ? .green
                : (left <= 0 || left <= Self.urgentSeconds ? .orange : .accentColor)
            let strength: Double = c.harvested ? 0.10
                : (left <= 0 || left <= Self.urgentSeconds ? 0.22 : 0.16)

            Text(fmt(c.date))
                .font(timeFont)
                .monospacedDigit()
                .foregroundStyle(c.harvested ? Color.secondary : tint)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(tint.opacity(strength),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            countdownView(c)
        }
    }

    /// 倒计时单独包 TimelineView：与 App 一致，只有这个 Text 随时间重建，
    /// 外层的时刻底色、整张列表都不重绘。
    private func countdownView(_ c: HarvestCycle) -> some View {
        if c.harvested {
            return AnyView(Text("已收")
                .font(countFont.weight(.medium))
                .foregroundStyle(.green))
        }
        return AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = c.date.timeIntervalSince(context.date)
            if left <= 0 {
                // 到期未收：最需要被看到的状态，给实心胶囊
                Text("可收")
                    .font(countFont.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange, in: Capsule())
            } else if left <= Self.urgentSeconds {
                // 临近（≤20 分钟）：加深、加底色、加粗
                Text(remainText(c.date, now: context.date))
                    .font(countFont.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                // 常规：灰色等宽，不抢视线
                Text(remainText(c.date, now: context.date))
                    .font(countFont.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        })
    }

    /// 临近阈值：20 分钟内进入高亮态（与 App 一致）
    private static let urgentSeconds: TimeInterval = 20 * 60
}

@main
struct FarmHarvestWidget: Widget {
    let kind = "FarmHarvestWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            FarmHarvestWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("农场收菜")
        .description("记录蔬菜收菜时间，使用上下箭头翻页浏览，桌面实时倒计时。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

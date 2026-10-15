import WidgetKit
import SwiftUI

struct FarmEntry: TimelineEntry {
    let date: Date
    let records: [CropRecord]
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> FarmEntry {
        FarmEntry(date: Date(), records: CropStore.load())
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
            completion(FarmEntry(date: now, records: preview))
        } else {
            completion(FarmEntry(date: Date(), records: CropStore.load()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FarmEntry>) -> Void) {
        let records = CropStore.load()
        let now = Date()
        var entries: [FarmEntry] = []

        // 每分钟刷新一次，覆盖到最远收获时间（最多 6 小时）。
        // 必须取 allHarvests 的最大值：一���记录有多次采收时，最后一茬
        // 才是真正的时间下界，只看 harvestAt 会导致后面几茬不刷新。
        let horizon = records.flatMap(\.allHarvests).max() ?? now.addingTimeInterval(3600)
        let end = min(horizon, now.addingTimeInterval(6 * 3600))
        var t = now
        while t <= end {
            entries.append(FarmEntry(date: t, records: records))
            t.addTimeInterval(60)
        }
        if entries.isEmpty {
            entries = [FarmEntry(date: now, records: records)]
        }
        completion(Timeline(entries: entries, policy: .after(end.addingTimeInterval(60))))
    }
}

struct FarmHarvestWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("农场收菜").font(.headline).padding(.bottom, 2)
            if entry.records.isEmpty {
                Text("暂无记录").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(entry.records.prefix(limit))) { r in
                    FarmRow(r: r, now: entry.date, single: family == .systemSmall)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // macOS 26+ 强制要求：必须用 containerBackground 声明背景，
        // 否则渲染失败并显示 "Please adopt container/Background API"。
        .containerBackground(.background, for: .widget)
    }

    /// 展示条数：小组件 1 条（大字模式）；中/大组件按高度预算动态取，
    /// 保证每条都完整展示（名字 + 全部收菜行 + 备注），不会被裁切。
    private var limit: Int {
        switch family {
        case .systemSmall: return 1
        case .systemMedium: return fitCount(budget: 105)
        default: return fitCount(budget: 295)
        }
    }

    /// 逐条累加估算行高，超出预算即停（估算与 FarmRow 实际布局对应，宁少勿裁）
    private func fitCount(budget: CGFloat) -> Int {
        var used: CGFloat = 0
        var n = 0
        for r in entry.records {
            let noteLines: CGFloat = (r.note?.isEmpty == false) ? 26 : 0
            let h: CGFloat = 16                                      // 名字行
                + CGFloat(max(r.harvests.count, 1)) * 19             // 收菜行（异常数据至少 1 行）
                + noteLines + 14 + 6                                 // 内边距 + 行间距
            if n > 0, used + h > budget { break }
            used += h
            n += 1
        }
        return max(1, n)
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
        .description("记录蔬菜收菜时间，桌面实时倒计时。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

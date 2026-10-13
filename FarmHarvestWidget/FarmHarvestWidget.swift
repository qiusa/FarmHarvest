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
                           harvestAt: now.addingTimeInterval(Double(p.minutes * 60)),
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

        // 每分钟刷新一次，覆盖到最远收获时间（最多 6 小时）
        let horizon = records.map(\.harvestAt).max() ?? now.addingTimeInterval(3600)
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

    private var limit: Int {
        switch family {
        case .systemSmall: return 1
        case .systemMedium: return 3
        default: return 6
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("农场收菜").font(.headline).padding(.bottom, 2)
            if entry.records.isEmpty {
                Text("暂无记录").font(.caption).foregroundStyle(.secondary)
            } else {
                GlassEffectContainer(spacing: 6) {
                    ForEach(Array(entry.records.prefix(limit))) { r in
                        FarmRow(r: r, now: entry.date, single: limit == 1)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 单行：突出显示收菜时刻（HH:mm），到时间高亮「可收获」
struct FarmRow: View {
    let r: CropRecord
    let now: Date
    let single: Bool
    private var ready: Bool { r.harvestAt <= now }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: r.colorHex))
                .frame(width: single ? 30 : 20, height: single ? 30 : 20)
                .overlay(Text(String(r.name.prefix(1)))
                    .font(single ? .system(size: 14) : .system(size: 10))
                    .foregroundColor(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(single ? .callout : .caption2).lineLimit(1)
                Text(hhmm(r.harvestAt))
                    .font(single ? .largeTitle : .headline).bold()
                    .foregroundColor(ready ? .orange : .primary)
                    .monospacedDigit()
                if let note = r.note, !note.isEmpty, !single {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if ready {
                    Text("可收获")
                        .font(single ? .title3 : .caption).bold()
                        .foregroundColor(.green)
                } else {
                    Text(remain())
                        .font(single ? .title3 : .caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func hhmm(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private func remain() -> String {
        let s = max(0, Int(r.harvestAt.timeIntervalSince(now)))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%02d:%02d", m, sec)
    }
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

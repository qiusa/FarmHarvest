import SwiftUI
import AppKit
import UserNotifications

/// 录入/编辑的时间模式
enum InputMode: String, CaseIterable, Identifiable {
    case minutes = "按成熟分钟数"
    case absolute = "按指定收菜时间"
    var id: String { rawValue }
}

func fmt(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    return f.string(from: d)
}

/// 把总分钟数格式化为「x 小时 y 分钟」（整小时省略分钟部分）
func formatDurationText(_ total: Int) -> String {
    let h = total / 60
    let m = total % 60
    if h > 0 && m > 0 { return "\(h) 小时 \(m) 分钟" }
    if h > 0 { return "\(h) 小时" }
    return "\(m) 分钟"
}

func remainText(_ r: CropRecord) -> String {
    // 有多次采收时，倒计时对准「下一茬」而不是首次，
    // 否则首次过了之后会永远停在 00:00，看不出还要等多久收第二茬。
    guard let next = r.nextHarvest else { return "可收获" }
    return remainText(next)
}

/// 距离某个时间点还有多久。
/// now 参数可选：实时倒计时场景应传入 TimelineView 的 context.date，
/// 保持与「是否到期」的判定同源，否则两者会差出一次 tick 的误差。
func remainText(_ target: Date, now: Date = Date()) -> String {
    let s = max(0, Int(target.timeIntervalSince(now)))
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, sec)
        : String(format: "%02d:%02d", m, sec)
}

/// 本地通知：到期前 1 分钟提醒（主 App 负责调度，Widget 不可发通知）
enum CropNotifier {
    /// App 启动时申请一次通知授权
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// 依据当前记录重排"提前 1 分钟"的本地通知（每次记录变更都整表重排）
    /// 一条记录可能有多个收菜时间点，每个都要单独排一条通知，
    /// 且 identifier 必须带时间戳区分 —— 否则同一 id 的多次通知会互相覆盖，
    /// 结果只有第一茬能收到提醒。
    static func reschedule(_ records: [CropRecord]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()
        for r in records {
            for (idx, hAt) in r.allHarvests.enumerated() {
                let fire = hAt.addingTimeInterval(-60) // 提前 1 分钟
                guard fire > now else { continue }
                let content = UNMutableNotificationContent()
                let total = r.allHarvests.count
                content.title = total > 1
                    ? "\(r.name) 即将可收菜（第 \(idx + 1)/\(total) 次）"
                    : "\(r.name) 即将可收菜"
                content.body = "还有 1 分钟 · 收菜时间 \(fmt(hAt))"
                content.sound = .default
                content.badge = 1
                let secs = fire.timeIntervalSince(now)
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
                // identifier 里带时间戳，保证多茬的请求不会互相替换
                let req = UNNotificationRequest(
                    identifier: "harvest-\(r.id)-\(Int(hAt.timeIntervalSince1970))",
                    content: content, trigger: trigger)
                center.add(req)
            }
        }
    }
}

/// 统一的"左对齐标签 + 控件跟随"行（替代 Form 的错位对齐）
struct LabeledField<Content: View>: View {
    let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

/// 弹窗里的玻璃卡片容器
struct GlassPanel<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        }
    }
}

struct ContentView: View {
    @State private var records: [CropRecord] = CropStore.load()
    // 必须缓存成 @State：CropStore.presets 是计算属性，改动文件后 SwiftUI 不会
    // 自行感知，弹窗关闭时需主动刷新，否则主界面蔬菜列表不会同步。
    @State private var presets: [CropPreset] = CropStore.presets
    @State private var selectedPresetID: String = CropStore.presets.first?.id ?? ""
    @State private var hoursText: String = "0"
    @State private var minutesText: String = ""
    @State private var inputMode: InputMode = .minutes
    @State private var harvestDate: Date = Date().addingTimeInterval(20 * 60)
    @State private var editTarget: CropRecord?
    @State private var showAddCrop: Bool = false
    @State private var noteText: String = ""
    @State private var saveFailed: Bool = false
    @State private var diagLines: [String] = []
    @State private var diagExpanded: Bool = false
    @State private var clearReadyConfirm: Bool = false

    private var selectedPreset: CropPreset? {
        presets.first { $0.id == selectedPresetID }
    }

    /// 刷新蔬菜列表；若当前选中项已被删除，自动切到第一个可用蔬菜
    private func reloadPresets() {
        let latest = CropStore.presets
        presets = latest
        if !latest.contains(where: { $0.id == selectedPresetID }) {
            if let first = latest.first {
                selectedPresetID = first.id
                hoursText = "\(first.minutes / 60)"
                minutesText = "\(first.minutes % 60)"
                harvestDate = Date().addingTimeInterval(TimeInterval(first.minutes * 60))
            } else {
                selectedPresetID = ""
            }
        } else if let cur = latest.first(where: { $0.id == selectedPresetID }) {
            // 选中的蔬菜可能被改了名字/时长，同步刷新「成熟时长」输入框
            hoursText = "\(cur.minutes / 60)"
            minutesText = "\(cur.minutes % 60)"
        }
    }

    /// 小时 + 分钟 折算的总分钟数（非法输入按 0 处理）
    private var totalMinutes: Int {
        let h = max(0, Int(hoursText.trimmingCharacters(in: .whitespaces)) ?? 0)
        let m = max(0, Int(minutesText.trimmingCharacters(in: .whitespaces)) ?? 0)
        return h * 60 + m
    }

    private var canAdd: Bool {
        guard selectedPreset != nil else { return false }
        if inputMode == .minutes { return totalMinutes > 0 }
        return true
    }

    private var previewHarvest: String? {
        switch inputMode {
        case .minutes:
            guard totalMinutes > 0 else { return nil }
            return fmt(Date().addingTimeInterval(TimeInterval(totalMinutes * 60)))
        case .absolute:
            return fmt(harvestDate)
        }
    }

    var body: some View {
        NavigationStack {
            // 左右分栏：左侧录入、右侧收菜记录，首屏即可看到记录
            HStack(alignment: .top, spacing: 0) {
                inputPane
                    .frame(minWidth: 420, idealWidth: 480, maxWidth: 560)
                Divider()
                recordsPane
                    .frame(minWidth: 380)
            }
            .navigationTitle("农场收菜")
            .navigationSubtitle("桌面实时倒计时")
            .background(.clear)
            .onAppear {
                records = CropStore.load()
                CropNotifier.requestPermission()
                CropNotifier.reschedule(records)
                diagLines = CropStore.diagnoseEnvironment()
                CropStore.reloadWidget()
                reloadPresets()
                if minutesText.isEmpty, let m = presets.first?.minutes {
                    hoursText = "\(m / 60)"
                    minutesText = "\(m % 60)"
                }
            }
            .sheet(item: $editTarget) { target in
                EditRecordSheet(record: target) { updated in
                    CropStore.update(updated)
                    records = CropStore.load()
                    CropNotifier.reschedule(records)
                    editTarget = nil
                }
            }
            .sheet(isPresented: $showAddCrop, onDismiss: {
                // 弹窗内可能新增 / 删除 / 修改蔬菜，也可能在「数据」页导入备份，
                // 两种情况都会改磁盘，所以蔬菜列表 + 收菜记录 + 通知都要重新读一遍。
                reloadPresets()
                records = CropStore.load()
                CropNotifier.reschedule(records)
                CropStore.reloadWidget()
            }) {
                AddCropSheet(onAdded: { c in
                    reloadPresets()
                    selectedPresetID = c.id
                    hoursText = "\(c.minutes / 60)"
                    minutesText = "\(c.minutes % 60)"
                    harvestDate = Date().addingTimeInterval(TimeInterval(c.minutes * 60))
                    showAddCrop = false
                })
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .confirmationDialog("清除 \(readyCount) 条已收获的记录？",
                            isPresented: $clearReadyConfirm, titleVisibility: .visible) {
            Button("清除", role: .destructive) { clearReadyRecords() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已到收菜时间的记录将从列表中移除，此操作不可撤销。")
        }
    }

    private func formatPreviewText(_ s: String) -> String { s }

    // MARK: - 左栏：录入

    private var inputPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 「自定义 / 蔬菜管理」入口放在标题行右侧：原先它在横向滚动条末尾，
                // 内置蔬菜一多就被挤出可视区，必须横向滚动才点得到。
                HStack {
                    sectionHeader("选择蔬菜")
                    Spacer(minLength: 0)
                    Button { showAddCrop = true } label: {
                        Label("自定义", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("新增自定义蔬菜 / 管理已有蔬菜 / 导入导出备份")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 14) {
                        HStack(spacing: 14) {
                            ForEach(presets) { preset in
                                VegetableChip(preset: preset, selected: selectedPresetID == preset.id) {
                                    selectedPresetID = preset.id
                                    hoursText = "\(preset.minutes / 60)"
                                    minutesText = "\(preset.minutes % 60)"
                                    harvestDate = Date().addingTimeInterval(TimeInterval(preset.minutes * 60))
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .padding(.horizontal, 4)
                }

                sectionHeader("种植参数")
                GlassPanel {
                    VStack(alignment: .leading, spacing: 18) {
                        Picker("录入方式", selection: $inputMode) {
                            ForEach(InputMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        LabeledField("成熟时长") {
                            HStack(spacing: 6) {
                                TextField("0", text: $hoursText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 56)
                                    .multilineTextAlignment(.trailing)
                                Text("小时").font(.caption).foregroundStyle(.secondary)
                                TextField("30", text: $minutesText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 56)
                                    .multilineTextAlignment(.trailing)
                                Text("分钟").font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                if totalMinutes > 0 {
                                    Text("共 \(formatDurationText(totalMinutes))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .opacity(inputMode == .minutes ? 1 : 0.35)
                        .disabled(inputMode != .minutes)

                        LabeledField("收菜时间") {
                            DatePicker("", selection: $harvestDate,
                                      displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                        }
                        .opacity(inputMode == .absolute ? 1 : 0.35)
                        .disabled(inputMode != .absolute)

                        if let p = previewHarvest {
                            Label("收菜时间 \(formatPreviewText(p))", systemImage: "arrow.forward")
                                .font(.caption)
                                .foregroundStyle(.tint)
                                .padding(.leading, 122)
                        }

                        LabeledField("备注说明") {
                            TextEditor(text: $noteText)
                                .font(.caption)
                                .scrollContentBackground(.hidden)
                                .padding(5)
                                .frame(height: 52)
                                .background(Color.primary.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                        }

                        Button { addRecord() } label: {
                            Label("种下并记录", systemImage: "leaf.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canAdd)

                        if saveFailed {
                            Label("保存失败：无法写入磁盘，请检查磁盘权限后重试",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.red)
                        } else if !CropStore.isSharedContainerAvailable {
                            Label("桌面组件暂不同步：当前签名无法访问共享容器，记录仅保存在本机",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }

                        if !diagLines.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Button {
                                    withAnimation(.smooth) { diagExpanded.toggle() }
                                } label: {
                                    Label("存储自检\(diagExpanded ? " ▾" : " ▸")",
                                          systemImage: "stethoscope")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                if diagExpanded {
                                    ForEach(diagLines, id: \.self) { line in
                                        Text(line)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    // MARK: - 右栏：收菜记录（首屏可见）

    private var recordsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 统计条：待收 / 已收获。
            // 这两个数字只会在「某茬跨越到期时刻」时突变，与秒级倒计时不同源，
            // 所以用 5 秒粒度即可——比给整页套 1 秒刷新省 80% 的重绘开销。
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                HStack(spacing: 10) {
                    statTile(title: "待收", value: countPending(at: ctx.date), tint: .orange)
                    statTile(title: "可收获", value: countReady(at: ctx.date), tint: .green)
                    statTile(title: "总计", value: records.count, tint: .accentColor)
                }
            }

            HStack(spacing: 8) {
                Text("收菜记录")
                    .font(.headline)
                Text("\(records.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !records.isEmpty {
                    Button {
                        clearReadyConfirm = true
                    } label: {
                        Label("清除已收获", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(readyCount == 0)
                    .help("移除 \(readyCount) 条已到收菜时间的记录")
                }
            }

            if records.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "carrot")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("还没有记录")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("在左侧选好蔬菜和时长，点「种下并记录」")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(records) { r in
                            RecordRow(r: r, onEdit: { editTarget = r }, onDelete: { delete(r) })
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
    }

    private func statTile(title: String, value: Int, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.bold()).foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 全部采收完毕的记录数（「清除已收获」清的是这类）。
    /// 统计条用的是 countReady(at:)，这里供「清除已收获」按钮的可用性判断 ——
    /// 按钮不需要秒级刷新，records 变化时重算即可。
    private var readyCount: Int {
        records.filter { $0.isFullyHarvested }.count
    }

    /// 指定时刻的「全部了结」记录数。
    /// 统计条由 TimelineView 驱动，必须用传入的 ctx.date 判定，
    /// 不能在内部再读 Date()，否则与触发刷新的时间点不一致。
    private func countReady(at now: Date) -> Int {
        records.filter { rec in
            !rec.harvests.isEmpty
                && rec.harvests.allSatisfy { $0.harvested || $0.date <= now }
        }.count
    }

    private func countPending(at now: Date) -> Int {
        records.count - countReady(at: now)
    }

    /// 清除所有已采完的记录（带确认，避免误删）
    /// 注意：只删「所有采收时间都已到」的记录，还剩后续采收的必须留下。
    private func clearReadyRecords() {
        var remain = records
        remain.removeAll { $0.isFullyHarvested }
        guard remain.count != records.count else { return }
        CropStore.save(remain)
        records = CropStore.load()
        CropNotifier.reschedule(records)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .foregroundStyle(.primary)
            .padding(.leading, 4)
    }

    private func addRecord() {
        guard let preset = selectedPreset else { return }
        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteOrNil = note.isEmpty ? nil : note
        let before = records.count
        if inputMode == .minutes, totalMinutes > 0 {
            CropStore.add(preset: preset, minutes: totalMinutes, note: noteOrNil)
        } else if inputMode == .absolute {
            CropStore.addWithHarvestTime(preset: preset, harvestAt: harvestDate, note: noteOrNil)
        }
        noteText = ""
        records = CropStore.load()
        CropNotifier.reschedule(records)
        // 落盘后重新读回数量：不变说明写入失败，提示用户而不是静默无反应
        if records.count == before {
            saveFailed = true
        } else {
            saveFailed = false
        }
    }

    private func delete(_ r: CropRecord) {
        records.removeAll { $0.id == r.id }
        CropStore.save(records)
        CropNotifier.reschedule(records)
    }
}

/// 蔬菜选择卡片（玻璃质感，选中高亮）
struct VegetableChip: View {
    let preset: CropPreset
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: preset.colorHex),
                                                  Color(hex: preset.colorHex).opacity(0.7)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 50, height: 50)
                    .overlay(Text(String(preset.name.prefix(1)))
                        .foregroundColor(.white).font(.title3.bold()))
                Text(preset.name).font(.caption)
                Text("\(preset.minutes) 分").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 96)
            .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            .scaleEffect(selected ? 1.05 : 1.0)
            .animation(.smooth, value: selected)
        }
        .buttonStyle(.plain)
    }
}

/// 收菜记录行（玻璃卡片，右栏窄空间下用图标按钮 + hover 显示操作）
struct RecordRow: View {
    let r: CropRecord
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: r.colorHex),
                                              Color(hex: r.colorHex).opacity(0.7)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 36, height: 36)
                .overlay(Text(String(r.name.prefix(1)))
                    .foregroundColor(.white).font(.subheadline.bold()))
            VStack(alignment: .leading, spacing: 4) {
                Text(r.name).font(.subheadline.bold())

                // 每茬收菜时间单独一行：多茬时不再压缩成「第N茬」胶囊，
                // 全部时间点直接铺开，方便一眼看清哪几茬已收、哪几茬还等着。
                // 单茬时不画圆点 —— 一个孤零零的空心圈是噪音。
                if r.harvests.isEmpty {
                    // 异常数据兜底：正常路径下 harvests 至少一茬（编辑弹窗不允许删空）
                    Text("未设置收菜时间")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(r.harvests) { c in
                        harvestLine(c, showDot: r.harvests.count > 1)
                    }
                }

                if let note = r.note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            // 右侧不再放「可收获」徽标：行内每条到期时间已标「可收」，
            // 再放一个整条汇总会重复且看不出是哪茬到期。
            // 操作按钮：常态半透明，hover 时高亮，避免窄栏拥挤
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.4)
            .help("编辑")
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.red)
            .opacity(hovering ? 1 : 0.4)
            .help("删除")
        }
        .padding(12)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

    /// 单茬收菜时间的一行：勾选态 + 时间 + 该茬的倒计时/状态。
    /// showDot 只在多茬时为 true：圆点用来区分每一行，单茬时是多余噪音。
    /// 时间是这行的主角，用 callout + 半粗 + 底色块托住，倒计时用等宽数字紧随其后。
    private func harvestLine(_ c: HarvestCycle, showDot: Bool = true) -> some View {
        HStack(spacing: 8) {
            if showDot {
                // 圆点本身也要随「是否已收」变色，但不需要秒级刷新，
                // 交给外层随records 变更重建即可。
                Image(systemName: c.harvested ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(c.harvested ? Color.green : Color.secondary)
                    .frame(width: 13)   // 固定宽度，保证多行的时间右对齐成一列
            }

            // 时刻是静态文本，不需要每秒重绘
            Text(fmt(c.date))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(c.harvested ? Color.secondary
                                 : (c.date <= Date() ? Color.orange : Color.accentColor))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background((c.harvested ? Color.green
                              : (c.date <= Date() ? Color.orange : Color.accentColor))
                             .opacity(c.harvested ? 0.10 : 0.16),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            countdownView(c)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(c))
    }

    /// 倒计时单独包 TimelineView：
    /// **性能关键** —— 只有这一个 Text 会随时间重建，
    /// 外层的圆点、时刻底色、整张列表都不重绘。
    /// 若把 TimelineView 提到列表层，每秒会重算所有行，N 条记录 = N 倍无效工作。
    private func countdownView(_ c: HarvestCycle) -> some View {
        // 已收的不需要倒计时，也不该占用每秒刷新，直接返回静态视图
        if c.harvested {
            return AnyView(Text("已收")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green))
        }

        // 秒级刷新由系统统一调度（比自建 Timer 省资源，且 App 后台自动暂停）
        return AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            let overdue = c.date <= context.date
            if overdue {
                // 到期未收：最需要被看到的状态，给实心胶囊而不是 00:00
                Text("可收")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
            } else {
                Text(remainText(c.date, now: context.date))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        })
    }

    private func accessibilityText(_ c: HarvestCycle) -> String {
        let base = fmt(c.date)
        if c.harvested { return "\(base) 已收" }
        let left = max(0, Int(c.date.timeIntervalSinceNow))
        let h = left / 3600, m = (left % 3600) / 60, s = left % 60
        return h > 0
            ? "\(base) 还剩 \(h) 小时 \(m) 分"
            : "\(base) 还剩 \(m) 分 \(s) 秒"
    }

    /// 编辑单条记录：改名称/备注，并管理各茬收菜时间（反复续期，每茬可单独编辑）
struct EditRecordSheet: View {
    let record: CropRecord
    let onSave: (CropRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    /// 新增一茬时的录入方式。「在上一茬之后」以现有最晚一茬为基准，
    /// 「每隔两天再续一次」只需填间隔，不用每次心算绝对日期。
    enum NewMode: String, CaseIterable, Identifiable {
        case afterLast = "在上一茬之后"
        case absoluteDate = "按指定收菜时间"
        var id: String { rawValue }
    }

    @State private var nameText: String
    @State private var noteText: String
    /// 各茬收菜（可在列表里逐行编辑时间、标记已收、删除）
    @State private var harvests: [HarvestCycle]

    // 新增一茬的表单
    @State private var newMode: NewMode = .afterLast
    @State private var newHoursText: String = "0"
    @State private var newMinutesText: String = "30"
    @State private var newDate: Date = Date()

    init(record: CropRecord, onSave: @escaping (CropRecord) -> Void) {
        self.record = record
        self.onSave = onSave
        _nameText = State(initialValue: record.name)
        _noteText = State(initialValue: record.note ?? "")
        // 按时间排序后作为编辑起点；老数据已在解码阶段迁移成 [HarvestCycle]
        _harvests = State(initialValue: record.harvests.sorted { $0.date < $1.date })
        _newDate = State(initialValue: record.harvests.last?.date ?? record.plantedAt)
    }

    private var newTotalMinutes: Int {
        let h = max(0, Int(newHoursText.trimmingCharacters(in: .whitespaces)) ?? 0)
        let m = max(0, Int(newMinutesText.trimmingCharacters(in: .whitespaces)) ?? 0)
        return h * 60 + m
    }

    /// 「在上一茬之后」的基准：现有最晚一茬；一茬都没有就用种下时间
    private var lastHarvestDate: Date {
        harvests.map(\.date).max() ?? record.plantedAt
    }

    private var previewNewDate: Date {
        newMode == .afterLast
            ? lastHarvestDate.addingTimeInterval(TimeInterval(newTotalMinutes * 60))
            : newDate
    }

    /// 至少要留一茬，否则这条记录没有意义
    private var valid: Bool { !harvests.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 头部：蔬菜标识 + 续期概况
                    HStack(spacing: 12) {
                        Circle()
                            .fill(LinearGradient(colors: [Color(hex: record.colorHex),
                                                          Color(hex: record.colorHex).opacity(0.7)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 38, height: 38)
                            .overlay(Text(String(record.name.prefix(1)))
                                .foregroundColor(.white).font(.headline))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name).font(.headline)
                            Text(harvestSummary)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 18) {
                            LabeledField("蔬菜名称") {
                                TextField("例如 胡萝卜", text: $nameText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 220)
                            }

                            LabeledField("备注说明") {
                                // TextEditor 才支持真正多行输入（TextField axis:.vertical 在 macOS 上不会换行）
                                TextEditor(text: $noteText)
                                    .font(.body)
                                    .scrollContentBackground(.hidden)
                                    .padding(6)
                                    .frame(width: 320, height: 64)
                                    .background(Color.primary.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                            }
                        }
                    }

                    cyclesSection
                }
                .padding(24)
            }
            // 高度下限给足：名称/备注 + 若干行收菜时间 + 续期表单全部要能一次看全，
            // 之前 560 偏低，最后一行会被截断（ScrollView 能滚但用户容易漏看）
            .frame(minWidth: 620, minHeight: 640, alignment: .topLeading)
            .navigationTitle("编辑记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!valid)
                }
            }
        }
    }

    /// 「共 N 茬 · 已收 M · 下次 …」
    private var harvestSummary: String {
        let n = Date()
        let done = harvests.filter { $0.harvested }.count
        let upcoming = harvests.filter { !$0.harvested && $0.date > n }
            .map(\.date).min()
        var s = "共 \(harvests.count) 茬 · 已收 \(done)"
        if let u = upcoming { s += " · 下次 \(fmt(u))" }
        else if done < harvests.count { s += " · 有 \(harvests.count - done) 茬待收" }
        return s
    }

    // MARK: - 各茬收菜时间

    private var cyclesSection: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Label("收菜时间（每茬可单独编辑）", systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    ForEach($harvests) { $h in
                        cycleRow($h)
                    }
                }

                Divider()

                // 新增一茬
                VStack(alignment: .leading, spacing: 10) {
                    Text("再续一茬")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $newMode) {
                        ForEach(NewMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)

                    HStack(spacing: 8) {
                        if newMode == .afterLast {
                            TextField("0", text: $newHoursText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 66)
                                .multilineTextAlignment(.trailing)
                            Text("小时").font(.subheadline).foregroundStyle(.secondary)
                            TextField("30", text: $newMinutesText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 66)
                                .multilineTextAlignment(.trailing)
                            Text("分钟").font(.subheadline).foregroundStyle(.secondary)
                            Text("→ \(fmt(previewNewDate))")
                                .font(.caption).foregroundStyle(.tint).monospacedDigit()
                        } else {
                            DatePicker("", selection: $newDate,
                                      displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                        }
                        Spacer(minLength: 0)
                        Button {
                            addCycle()
                        } label: {
                            Label("添加", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func cycleRow(_ h: Binding<HarvestCycle>) -> some View {
        let overdue = !h.wrappedValue.harvested && h.wrappedValue.date <= Date()
        return HStack(spacing: 10) {
            // 已收勾选：续期时收了这一茬再续下一茬
            Button {
                h.wrappedValue.harvested.toggle()
            } label: {
                Image(systemName: h.wrappedValue.harvested
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(h.wrappedValue.harvested ? Color.green
                                     : (overdue ? Color.orange : Color.secondary))
            }
            .buttonStyle(.borderless)
            .help(h.wrappedValue.harvested ? "取消「已收」标记" : "标记这一茬已收")

            // 每茬独立的时间选择器（可直接改日期和时分）
            DatePicker("",
                      selection: h.date,
                      displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .fixedSize()

            // 每行的倒计时同样要实时刷新。编辑弹窗里行数很少（通常1~5 茬），
            // 开销可忽略，直接用 TimelineView 包这一个 Text。
            if h.wrappedValue.harvested {
                Text("已收")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let over = h.wrappedValue.date <= ctx.date
                    if over {
                        Text("可收")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                    } else {
                        Text(remainText(h.wrappedValue.date, now: ctx.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            // 调整时间：弹出输入面板填「增加多少小时/分钟」，默认 1 小时 0 分
            Button {
                openAdjust(for: h.wrappedValue.id)
            } label: {
                Label("调整", systemImage: "clock.arrow.circlepath")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(
                get: { adjustingID == h.wrappedValue.id },
                set: { if !$0 { closeAdjust() } }
            ), arrowEdge: .bottom) {
                adjustPanel(for: h.wrappedValue.id)
            }
            .help("调整这一茬的时间")

            Button {
                harvests.removeAll { $0.id == h.wrappedValue.id }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.red)
            .help("删除这一茬")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 调整单茬时间

    /// 正在调整的茬 id（nil = 面板关闭）。用 id 而非下标定位，
    /// 否则删行/排序后下标会错位，改到别的茬上。
    @State private var adjustingID: String?
    @State private var adjustHoursText: String = "1"
    @State private var adjustMinutesText: String = "0"
    /// 负数表示往前拨，正数往后
    @State private var adjustDirection: AdjustDirection = .later

    enum AdjustDirection: String, CaseIterable, Identifiable {
        case later = "往后延"
        case earlier = "往前提"
        var id: String { rawValue }
    }

    private func openAdjust(for id: String) {
        // 每次打开都重置为默认 1 小时 0 分，符合「改一次就是加一小时」的直觉
        adjustingID = id
        adjustHoursText = "1"
        adjustMinutesText = "0"
        adjustDirection = .later
    }

    private func closeAdjust() {
        adjustingID = nil
    }

    /// 面板里的调整量（分钟），非法输入按 0 处理
    private var adjustTotalMinutes: Int {
        let h = max(0, Int(adjustHoursText.trimmingCharacters(in: .whitespaces)) ?? 0)
        let m = max(0, Int(adjustMinutesText.trimmingCharacters(in: .whitespaces)) ?? 0)
        let total = h * 60 + m
        return adjustDirection == .later ? total : -total
    }

    @ViewBuilder
    private func adjustPanel(for id: String) -> some View {
        let cur = harvests.first { $0.id == id }
        VStack(alignment: .leading, spacing: 12) {
            Text("调整收菜时间")
                .font(.headline)
            if let c = cur {
                Text("当前 \(fmt(c.date))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("", selection: $adjustDirection) {
                ForEach(AdjustDirection.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                TextField("1", text: $adjustHoursText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("小时").font(.subheadline).foregroundStyle(.secondary)
                TextField("0", text: $adjustMinutesText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("分钟").font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if adjustTotalMinutes != 0, let c = cur {
                let newDate = c.date.addingTimeInterval(TimeInterval(adjustTotalMinutes * 60))
                Text("→ \(fmt(newDate))")
                    .font(.caption).foregroundStyle(.tint).monospacedDigit()
            }

            HStack {
                Button("取消") { closeAdjust() }
                Spacer()
                Button("确定") {
                    applyAdjust(for: id)
                    closeAdjust()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(adjustTotalMinutes == 0)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func applyAdjust(for id: String) {
        guard let i = harvests.firstIndex(where: { $0.id == id }) else { return }
        harvests[i].date = harvests[i].date
            .addingTimeInterval(TimeInterval(adjustTotalMinutes * 60))
        // 调整后时间顺序可能变了，保持列表始终按时间先后展示
        harvests.sort { $0.date < $1.date }
    }

    private func addCycle() {
        let d = previewNewDate
        harvests.append(HarvestCycle(date: d))
        // 用户可能往回加时间，列表始终按时间先后展示
        harvests.sort { $0.date < $1.date }
        // 下一轮「在上一茬之后」以刚加的为准，连续续期不用重算
        newDate = d
    }

    private func save() {
        let trimmedNote = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = harvests.sorted { $0.date < $1.date }
        let first = sorted.first?.date ?? record.plantedAt
        let updated = CropRecord(
            id: record.id,
            name: nameText.trimmingCharacters(in: .whitespaces).isEmpty
                ? record.name : nameText.trimmingCharacters(in: .whitespaces),
            colorHex: record.colorHex,
            // minutes 保持「首茬相对种下时间的成熟时长」，续期不影响这个基线
            minutes: max(0, Int(first.timeIntervalSince(record.plantedAt) / 60)),
            plantedAt: record.plantedAt,
            harvests: sorted,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
        onSave(updated)
        dismiss()
    }
}

// （旧 AddCropSheet 已移除，新实现见 CropManagerSheet.swift）


#Preview {
    ContentView()
}

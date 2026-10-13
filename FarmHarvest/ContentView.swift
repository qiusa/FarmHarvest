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
    let s = max(0, Int(r.harvestAt.timeIntervalSinceNow))
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
    static func reschedule(_ records: [CropRecord]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()
        for r in records {
            let fire = r.harvestAt.addingTimeInterval(-60) // 提前 1 分钟
            guard fire > now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(r.name) 即将可收菜"
            content.body = "还有 1 分钟 · 收菜时间 \(fmt(r.harvestAt))"
            content.sound = .default
            content.badge = 1
            let secs = fire.timeIntervalSince(now)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
            let req = UNNotificationRequest(identifier: "harvest-\(r.id)", content: content, trigger: trigger)
            center.add(req)
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

    private var selectedPreset: CropPreset? {
        CropStore.presets.first { $0.id == selectedPresetID }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 1. 选择蔬菜（玻璃卡片横滑）
                    sectionHeader("选择蔬菜")
                    ScrollView(.horizontal, showsIndicators: false) {
                        GlassEffectContainer(spacing: 14) {
                            HStack(spacing: 14) {
                                ForEach(CropStore.presets) { preset in
                                    VegetableChip(preset: preset, selected: selectedPresetID == preset.id) {
                                        selectedPresetID = preset.id
                                        hoursText = "\(preset.minutes / 60)"
                                        minutesText = "\(preset.minutes % 60)"
                                        harvestDate = Date().addingTimeInterval(TimeInterval(preset.minutes * 60))
                                    }
                                }
                                Button { showAddCrop = true } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: "plus")
                                            .font(.title).foregroundStyle(.tint)
                                        Text("自定义").font(.caption)
                                    }
                                    .frame(width: 96, height: 96)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                            }
                            .padding(.vertical, 6)
                        }
                        .padding(.horizontal, 4)
                    }

                    // 2. 种植参数（玻璃面板）
                    sectionHeader("种植参数")
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 18) {
                            Picker("录入方式", selection: $inputMode) {
                                ForEach(InputMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            LabeledField("成熟时长") {
                                HStack(spacing: 8) {
                                    TextField("0", text: $hoursText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 70)
                                        .multilineTextAlignment(.trailing)
                                    Text("小时").font(.subheadline).foregroundStyle(.secondary)
                                    TextField("30", text: $minutesText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 70)
                                        .multilineTextAlignment(.trailing)
                                    Text("分钟").font(.subheadline).foregroundStyle(.secondary)
                                    if totalMinutes > 0 {
                                        Text("共 \(formatDurationText(totalMinutes))")
                                            .font(.caption).foregroundStyle(.secondary)
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
                                TextField("可选，例如：阳台第二盆", text: $noteText, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(1...3)
                                    .frame(width: 300)
                            }

                            Button { addRecord() } label: {
                                Label("种下并记录", systemImage: "leaf.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!canAdd)

                            // 存储降级时明确告知用户，而不是让写入静默失败
                            if saveFailed {
                                Label("保存失败：无法写入磁盘，请检查磁盘权限后重试", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else if !CropStore.isSharedContainerAvailable {
                                Label("桌面组件暂不同步：当前签名无法访问共享容器，记录仅保存在本机", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }

                            // 存储自检详情：默认收起，点标题展开（把「为什么存不进去」摊开给用户）
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
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }

                    // 3. 收菜记录（玻璃卡片列表）
                    sectionHeader("收菜记录（\(records.count)）")
                    if records.isEmpty {
                        Text("还没有记录，去上方种下第一棵菜吧～")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    } else {
                        GlassEffectContainer(spacing: 12) {
                            VStack(spacing: 12) {
                                ForEach(records) { r in
                                    RecordRow(r: r, onEdit: { editTarget = r }, onDelete: { delete(r) })
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(24)
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
                if minutesText.isEmpty, let m = CropStore.presets.first?.minutes {
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
            .sheet(isPresented: $showAddCrop) {
                AddCropSheet(onAdded: { c in
                    selectedPresetID = c.id
                    hoursText = "\(c.minutes / 60)"
                    minutesText = "\(c.minutes % 60)"
                    showAddCrop = false
                })
            }
        }
        .frame(minWidth: 600, minHeight: 680)
    }

    private func formatPreviewText(_ s: String) -> String { s }

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

/// 收菜记录行（玻璃卡片）
struct RecordRow: View {
    let r: CropRecord
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: r.colorHex),
                                              Color(hex: r.colorHex).opacity(0.7)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 40, height: 40)
                .overlay(Text(String(r.name.prefix(1)))
                    .foregroundColor(.white).font(.headline))
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name).font(.headline)
                HStack(spacing: 5) {
                    Text("收菜").font(.caption2).foregroundStyle(.secondary)
                    Text(fmt(r.harvestAt))
                        .font(.subheadline).bold()
                        .foregroundColor(r.harvestAt <= Date() ? .orange : .primary)
                }
                if let note = r.note, !note.isEmpty {
                    Label(note, systemImage: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if r.harvestAt <= Date() {
                Text("可收获").foregroundColor(.green).font(.subheadline.bold())
            } else {
                Text(remainText(r)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            Button("编辑", action: onEdit).controlSize(.small).buttonStyle(.borderless)
            Button("删除", action: onDelete).controlSize(.small).buttonStyle(.borderless).tint(.red)
        }
        .padding(14)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

/// 编辑单条记录：玻璃面板布局，可改名称、在当前收菜时间上新增分钟，或指定绝对收菜时间
struct EditRecordSheet: View {
    let record: CropRecord
    let onSave: (CropRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    enum EditMode: String, CaseIterable, Identifiable {
        case add = "在当前收菜时间上新增"
        case absolute = "按指定收菜时间"
        var id: String { rawValue }
    }

    @State private var mode: EditMode
    @State private var nameText: String
    @State private var noteText: String
    @State private var hoursText: String
    @State private var minutesText: String
    @State private var harvestDate: Date

    init(record: CropRecord, onSave: @escaping (CropRecord) -> Void) {
        self.record = record
        self.onSave = onSave
        _mode = State(initialValue: .add)
        _nameText = State(initialValue: record.name)
        _noteText = State(initialValue: record.note ?? "")
        // 默认 0 小时 0 分钟（与主界面「成熟时长」一致的交互）
        _hoursText = State(initialValue: "0")
        _minutesText = State(initialValue: "0")
        _harvestDate = State(initialValue: record.harvestAt)
    }

    /// 新增的总分钟数（小时 × 60 + 分钟），非法输入按 0 处理
    private var addTotalMinutes: Int {
        let h = max(0, Int(hoursText.trimmingCharacters(in: .whitespaces)) ?? 0)
        let m = max(0, Int(minutesText.trimmingCharacters(in: .whitespaces)) ?? 0)
        return h * 60 + m
    }

    private var valid: Bool {
        if mode == .add { return addTotalMinutes > 0 }
        return true
    }

    private var previewNewHarvest: String? {
        guard addTotalMinutes > 0 else { return nil }
        return fmt(record.harvestAt.addingTimeInterval(TimeInterval(addTotalMinutes * 60)))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                // 头部：蔬菜标识 + 当前收菜时间
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
                        Text("当前收菜时间  \(fmt(record.harvestAt))")
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
                            TextField("可选，例如：阳台第二盆", text: $noteText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...3)
                                .frame(width: 300)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("时间方式")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Picker("时间方式", selection: $mode) {
                                ForEach(EditMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        if mode == .add {
                            LabeledField("新增时长") {
                                HStack(spacing: 8) {
                                    TextField("0", text: $hoursText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 70)
                                        .multilineTextAlignment(.trailing)
                                    Text("小时").font(.subheadline).foregroundStyle(.secondary)
                                    TextField("0", text: $minutesText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 70)
                                        .multilineTextAlignment(.trailing)
                                    Text("分钟").font(.subheadline).foregroundStyle(.secondary)
                                    if addTotalMinutes > 0 {
                                        Text("共 \(formatDurationText(addTotalMinutes))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if let p = previewNewHarvest {
                                Label("收菜时间将变更为 \(p)", systemImage: "arrow.forward")
                                    .font(.caption).foregroundStyle(.tint)
                                    .padding(.leading, 122)
                            }
                        } else {
                            LabeledField("收菜时间") {
                                DatePicker("", selection: $harvestDate,
                                          displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(minWidth: 500, minHeight: 420, alignment: .topLeading)
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

    private func save() {
        let harvestAt: Date
        if mode == .add, addTotalMinutes > 0 {
            harvestAt = record.harvestAt.addingTimeInterval(TimeInterval(addTotalMinutes * 60))
        } else {
            harvestAt = harvestDate
        }
        let trimmedNote = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = CropRecord(
            id: record.id,
            name: nameText.trimmingCharacters(in: .whitespaces).isEmpty
                ? record.name : nameText.trimmingCharacters(in: .whitespaces),
            colorHex: record.colorHex,
            minutes: max(0, Int(harvestAt.timeIntervalSince(record.plantedAt) / 60)),
            plantedAt: record.plantedAt,
            harvestAt: harvestAt,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
        onSave(updated)
        dismiss()
    }
}

/// 自定义蔬菜：玻璃面板布局，输入名字 + 选颜色；列出已自定义蔬菜可点按删除
struct AddCropSheet: View {
    let onAdded: (CropPreset) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var colorHex: String = CropStore.cropPalette[0]
    @State private var custom: [CropPreset] = CropStore.customCrops()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                GlassPanel {
                    VStack(alignment: .leading, spacing: 18) {
                        LabeledField("蔬菜名字") {
                            TextField("例如 菠菜", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("颜色")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .padding(.leading, 122)
                            HStack(spacing: 10) {
                                ForEach(CropStore.cropPalette, id: \.self) { hex in
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 28, height: 28)
                                        .overlay(Circle().stroke(colorHex == hex ? Color.accentColor : .clear, lineWidth: 3))
                                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                                        .onTapGesture { colorHex = hex }
                                }
                            }
                            .padding(.leading, 122)
                        }

                        Button { add() } label: {
                            Text("添加").font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if !custom.isEmpty {
                    Text("已自定义（点按删除）")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    GlassEffectContainer(spacing: 10) {
                        ForEach(custom) { c in
                            HStack(spacing: 12) {
                                Circle().fill(Color(hex: c.colorHex)).frame(width: 24, height: 24)
                                Text(c.name).font(.subheadline)
                                Spacer()
                                Image(systemName: "trash").foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                CropStore.removeCustomCrop(id: c.id)
                                custom = CropStore.customCrops()
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(minWidth: 500, minHeight: 380, alignment: .topLeading)
            .navigationTitle("自定义蔬菜")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func add() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let c = CropStore.addCustomCrop(name: n, colorHex: colorHex)
        custom = CropStore.customCrops()
        name = ""
        onAdded(c)
    }
}

#Preview {
    ContentView()
}

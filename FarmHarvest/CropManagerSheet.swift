import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 蔬菜管理弹窗：新增自定义蔬菜、管理（内置 + 自定义均可删除 / 恢复）、数据导入导出
struct CropManagerSheet: View {
    let onAdded: (CropPreset) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case add = "新增"
        case manage = "管理"
        case data = "数据"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .add
    @State private var presets: [CropPreset] = CropStore.presets
    @State private var hidden: [CropPreset] = CropStore.hiddenBuiltinCrops()
    @State private var builtinIDs: Set<String> = Set(CropStore.builtinCrops.map(\.id))

    // 新增表单
    @State private var name: String = ""
    @State private var colorHex: String = CropStore.cropPalette[0]
    @State private var hoursText: String = "0"
    @State private var minutesText: String = "30"

    // 删除确认 / 编辑目标
    @State private var pendingDelete: CropPreset?
    @State private var editing: CropPreset?

    // 提示 / 错误
    @State private var toast: String?
    @State private var toastIsError: Bool = false
    @State private var importMode: CropStore.ImportMode = .merge

    private var formMinutes: Int {
        let h = max(0, Int(hoursText.trimmingCharacters(in: .whitespaces)) ?? 0)
        let m = max(0, Int(minutesText.trimmingCharacters(in: .whitespaces)) ?? 0)
        return max(1, h * 60 + m)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var customCount: Int {
        presets.filter { !builtinIDs.contains($0.id) }.count
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Picker("视图", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: tab) { _, new in
                    if new != .add { editing = nil }
                }

                switch tab {
                case .add:    addTab
                case .manage: manageTab
                case .data:   dataTab
                }

                if let toast {
                    Label(toast, systemImage: toastIsError
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(toastIsError ? .red : .green)
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(minWidth: 560, minHeight: 540, alignment: .topLeading)
            .navigationTitle("蔬菜管理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .alert("删除「\(pendingDelete?.name ?? "")」？",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let p = pendingDelete { remove(p) }
                pendingDelete = nil
            }
        } message: {
            Text(builtinIDs.contains(pendingDelete?.id ?? "")
                 ? "内置蔬菜不会真正移除，可随时在「管理 - 已删除的内置」中恢复。"
                 : "该蔬菜将从列表中移除。")
        }
    }

    // MARK: - 新增

    private var addTab: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 18) {
                LabeledField("蔬菜名字") {
                    TextField("例如 菠菜", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
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
                                .overlay(Circle()
                                    .stroke(colorHex == hex ? Color.accentColor : .clear,
                                            lineWidth: 3))
                                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                                .contentShape(Circle())
                                .onTapGesture { colorHex = hex }
                        }
                    }
                    .padding(.leading, 122)
                }

                LabeledField("默认成熟") {
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
                        Text("共 \(formatDurationText(formMinutes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Button { editing != nil ? saveEdit() : add() } label: {
                    Label(editing != nil ? "保存修改" : "添加",
                          systemImage: editing != nil ? "checkmark" : "plus")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(trimmedName.isEmpty)

                if editing != nil {
                    Button("取消编辑") {
                        editing = nil
                        name = ""
                        hoursText = "0"
                        minutesText = "30"
                        colorHex = CropStore.cropPalette[0]
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
    }

    // MARK: - 管理

    private var manageTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("当前列表（\(presets.count)）",
                             hint: "点铅笔改名称与时长，点 trash 删除（内置也可删）")
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 8) {
                        ForEach(presets) { cropRow($0) }
                    }
                }

                if !hidden.isEmpty {
                    sectionTitle("已删除的内置（\(hidden.count)）", hint: "点回旋箭头恢复")
                    GlassEffectContainer(spacing: 8) {
                        VStack(spacing: 8) {
                            ForEach(hidden) { p in
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(Color(hex: p.colorHex).opacity(0.4))
                                        .frame(width: 26, height: 26)
                                        .overlay(Text(String(p.name.prefix(1)))
                                            .foregroundStyle(.secondary).font(.caption.bold()))
                                    Text(p.name).font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("默认 \(formatDurationText(p.minutes))")
                                        .font(.caption).foregroundStyle(.tertiary)
                                    Button {
                                        CropStore.restoreBuiltinCrop(id: p.id)
                                        refresh()
                                        show("已恢复「\(p.name)」")
                                    } label: {
                                        Image(systemName: "arrow.uturn.backward")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("恢复")
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                    Button {
                        CropStore.restoreAllBuiltinCrops()
                        refresh()
                        show("已恢复全部内置蔬菜")
                    } label: {
                        Label("一键恢复全部内置蔬菜", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func cropRow(_ p: CropPreset) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: p.colorHex),
                                              Color(hex: p.colorHex).opacity(0.7)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 26, height: 26)
                .overlay(Text(String(p.name.prefix(1)))
                    .foregroundColor(.white).font(.caption.bold()))
            Text(p.name).font(.subheadline)
            if !builtinIDs.contains(p.id) {
                Text("自定义").font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            Spacer()
            Text(formatDurationText(p.minutes))
                .font(.caption).foregroundStyle(.secondary)
            Button {
                editing = p
                name = p.name
                colorHex = p.colorHex
                hoursText = "\(p.minutes / 60)"
                minutesText = "\(p.minutes % 60)"
                tab = .add
                show("正在编辑「\(p.name)」，修改后点「保存修改」")
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑")
            Button {
                pendingDelete = p
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .tint(.red)
            .help("删除")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 数据

    private var dataTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GlassPanel {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledField("导出") {
                        Button { doExport() } label: {
                            Label("导出备份…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("导入")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Picker("", selection: $importMode) {
                            Text("合并").tag(CropStore.ImportMode.merge)
                            Text("替换").tag(CropStore.ImportMode.replace)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)

                        Text(importMode == .merge
                             ? "合并：同 id 记录被备份覆盖，新记录追加到列表末尾。"
                             : "替换：清空当前全部记录与蔬菜，完全采用备份内容。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button { doImport() } label: {
                            Label("导入备份…", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            GlassPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前数据")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("收菜记录 \(CropStore.load().count) 条 · 蔬菜 \(presets.count) 个（内置 \(presets.count - customCount) + 自定义 \(customCount)）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("存储位置：\(CropStore.storageRoot.path)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 辅助

    private func sectionTitle(_ t: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.subheadline.bold())
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    private func refresh() {
        presets = CropStore.presets
        hidden = CropStore.hiddenBuiltinCrops()
    }

    private func show(_ msg: String, isError: Bool = false) {
        toast = msg
        toastIsError = isError
    }

    private func add() {
        let c = CropStore.addCustomCrop(name: trimmedName,
                                        colorHex: colorHex,
                                        minutes: formMinutes)
        refresh()
        name = ""
        show("已添加「\(c.name)」")
        onAdded(c)
    }

    private func saveEdit() {
        guard let target = editing else { return }
        CropStore.updateCustomCrop(CropPreset(id: target.id,
                                              name: trimmedName,
                                              colorHex: colorHex,
                                              minutes: formMinutes))
        refresh()
        let done = target.name
        editing = nil
        name = ""
        show("已更新「\(done)」")
    }

    private func remove(_ p: CropPreset) {
        CropStore.removeCrop(id: p.id)
        refresh()
        show("已删除「\(p.name)」")
    }

    /// 取用于承载文件面板的宿主窗口。
    /// sheet 刚弹出时 keyWindow 可能短暂为 nil，逐个回退直到找到可挂载的窗口。
    private func hostWindow() -> NSWindow? {
        if let w = NSApp.keyWindow, w.isVisible { return w }
        if let w = NSApp.mainWindow, w.isVisible { return w }
        return NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    // 导入导出面板必须在**宿主窗口**上以子 sheet 形式呈现。
    // 若在 SwiftUI .sheet 里直接 runModal()，面板会被外层 sheet 挡住事件循环，
    // 表现为「点了没反应」。这里用 continuation 包装成 async 调用。
    private func runSavePanel() async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FarmHarvest-备份-\(Self.stamp()).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.message = "选择备份文件的保存位置"
        return await withCheckedContinuation { cont in
            guard let host = hostWindow() else {
                //拿不到宿主窗口时退回模态运行，宁可样式不统一也不要静默无反应
                cont.resume(returning: panel.runModal() == .OK ? panel.url : nil)
                return
            }
            panel.beginSheetModal(for: host) { resp in
                cont.resume(returning: resp == .OK ? panel.url : nil)
            }
        }
    }

    private func runOpenPanel() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要导入的备份文件"
        return await withCheckedContinuation { cont in
            guard let host = hostWindow() else {
                cont.resume(returning: panel.runModal() == .OK ? panel.url : nil)
                return
            }
            panel.beginSheetModal(for: host) { resp in
                cont.resume(returning: resp == .OK ? panel.url : nil)
            }
        }
    }

    private func doExport() {
        Task {
            // 等sheet 呈现动画结束再弹面板，否则可能被吞掉
            try? await Task.sleep(for: .milliseconds(350))
            guard let url = await runSavePanel() else { return }
            do {
                try CropStore.exportBackup(to: url)
                show("已导出到 \(url.lastPathComponent)")
            } catch {
                show("导出失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    private func doImport() {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard let url = await runOpenPanel() else { return }
            do {
                let s = try CropStore.importBackup(from: url, mode: importMode)
                refresh()
                show("已\(s.mode == .merge ? "合并" : "替换")导入：记录 \(s.recordsAdded) 条 · 蔬菜 \(s.cropsAdded) 个")
            } catch {
                show("导入失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

/// 兼容主界面既有调用点
typealias AddCropSheet = CropManagerSheet
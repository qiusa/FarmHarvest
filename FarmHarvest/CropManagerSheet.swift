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
    /// 收菜记录条数缓存：导入后必须刷新，否则「当前数据」显示的是旧值
    @State private var recordCount: Int = CropStore.load().count

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

    // 文件面板开关：交给 SwiftUI 原生 fileExporter / fileImporter 处理，
    // 不用手动 NSSavePanel + beginSheetModal（sheet 上再挂 sheet 会被 AppKit 静默丢弃）。
    @State private var showExporter: Bool = false
    @State private var showImporter: Bool = false
    /// 导出内容在点击按钮时就地生成，避免在 body 求值时反复读盘
    @State private var exportData: Data = Data()

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
        .fileExporter(isPresented: $showExporter,
                      document: BackupDocument(data: exportData),
                      contentType: .json,
                      defaultFilename: "FarmHarvest-备份-\(Self.stamp())") { result in
            switch result {
            case .success(let url):
                show("已导出到 \(url.lastPathComponent)")
            case .failure(let err):
                // 用户主动取消不算错误，不打扰
                if (err as NSError).code != NSUserCancelledError {
                    show("导出失败：\(err.localizedDescription)", isError: true)
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let before = CropStore.load()
                do {
                    let s = try CropStore.importBackup(from: url, mode: importMode)
                    refresh()
                    let after = CropStore.load()
                    // 合并模式下若备份与本地完全一致，用户会以为「导入没生效」——
                    // 这里明确说明是「内容本就相同」还是真的写入了新数据。
                    if s.mode == .merge, before == after {
                        show("已合并：内容与当前数据完全相同（新增 0 条 · 覆盖 \(s.recordsOverwritten) 条）")
                    } else {
                        show(s.text)
                    }
                } catch {
                    show("导入失败：\(error.localizedDescription)", isError: true)
                }
            case .failure(let err):
                if (err as NSError).code != NSUserCancelledError {
                    show("选择文件失败：\(err.localizedDescription)", isError: true)
                }
            }
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
                        Button { startExport() } label: {
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
                             ? "合并：同 id 的记录被备份覆盖，本地没有的记录追加到末尾。若备份就是本机导出的那份，内容会完全一致、界面看不出变化。"
                             : "替换：清空当前全部记录与蔬菜，完全采用备份内容。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button { showImporter = true } label: {
                            Label("导入备份…", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .help("从之前导出的 JSON 备份文件恢复")
                    }
                }
            }

            GlassPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前数据")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("收菜记录 \(recordCount) 条 · 蔬菜 \(presets.count) 个（内置 \(presets.count - customCount) + 自定义 \(customCount)）")
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
        recordCount = CropStore.load().count
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

    /// 生成备份内容后就绪，再让 SwiftUI 弹出原生保存面板。
    /// 先取数据再翻开关，避免 body 求值期间读盘。
    private func startExport() {
        do {
            exportData = try CropStore.exportBackupJSON()
            showExporter = true
        } catch {
            show("导出失败：\(error.localizedDescription)", isError: true)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

/// `.fileExporter` 需要的文档包装：内容就是 CropStore 产出的备份 JSON
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 兼容主界面既有调用点
typealias AddCropSheet = CropManagerSheet
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 事项模板管理弹窗：新增自定义模板、管理（内置 + 自定义均可删除 / 恢复）、数据导入导出
struct CropManagerSheet: View {
    let onAdded: (CropPreset) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case add = "新增"
        case manage = "管理"
        case data = "数据"
        var id: String { rawValue }
    }

    @Binding private var tab: Tab
    @State private var presets: [CropPreset] = CropStore.presets
    @State private var hidden: [CropPreset] = CropStore.hiddenBuiltinCrops()
    @State private var builtinIDs: Set<String> = Set(CropStore.builtinCrops.map(\.id))
    /// 提醒记录条数缓存：导入后必须刷新，否则「当前数据」显示的是旧值
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
    @State private var channel: BackupChannel = .lan
    @State private var isImportingRemoteBackup = false
    @State private var isUploadingBackup = false
    @AppStorage(CropStore.lastSuccessfulUploadTimestampKey)
    private var lastSuccessfulUploadTimestamp: Double = 0
    @AppStorage(CropStore.lastSuccessfulBuildManagerUploadTimestampKey)
    private var lastSuccessfulBuildManagerUploadTimestamp: Double = 0
    @State private var showRemoteReplaceConfirmation = false
    @State private var pendingRemoteImportURL: URL?

    // 文件面板开关：交给 SwiftUI 原生 fileExporter / fileImporter 处理，
    // 不用手动 NSSavePanel + beginSheetModal（sheet 上再挂 sheet 会被 AppKit 静默丢弃）。
    @State private var showExporter: Bool = false
    @State private var showImporter: Bool = false
    /// 导出内容在点击按钮时就地生成，避免在 body 求值时反复读盘
    @State private var exportData: Data = Data()

    init(onAdded: @escaping (CropPreset) -> Void, tab: Binding<Tab>) {
        self.onAdded = onAdded
        _tab = tab
    }

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
            .navigationTitle("事项模板管理")
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
                 ? "内置模板不会真正移除，可随时在「管理 - 已删除的内置」中恢复。"
                 : "该模板将从列表中移除。")
        }
        .fileExporter(isPresented: $showExporter,
                      document: BackupDocument(data: exportData),
                      contentType: .json,
                      defaultFilename: CropStore.sourceBackupFileName) { result in
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
        .confirmationDialog(
            "用远程备份替换本机数据？",
            isPresented: $showRemoteReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("下载并替换", role: .destructive) {
                guard let url = pendingRemoteImportURL else { return }
                pendingRemoteImportURL = nil
                Task { await importRemoteBackup(from: url, mode: .replace) }
            }
            Button("取消", role: .cancel) {
                pendingRemoteImportURL = nil
            }
        } message: {
            Text("当前提醒记录、自定义模板和内置模板隐藏状态将被远程备份覆盖。")
        }
    }

    // MARK: - 新增

    private var addTab: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 18) {
                LabeledField("模板名称") {
                    TextField("例如：会议安排", text: $name)
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

                LabeledField("默认提醒间隔") {
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
                        show("已恢复全部内置模板")
                    } label: {
                        Label("一键恢复全部内置模板", systemImage: "arrow.uturn.backward.circle")
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassPanel {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("同步通道", selection: $channel) {
                            ForEach(BackupChannel.allCases) { c in
                                Label(c.rawValue, systemImage: c.icon).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text(channel.summary)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        backupAddressRow

                        Divider()

                        uploadRow

                        Divider()

                        remoteImportRow
                    }
                }

                GlassPanel {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("本地文件")
                            .font(.caption).foregroundStyle(.tertiary)

                        localExportRow

                        Divider()

                        localImportRow
                    }
                }

                GlassPanel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前数据")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("提醒记录 \(recordCount) 条 · 模板 \(presets.count) 个（内置 \(presets.count - customCount) + 自定义 \(customCount)）")
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

            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.hidden)
    }

    /// 当前通道的固定备份地址 + 复制按钮（两台设备互传时最需要的是这个地址）
    private var backupAddressRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("备份地址")
                .font(.caption).foregroundStyle(.secondary)
            Text(channel.backupURLString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(channel.backupURLString, forType: .string)
                show("已复制备份地址，可发给另一台设备导入。")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制地址")
            Spacer(minLength: 0)
        }
    }

    private var uploadRow: some View {
        let lastUpload = channel == .lan
            ? lastSuccessfulUploadTimestamp
            : lastSuccessfulBuildManagerUploadTimestamp
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.up.doc")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("上传")
                    .font(.subheadline.weight(.medium))
                Text("把本机当前数据推到备份地址，覆盖服务器上的那一份。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                Button {
                    Task { await uploadCurrentBackup(to: channel) }
                } label: {
                    Group {
                        if isUploadingBackup {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("上传当前备份")
                        }
                    }
                    .frame(width: 112)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isUploadingBackup)

                Text(lastUploadText(lastUpload))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var remoteImportRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text("下载并导入")
                    .font(.subheadline.weight(.medium))
                importModeControls
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                Button {
                    startRemoteImport(from: channel.backupURLString)
                } label: {
                    Group {
                        if isImportingRemoteBackup {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("下载并导入")
                        }
                    }
                    .frame(width: 112)
                }
                .buttonStyle(.bordered)
                .disabled(isImportingRemoteBackup)

                Text(channel.reachabilityHint)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var localExportRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("导出到文件")
                    .font(.subheadline.weight(.medium))
                Text("存成 JSON 自己归档，或拷到另一台电脑。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button { startExport() } label: {
                Text("导出备份…").frame(width: 112)
            }
            .buttonStyle(.bordered)
        }
    }

    private var localImportRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text("从文件导入")
                    .font(.subheadline.weight(.medium))
                importModeControls
            }
            Spacer(minLength: 12)
            Button { showImporter = true } label: {
                Text("导入备份…").frame(width: 112)
            }
            .buttonStyle(.bordered)
            .help("从之前导出的 JSON 备份文件恢复")
        }
    }

    /// 网络导入与本地文件导入共用同一个方式，两处都显示，避免设置在看不见的地方生效
    private var importModeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("导入方式", selection: $importMode) {
                Text("合并").tag(CropStore.ImportMode.merge)
                Text("替换").tag(CropStore.ImportMode.replace)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            Text(importMode == .merge
                 ? "合并：同 id 的记录被备份覆盖，本机独有的记录保留。"
                 : "替换：清空本机全部记录与模板，完全采用备份内容。")
                .font(.caption)
                .foregroundStyle(importMode == .replace ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lastUploadText(_ timestamp: Double) -> String {
        guard timestamp > 0 else { return "尚未上传" }
        return "最近上传 " + Date(timeIntervalSince1970: timestamp)
            .formatted(date: .numeric, time: .shortened)
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

    private func startRemoteImport(from urlString: String) {
        guard let url = URL(string: urlString),
              CropStore.isAllowedRemoteBackupURL(url) else {
            show("备份地址无效：\(urlString)", isError: true)
            return
        }

        if importMode == .replace {
            pendingRemoteImportURL = url
            showRemoteReplaceConfirmation = true
        } else {
            Task { await importRemoteBackup(from: url, mode: .merge) }
        }
    }

    @MainActor
    private func importRemoteBackup(from url: URL, mode: CropStore.ImportMode) async {
        isImportingRemoteBackup = true
        defer { isImportingRemoteBackup = false }
        let before = CropStore.load()

        do {
            let summary = try await CropStore.importBackup(fromRemoteURL: url, mode: mode)
            refresh()
            let after = CropStore.load()
            if mode == .merge, before == after {
                show("远程备份与本机记录一致（覆盖 \(summary.recordsOverwritten) 条）")
            } else {
                show(summary.text)
            }
        } catch {
            show("远程导入失败：\(error.localizedDescription)", isError: true)
        }
    }

    @MainActor
    private func uploadCurrentBackup(to channel: BackupChannel) async {
        isUploadingBackup = true
        defer { isUploadingBackup = false }

        do {
            let data = try CropStore.exportBackupJSON()
            let fileName: String
            switch channel {
            case .lan: fileName = try await SourceFileUploader.uploadBackup(data: data).fileName
            case .wan: fileName = try await BuildManagerBackupUploader.uploadBackup(data: data).fileName
            }
            let now = Date().timeIntervalSince1970
            if channel == .lan {
                lastSuccessfulUploadTimestamp = now
            } else {
                lastSuccessfulBuildManagerUploadTimestamp = now
            }
            show("已上传到\(channel.rawValue)：\(fileName)，备份地址已指向这份最新内容。")
        } catch {
            show("\(channel.rawValue)上传失败：\(error.localizedDescription)", isError: true)
        }
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

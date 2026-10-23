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
    @State private var isImportingRemoteBackup = false
    @State private var isUploadingBackup = false
    @State private var isUploadingBuildManagerBackup = false
    @State private var buildManagerUploadToken = BuildManagerUploadCredentialStore.load() ?? ""
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
                        VStack(alignment: .leading, spacing: 10) {
                            Text("上传到共享目录")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("上传文件名：\(CropStore.sourceBackupFileName)。固定导入地址：\(CropStore.sourceBackupURLString)。仅在可信局域网内使用。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("接口不会覆盖文件：若同名文件已存在，服务器会自动追加序号，固定导入地址仍指向原文件。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                Task { await uploadCurrentBackup() }
                            } label: {
                                if isUploadingBackup {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 140)
                                } else {
                                    Label("上传当前备份", systemImage: "arrow.up.doc")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isUploadingBackup)
                            Text(lastSuccessfulUploadTimestamp > 0
                                 ? "最近上传：\(Date(timeIntervalSince1970: lastSuccessfulUploadTimestamp).formatted(date: .numeric, time: .shortened))"
                                 : "最近上传：暂无")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("上传到构建管理服务器")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(BuildManagerBackupUploader.endpointString)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("服务器会为每次上传生成独立下载地址，不覆盖旧备份。令牌由管理员提供并保存在系统钥匙串中；若服务返回 503，需先由管理员配置服务端上传令牌。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            SecureField("服务器上传令牌", text: $buildManagerUploadToken)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isUploadingBuildManagerBackup)
                            Button {
                                Task { await uploadBackupToBuildManager() }
                            } label: {
                                if isUploadingBuildManagerBackup {
                                    ProgressView("正在上传…")
                                        .controlSize(.small)
                                } else {
                                    Label("上传当前备份到服务器", systemImage: "arrow.up.doc")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isUploadingBuildManagerBackup || buildManagerUploadToken.isEmpty)
                            Text(lastSuccessfulBuildManagerUploadTimestamp > 0
                                 ? "最近上传：\(Date(timeIntervalSince1970: lastSuccessfulBuildManagerUploadTimestamp).formatted(date: .numeric, time: .shortened))"
                                 : "最近上传：暂无")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Divider()

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
                                 : "替换：清空当前全部记录与模板，完全采用备份内容。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Button { showImporter = true } label: {
                                Label("导入备份…", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.bordered)
                            .help("从之前导出的 JSON 备份文件恢复")

                            Divider()
                                .padding(.vertical, 4)

                            Text("从远程地址导入")
                                .font(.subheadline)
                            Text("固定地址供 Mac 和 iPhone 导入；设备需在可访问共享目录的网络中。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(CropStore.defaultRemoteBackupURLString)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                startRemoteImport()
                            } label: {
                                if isImportingRemoteBackup {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 120)
                                } else {
                                    Label("从网址导入", systemImage: "arrow.down.doc")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isImportingRemoteBackup)
                        }
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

    private func startRemoteImport() {
        guard let url = URL(string: CropStore.defaultRemoteBackupURLString),
              CropStore.isAllowedRemoteBackupURL(url) else {
            show("请输入有效的 HTTPS 地址，或上传接口返回的局域网下载地址。", isError: true)
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
    private func uploadCurrentBackup() async {
        isUploadingBackup = true
        defer { isUploadingBackup = false }

        do {
            let data = try CropStore.exportBackupJSON()
            let result = try await SourceFileUploader.uploadBackup(data: data)
            lastSuccessfulUploadTimestamp = Date().timeIntervalSince1970
            if result.fileName == CropStore.sourceBackupFileName {
                show("上传成功：\(result.fileName)，可从固定地址导入。")
            } else {
                show("上传成功，但服务器因同名自动保存为 \(result.fileName)；固定地址仍指向旧文件。接口不支持覆盖，请联系管理员提供固定文件更新方式。", isError: true)
            }
        } catch {
            show("上传失败：\(error.localizedDescription)", isError: true)
        }
    }

    @MainActor
    private func uploadBackupToBuildManager() async {
        guard !buildManagerUploadToken.isEmpty else {
            show("请先输入管理员提供的服务器上传令牌。", isError: true)
            return
        }

        isUploadingBuildManagerBackup = true
        defer { isUploadingBuildManagerBackup = false }

        do {
            let data = try CropStore.exportBackupJSON()
            try BuildManagerUploadCredentialStore.save(buildManagerUploadToken)
            let result = try await BuildManagerBackupUploader.uploadBackup(
                data: data,
                token: buildManagerUploadToken
            )
            lastSuccessfulBuildManagerUploadTimestamp = Date().timeIntervalSince1970
            show("已上传：\(result.fileName)\n下载地址：\(result.downloadURL.absoluteString)")
        } catch {
            show("服务器备份上传失败：\(error.localizedDescription)", isError: true)
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

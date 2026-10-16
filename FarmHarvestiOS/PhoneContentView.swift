import SwiftUI
import UIKit
import UserNotifications

/// iPhone-first interface. The macOS app keeps its existing desktop layout.
struct PhoneContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var records = CropStore.load()
    @State private var presets = CropStore.presets
    @State private var selectedPresetID = CropStore.presets.first?.id ?? ""
    @State private var minutesText = "\(CropStore.presets.first?.minutes ?? 30)"
    @State private var note = ""
    @State private var showAddCrop = false
    @State private var newCropName = ""
    @State private var newCropMinutes = "30"
    @State private var pendingDelete: CropRecord?
    @State private var editingRecord: CropRecord?
    @State private var showClearConfirmation = false
    @State private var remoteImportMode: CropStore.ImportMode = .merge
    @State private var isImportingRemoteBackup = false
    @State private var isUploadingBackup = false
    @State private var showRemoteReplaceConfirmation = false
    @State private var pendingRemoteImportURL: URL?
    @State private var message: String?

    private var selectedPreset: CropPreset? {
        presets.first { $0.id == selectedPresetID }
    }

    private var parsedMinutes: Int? {
        guard let value = Int(minutesText.trimmingCharacters(in: .whitespaces)),
              value > 0 else { return nil }
        return value
    }

    var body: some View {
        TabView {
            NavigationStack {
                plantForm
                    .navigationTitle("种菜")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showAddCrop = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel("添加自定义蔬菜")
                        }
                    }
            }
            .tabItem {
                Label("种菜", systemImage: "leaf")
            }

            NavigationStack {
                recordsList
                    .navigationTitle("事项记录")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("清除已收获") {
                                showClearConfirmation = true
                            }
                            .disabled(clearableRecordCount == 0)
                        }
                    }
            }
            .tabItem {
                Label("记录", systemImage: "list.bullet")
            }

            NavigationStack {
                remoteImportForm
                    .navigationTitle("数据")
            }
            .tabItem {
                Label("数据", systemImage: "arrow.down.doc")
            }
        }
        .tint(.green)
        .task {
            PhoneCropNotifier.bootstrap()
            refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refresh()
            }
        }
        .sheet(isPresented: $showAddCrop) {
            addCropSheet
        }
        .sheet(item: $editingRecord, onDismiss: { editingRecord = nil }) { record in
            PhoneEditRecordSheet(record: record) { updated in
                CropStore.update(updated)
                refresh()
                editingRecord = nil
            }
        }
        .confirmationDialog(
            "删除「\(pendingDelete?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let pendingDelete else { return }
                CropStore.save(records.filter { $0.id != pendingDelete.id })
                self.pendingDelete = nil
                refresh()
            }
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .confirmationDialog(
            "清除已收获或已到收菜时间的记录？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                CropStore.save(records.filter {
                    $0.harvests.isEmpty || !$0.isFullyHarvested
                })
                refresh()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清除每一茬都已采收或已到收菜时间的记录；仍有未来采收时间的记录会保留。")
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
            Text("当前收菜记录、自定义蔬菜和内置蔬菜隐藏状态将被远程备份覆盖。")
        }
        .alert("提示", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var plantForm: some View {
        Form {
            Section("蔬菜") {
                if presets.isEmpty {
                    Text("还没有可选蔬菜，请先添加。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("选择蔬菜", selection: $selectedPresetID) {
                        ForEach(presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .onChange(of: selectedPresetID) { _, newID in
                        if let preset = presets.first(where: { $0.id == newID }) {
                            minutesText = "\(preset.minutes)"
                        }
                    }
                }
            }

            Section("成熟时间") {
                HStack {
                    TextField("分钟", text: $minutesText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                    Text("分钟")
                        .foregroundStyle(.secondary)
                }

                if let minutes = parsedMinutes {
                    Text("预计收菜：\(fmt(Date().addingTimeInterval(TimeInterval(minutes * 60))))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("请输入大于 0 的分钟数")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("备注（可选）") {
                TextField("例如：阳台东侧", text: $note, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section {
                Button {
                    addRecord()
                } label: {
                    Label("种下并开始倒计时", systemImage: "leaf.fill")
                        .frame(maxWidth: .infinity)
                }
                .font(.headline)
                .disabled(selectedPreset == nil || parsedMinutes == nil)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DismissKeyboardOnBackgroundTap())
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起键盘", action: dismissKeyboard)
            }
        }
    }

    private var recordsList: some View {
        List {
            Section {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    HStack(spacing: 8) {
                        recordStat("待收", value: countPending(at: context.date), tint: .orange)
                        recordStat("可收获", value: countReady(at: context.date), tint: .green)
                        recordStat("总计", value: records.count, tint: .accentColor)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
            }

            Section("收菜记录（\(records.count)）") {
                if records.isEmpty {
                    ContentUnavailableView(
                        "还没有收菜记录",
                        systemImage: "carrot",
                        description: Text("到「种菜」页面添加一条记录。")
                    )
                    .listRowBackground(Color.clear)
                } else {
                ForEach(records) { record in
                    PhoneRecordRow(
                        record: record,
                        onEdit: { editingRecord = record },
                        onToggleHarvest: { cycle in
                            CropStore.setHarvested(
                                recordID: record.id,
                                cycleID: cycle.id,
                                !cycle.harvested
                            )
                            refresh()
                        },
                        onRenew: {
                            let nextDate = Date().addingTimeInterval(
                                TimeInterval(max(1, record.minutes) * 60)
                            )
                            CropStore.renew(record, after: nextDate)
                            refresh()
                        }
                    )
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = record
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { refresh() }
    }

    private func recordStat(_ title: String, value: Int, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.bold())
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Match the Mac record summary: a record is ready to clear when every cycle
    /// has either been harvested or has reached its scheduled time.
    private func countReady(at now: Date) -> Int {
        records.filter { record in
            !record.harvests.isEmpty
                && record.harvests.allSatisfy { $0.harvested || $0.date <= now }
        }.count
    }

    private func countPending(at now: Date) -> Int {
        records.count - countReady(at: now)
    }

    private var clearableRecordCount: Int {
        records.filter { !$0.harvests.isEmpty && $0.isFullyHarvested }.count
    }

    private var deleteConfirmationMessage: String {
        guard let record = pendingDelete else { return "" }
        let count = record.harvests.count
        if count <= 1 {
            let date = record.harvests.first.map { fmt($0.date) } ?? "未设置"
            return "收菜时间 \(date)。此操作不可撤销。"
        }
        let harvested = record.harvests.filter(\.harvested).count
        let next = record.nextHarvest.map { fmt($0) } ?? "无"
        return "共 \(count) 茬，已采收 \(harvested) 茬。下次收菜：\(next)。此操作不可撤销。"
    }

    private var addCropSheet: some View {
        NavigationStack {
            Form {
                Section("自定义蔬菜") {
                    TextField("名称", text: $newCropName)
                    HStack {
                        TextField("成熟分钟数", text: $newCropMinutes)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                        Text("分钟").foregroundStyle(.secondary)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(DismissKeyboardOnBackgroundTap())
            .navigationTitle("添加蔬菜")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘", action: dismissKeyboard)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddCrop = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let name = newCropName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty,
                              let minutes = Int(newCropMinutes), minutes > 0 else {
                            message = "请填写蔬菜名称和大于 0 的成熟分钟数。"
                            return
                        }
                        let preset = CropStore.addCustomCrop(name: name, minutes: minutes)
                        refresh()
                        selectedPresetID = preset.id
                        minutesText = "\(preset.minutes)"
                        newCropName = ""
                        newCropMinutes = "30"
                        showAddCrop = false
                    }
                    .disabled(newCropName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var remoteImportForm: some View {
        Form {
            Section("上传备份到共享目录") {
                Text("上传文件名：\(CropStore.sourceBackupFileName)。固定导入地址：\(CropStore.sourceBackupURLString)。请仅在可信局域网内使用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("接口不覆盖已有文件；若同名文件存在，服务器会追加序号，固定地址仍指向原文件。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await uploadCurrentBackup() }
                } label: {
                    HStack {
                        Spacer()
                        if isUploadingBackup {
                            ProgressView("正在上传备份…")
                        } else {
                            Label("上传当前备份", systemImage: "arrow.up.doc")
                        }
                        Spacer()
                    }
                }
                .disabled(isUploadingBackup)
            }

            Section("远程备份地址") {
                Text(CropStore.defaultRemoteBackupURLString)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)

                Text("手机和电脑都可从共享目录下载地址或 HTTPS 地址导入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("导入方式") {
                Picker("方式", selection: $remoteImportMode) {
                    Text("合并").tag(CropStore.ImportMode.merge)
                    Text("替换").tag(CropStore.ImportMode.replace)
                }
                .pickerStyle(.segmented)

                Text(remoteImportMode == .merge
                     ? "同 ID 的记录和蔬菜会更新，本机没有的项目会追加；本机独有项目保留。"
                     : "完全采用远程备份，会覆盖本机记录、自定义蔬菜和隐藏的内置蔬菜。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    startRemoteImport()
                } label: {
                    HStack {
                        Spacer()
                        if isImportingRemoteBackup {
                            ProgressView("正在下载并导入…")
                        } else {
                            Label("获取并导入", systemImage: "arrow.down.doc")
                        }
                        Spacer()
                    }
                }
                .disabled(isImportingRemoteBackup)
            }

            Section {
                Text("上传会将当前备份保存为一个新文件，不会覆盖已有文件；手机上的修改不会自动同步。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DismissKeyboardOnBackgroundTap())
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起键盘", action: dismissKeyboard)
            }
        }
    }

    private func startRemoteImport() {
        guard let url = URL(string: CropStore.defaultRemoteBackupURLString),
              CropStore.isAllowedRemoteBackupURL(url) else {
            message = "请输入有效的 HTTPS 地址，或上传接口返回的局域网下载地址。"
            return
        }

        if remoteImportMode == .replace {
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
                message = "远程备份与本机记录一致（覆盖 \(summary.recordsOverwritten) 条）"
            } else {
                message = summary.text
            }
        } catch {
            message = "远程导入失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func uploadCurrentBackup() async {
        isUploadingBackup = true
        defer { isUploadingBackup = false }

        do {
            let data = try CropStore.exportBackupJSON()
            let result = try await SourceFileUploader.uploadBackup(data: data)
            if result.fileName == CropStore.sourceBackupFileName {
                message = "上传成功：\(result.fileName)，可从固定地址导入。"
            } else {
                message = "上传成功，但服务器因同名自动保存为 \(result.fileName)；固定地址仍指向旧文件。接口不支持覆盖，请联系管理员提供固定文件更新方式。"
            }
        } catch {
            message = "上传失败：\(error.localizedDescription)"
        }
    }

    private func addRecord() {
        guard let preset = selectedPreset, let minutes = parsedMinutes else { return }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousCount = records.count
        CropStore.add(preset: preset, minutes: minutes, note: trimmedNote.isEmpty ? nil : trimmedNote)
        refresh()
        note = ""
        message = records.count > previousCount ? "已种下「\(preset.name)」，收菜提醒已安排。" : "保存失败，请检查设备存储空间后重试。"
    }

    private func refresh() {
        records = CropStore.load()
        presets = CropStore.presets
        if !presets.contains(where: { $0.id == selectedPresetID }),
           let first = presets.first {
            selectedPresetID = first.id
            minutesText = "\(first.minutes)"
        }
        PhoneCropNotifier.reschedule(records)
    }
}

private func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

/// Lets a tap on unused form space dismiss the keyboard without blocking controls.
private struct DismissKeyboardOnBackgroundTap: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private var tapRecognizer: UITapGestureRecognizer?

        func attach(to view: UIView) {
            guard let window = view.window else { return }
            guard self.window !== window else { return }

            detach()
            let recognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(handleTap)
            )
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            self.window = window
            tapRecognizer = recognizer
        }

        func detach() {
            if let tapRecognizer {
                window?.removeGestureRecognizer(tapRecognizer)
            }
            tapRecognizer = nil
            window = nil
        }

        @objc private func handleTap() {
            dismissKeyboard()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var touchedView = touch.view
            while let view = touchedView {
                if view is UIControl || view is UITextView {
                    return false
                }
                touchedView = view.superview
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private struct PhoneRecordRow: View {
    let record: CropRecord
    let onEdit: () -> Void
    let onToggleHarvest: (HarvestCycle) -> Void
    let onRenew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(hex: record.colorHex))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Text(String(record.name.prefix(1)))
                            .font(.headline)
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name).font(.headline)
                }
                Spacer()
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("编辑 \(record.name)")
                Button(action: onRenew) {
                    Label("续种", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("续种 \(record.name)")
            }

            if let note = record.note, !note.isEmpty {
                NotePresetRecordNote(note: note)
                    .font(.caption)
            }

            ForEach(
                Array(record.harvests.sorted { $0.date < $1.date }.enumerated()),
                id: \.element.id
            ) { index, cycle in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("第 \(index + 1) 茬 · \(fmt(cycle.date))")
                            .font(.subheadline.weight(.semibold))
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(cycle.harvested
                                 ? "已采收"
                                 : (cycle.date <= context.date
                                    ? "可以收菜"
                                    : "还剩 \(remainText(cycle.date, now: context.date))"))
                                .font(.caption)
                                .foregroundStyle(
                                    cycle.harvested ? .green
                                        : (cycle.date <= context.date ? .orange : .secondary)
                                )
                                .monospacedDigit()
                        }
                    }
                    Spacer()
                    Button(cycle.harvested ? "撤销" : "已采收") {
                        onToggleHarvest(cycle)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(cycle.harvested ? .secondary : .green)
                }
                .padding(.leading, 44)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PhoneEditRecordSheet: View {
    let record: CropRecord
    let onSave: (CropRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var note: String
    @State private var harvests: [HarvestCycle]
    @State private var newMode: NewCycleMode = .fromNow
    @State private var hoursText = "1"
    @State private var minutesText = "0"
    @State private var newDate: Date
    @State private var pendingCycleDelete: HarvestCycle?
    @State private var cycleAdjustmentHours: [String: String] = [:]
    @State private var cycleAdjustmentMinutes: [String: String] = [:]

    private enum NewCycleMode: String, CaseIterable, Identifiable {
        case fromNow = "从现在起"
        case absoluteDate = "指定时间"

        var id: String { rawValue }
    }

    init(record: CropRecord, onSave: @escaping (CropRecord) -> Void) {
        self.record = record
        self.onSave = onSave
        _name = State(initialValue: record.name)
        _note = State(initialValue: record.note ?? "")
        _harvests = State(initialValue: record.harvests.sorted { $0.date < $1.date })
        _newDate = State(
            initialValue: Date().addingTimeInterval(TimeInterval(max(1, record.minutes) * 60))
        )
    }

    private var durationMinutes: Int? {
        guard let hours = Int(hoursText.trimmingCharacters(in: .whitespaces)),
              let minutes = Int(minutesText.trimmingCharacters(in: .whitespaces)),
              hours >= 0, minutes >= 0 else { return nil }
        let (hourMinutes, overflow1) = hours.multipliedReportingOverflow(by: 60)
        let (total, overflow2) = hourMinutes.addingReportingOverflow(minutes)
        guard !overflow1, !overflow2, total > 0 else { return nil }
        return total
    }

    private var previewDate: Date? {
        switch newMode {
        case .fromNow:
            guard let durationMinutes else { return nil }
            return Date().addingTimeInterval(TimeInterval(durationMinutes * 60))
        case .absoluteDate:
            return newDate
        }
    }

    private var canAddCycle: Bool {
        guard let previewDate else { return false }
        return previewDate > Date()
    }

    private var summary: String {
        let harvestedCount = harvests.filter(\.harvested).count
        let next = harvests
            .filter { !$0.harvested && $0.date > Date() }
            .map(\.date)
            .min()
        var text = "共 \(harvests.count) 茬 · 已采收 \(harvestedCount)"
        if let next {
            text += " · 下次 \(fmt(next))"
        } else if harvestedCount < harvests.count {
            text += " · 有 \(harvests.count - harvestedCount) 茬待处理"
        }
        return text
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("记录信息") {
                    TextField("蔬菜名称", text: $name)
                    TextField("备注说明", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    if harvests.isEmpty {
                        Text("至少保留一茬收菜时间，或先添加一茬再保存。")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    ForEach($harvests) { $cycle in
                        VStack(alignment: .leading, spacing: 8) {
                            DatePicker(
                                "收菜时间",
                                selection: $cycle.date,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            DisclosureGroup("从现在起调整") {
                                HStack(spacing: 8) {
                                    TextField(
                                        "1",
                                        text: cycleAdjustmentHoursBinding(for: cycle.id)
                                    )
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 70)
                                    Text("小时")
                                        .foregroundStyle(.secondary)
                                    TextField(
                                        "0",
                                        text: cycleAdjustmentMinutesBinding(for: cycle.id)
                                    )
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 70)
                                    Text("分钟")
                                        .foregroundStyle(.secondary)
                                }

                                if let preview = cycleAdjustmentPreview(for: cycle.id) {
                                    Text("从现在起 → \(fmt(preview))")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }

                                Button("按此时间设置") {
                                    applyCycleAdjustment(for: cycle.id)
                                }
                                .disabled(cycleAdjustmentDuration(for: cycle.id) == nil)
                            }
                            Toggle("已采收", isOn: $cycle.harvested)
                            HStack {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(cycle.harvested
                                         ? "已采收"
                                         : (cycle.date <= context.date
                                            ? "可以收菜"
                                            : "还剩 \(remainText(cycle.date, now: context.date))"))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(
                                            cycle.harvested ? .green
                                                : (cycle.date <= context.date ? .orange : .secondary)
                                        )
                                }
                                Spacer()
                                Button("删除这一茬", role: .destructive) {
                                    pendingCycleDelete = cycle
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("收菜时间（每茬可单独编辑）")
                } footer: {
                    Text(summary)
                }

                Section("再续一茬") {
                    Picker("续期方式", selection: $newMode) {
                        ForEach(NewCycleMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if newMode == .absoluteDate {
                        DatePicker(
                            "收菜时间",
                            selection: $newDate,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    } else {
                        HStack(spacing: 8) {
                            TextField("1", text: $hoursText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 70)
                            Text("小时")
                                .foregroundStyle(.secondary)
                            TextField("0", text: $minutesText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 70)
                            Text("分钟")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let previewDate {
                        Text(newMode == .fromNow
                             ? "从现在起 · \(fmt(previewDate))"
                             : "预计收菜：\(fmt(previewDate))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        addCycle()
                    } label: {
                        Label("添加这一茬", systemImage: "plus")
                    }
                    .disabled(!canAddCycle)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(DismissKeyboardOnBackgroundTap())
            .navigationTitle("编辑记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘", action: dismissKeyboard)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(harvests.isEmpty)
                }
            }
            .confirmationDialog(
                "删除这一茬？",
                isPresented: Binding(
                    get: { pendingCycleDelete != nil },
                    set: { if !$0 { pendingCycleDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    guard let id = pendingCycleDelete?.id else { return }
                    harvests.removeAll { $0.id == id }
                    pendingCycleDelete = nil
                }
                Button("取消", role: .cancel) {
                    pendingCycleDelete = nil
                }
            } message: {
                if let cycle = pendingCycleDelete {
                    let remaining = harvests.count - 1
                    Text(remaining == 0
                         ? "收菜时间 \(fmt(cycle.date))。这是唯一一茬，删除后需要重新添加才能保存。"
                         : "收菜时间 \(fmt(cycle.date))。删除后还剩 \(remaining) 茬。")
                }
            }
        }
        .presentationDetents([.large])
    }

    private func cycleAdjustmentHoursBinding(for id: String) -> Binding<String> {
        Binding(
            get: { cycleAdjustmentHours[id] ?? "1" },
            set: { cycleAdjustmentHours[id] = $0 }
        )
    }

    private func cycleAdjustmentMinutesBinding(for id: String) -> Binding<String> {
        Binding(
            get: { cycleAdjustmentMinutes[id] ?? "0" },
            set: { cycleAdjustmentMinutes[id] = $0 }
        )
    }

    private func cycleAdjustmentDuration(for id: String) -> Int? {
        guard let hours = Int((cycleAdjustmentHours[id] ?? "1").trimmingCharacters(in: .whitespaces)),
              let minutes = Int((cycleAdjustmentMinutes[id] ?? "0").trimmingCharacters(in: .whitespaces)),
              hours >= 0, minutes >= 0 else { return nil }
        let (hourMinutes, overflow1) = hours.multipliedReportingOverflow(by: 60)
        let (total, overflow2) = hourMinutes.addingReportingOverflow(minutes)
        guard !overflow1, !overflow2, total > 0 else { return nil }
        return total
    }

    private func cycleAdjustmentPreview(for id: String) -> Date? {
        guard let duration = cycleAdjustmentDuration(for: id) else { return nil }
        return Date().addingTimeInterval(TimeInterval(duration) * 60)
    }

    private func applyCycleAdjustment(for id: String) {
        guard let index = harvests.firstIndex(where: { $0.id == id }),
              let preview = cycleAdjustmentPreview(for: id) else { return }
        harvests[index].date = preview
        harvests.sort { $0.date < $1.date }
    }

    private func addCycle() {
        guard let previewDate, previewDate > Date() else { return }
        harvests.append(HarvestCycle(date: previewDate))
        harvests.sort { $0.date < $1.date }
        newDate = previewDate
    }

    private func save() {
        guard !harvests.isEmpty else { return }
        let sorted = harvests.sorted { $0.date < $1.date }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstDate = sorted[0].date
        let updated = CropRecord(
            id: record.id,
            name: trimmedName.isEmpty ? record.name : trimmedName,
            colorHex: record.colorHex,
            minutes: max(0, Int(firstDate.timeIntervalSince(record.plantedAt) / 60)),
            plantedAt: record.plantedAt,
            harvests: sorted,
            note: trimmedNote.isEmpty ? nil : trimmedNote
        )
        onSave(updated)
        dismiss()
    }
}

/// iOS-specific notification adapter. Records remain local to this device;
/// the macOS app has its own notification center and data container.
private final class PhoneCropNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let shared = PhoneCropNotifier()

    static func bootstrap() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            DispatchQueue.main.async {
                reschedule(CropStore.load())
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    static func reschedule(_ records: [CropRecord]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()

        for record in records {
            let allCycles = record.harvests.sorted { $0.date < $1.date }
            for cycle in allCycles where !cycle.harvested {
                let position = (allCycles.firstIndex { $0.id == cycle.id } ?? 0) + 1
                let suffix = allCycles.count > 1 ? "（第 \(position)/\(allCycles.count) 茬）" : ""
                let timestamp = Int(cycle.date.timeIntervalSince1970)

                if cycle.date > now {
                    add(
                        center,
                        id: "phone-at-\(record.id)-\(timestamp)",
                        title: "\(record.name) 可以收菜了\(suffix)",
                        body: "收菜时间 \(fmt(cycle.date))，快去看看",
                        date: cycle.date
                    )
                }

                let reminder = cycle.date.addingTimeInterval(-60)
                if reminder > now {
                    add(
                        center,
                        id: "phone-pre-\(record.id)-\(timestamp)",
                        title: "\(record.name) 即将可收菜\(suffix)",
                        body: "还有 1 分钟 · 收菜时间 \(fmt(cycle.date))",
                        date: reminder
                    )
                }
            }
        }
    }

    private static func add(
        _ center: UNUserNotificationCenter,
        id: String,
        title: String,
        body: String,
        date: Date
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

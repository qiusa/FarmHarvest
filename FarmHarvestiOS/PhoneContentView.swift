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
    @State private var showClearConfirmation = false
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
                    .navigationTitle("收菜记录")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("清除已完成") {
                                showClearConfirmation = true
                            }
                            .disabled(!records.contains(where: \.isFullyHarvested))
                        }
                    }
            }
            .tabItem {
                Label("记录", systemImage: "list.bullet")
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
            Text("此操作不可撤销。")
        }
        .confirmationDialog(
            "清除已完成的记录？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                CropStore.save(records.filter { !$0.isFullyHarvested })
                refresh()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会清除所有采收时间都已完成的记录。")
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
            if records.isEmpty {
                ContentUnavailableView(
                    "还没有收菜记录",
                    systemImage: "carrot",
                    description: Text("到「种菜」页面添加一条记录。")
                )
            } else {
                ForEach(records) { record in
                    PhoneRecordRow(
                        record: record,
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
        .listStyle(.insetGrouped)
        .refreshable { refresh() }
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
                    if let note = record.note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button(action: onRenew) {
                    Label("续种", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("续种 \(record.name)")
            }

            ForEach(record.harvests) { cycle in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(fmt(cycle.date))
                            .font(.subheadline.weight(.semibold))
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(cycle.harvested
                                 ? "已采收"
                                 : (cycle.date <= context.date
                                    ? "可以收菜"
                                    : "还剩 \(remainText(cycle.date, now: context.date))"))
                                .font(.caption)
                                .foregroundStyle(cycle.harvested ? .green : (cycle.date <= context.date ? .orange : .secondary))
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

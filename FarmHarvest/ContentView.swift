import SwiftUI
import AppKit
import UserNotifications
import os.log

/// 录入/编辑的时间模式
enum InputMode: String, CaseIterable, Identifiable {
    case minutes = "按成熟分钟数"
    case absolute = "按指定收菜时间"
    var id: String { rawValue }
}

/// 把总分钟数格式化为「x 小时 y 分钟」（整小时省略分钟部分）
func formatDurationText(_ total: Int) -> String {
    let h = total / 60
    let m = total % 60
    if h > 0 && m > 0 { return "\(h) 小时 \(m) 分钟" }
    if h > 0 { return "\(h) 小时" }
    return "\(m) 分钟"
}

/// 本地通知：到期前 1 分钟提醒（主 App 负责调度，Widget 不可发通知）
/// 本地通知调度。必须是 class：UNUserNotificationCenterDelegate 继承自 NSObjectProtocol，
/// enum / struct 无法遵循（报 "non-class type cannot conform to class protocol"）。
final class CropNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CropNotifier()

    /// App 启动时申请一次通知授权，并把自己注册为代理。
    /// 代理是必须的：不设 willPresent 的话，App 在前台时通知**不弹横幅**，
    /// 看起来就像「没发通知」——其实系统已经收到了。
    static func bootstrap() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, err in
            if let err {
                os_log("通知授权失败 %{public}@", log: .default, type: .error, "\(err)")
            }
            os_log("通知授权结果 %{public}@", log: .default, type: .info, "\(granted)")
            // 授权是异步的，必须等结果回来再排程；
            // 否则授权尚未完成时的 add() 会被丢弃。
            DispatchQueue.main.async { reschedule(CropStore.load()) }
        }
    }

    /// App 在前台也展示横幅 + 播放声音，否则前台时通知等于没发
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
        @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// 依据当前记录重排本地通知（每次记录变更都整表重排）。
    /// 每茬排两条：到点提醒 + 提前 1 分钟预告。
    /// identifier 必须带时间戳+类型区分 —— 否则同一 id 的多条请求会互相覆盖，
    /// 结果只有一条能发出来。
    static func reschedule(_ records: [CropRecord]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()
        for r in records {
            // 跳过已采收的茬：已经收完了还响通知就是噪音
            let pending = r.harvests.filter { !$0.harvested }.sorted { $0.date < $1.date }
            // 序位按「全部茬」算，而不是过滤后的，否则第一茬收了之后
            // 剩余各茬的「第 N 茬」编号会错位
            let allSorted = r.harvests.sorted { $0.date < $1.date }
            let total = allSorted.count
            for h in pending {
                let at = h.date
                let stamp = Int(at.timeIntervalSince1970)
                let pos = (allSorted.firstIndex { $0.id == h.id } ?? 0) + 1
                let nth = total > 1 ? "（第 \(pos)/\(total) 茬）" : ""

                // ① 到点提醒：这是用户最需要的那一条
                if at > now {
                    add(center,
                        id: "at-\(r.id)-\(stamp)",
                        title: "\(r.name) 可以收菜了\(nth)",
                        body: "收菜时间 \(fmt(at))，快去看看",
                        fire: at,
                        badge: 1)
                }

                // ② 提前 1 分钟预告，留出反应时间
                let pre = at.addingTimeInterval(-60)
                if pre > now {
                    add(center,
                        id: "pre-\(r.id)-\(stamp)",
                        title: "\(r.name) 即将可收菜\(nth)",
                        body: "还有 1 分钟 · 收菜时间 \(fmt(at))",
                        fire: pre,
                        badge: nil)
                }
            }
        }
    }

    private static func add(_ center: UNUserNotificationCenter,
                            id: String, title: String, body: String,
                            fire: Date, badge: Int?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let badge { content.badge = NSNumber(value: badge) }
        let secs = fire.timeIntervalSinceNow
        // UNTimeIntervalNotificationTrigger 要求 interval > 0，
        // 传0 或负数会直接抛异常，所以这里必须再兜一层。
        guard secs > 0.5 else { return }
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: secs, repeats: false)
        center.add(UNNotificationRequest(identifier: id,
                                         content: content, trigger: trigger))
        { err in
            if let err {
                os_log("通知排程失败 %{public}@ id=%{public}@",
                       log: .default, type: .error, "\(err)", id)
            }
        }
    }

    /// 通知自检：授权状态 + 已排程条数，用于定位「点了没反应」。
    /// 系统 API 都是异步的，所以用回调返回结果，不能同步拿。
    static func diagnose(_ completion: @escaping ([String]) -> Void) {
        let center = UNUserNotificationCenter.current()
        var out: [String] = []
        center.getNotificationSettings { s in
            let status: String
            switch s.authorizationStatus {
            case .authorized: status = "已授权"
            case .denied: status = "**已拒绝**（需去系统设置里手动打开）"
            case .notDetermined: status = "未询问"
            case .provisional: status = "临时授权"
            default: status = "未知"
            }
            out.append("通知权限：\(status)")
            out.append("横幅提醒：\(s.alertSetting == .enabled ? "开" : "关")")
            out.append("声音：\(s.soundSetting == .enabled ? "开" : "关")")

            center.getPendingNotificationRequests { reqs in
                out.append("已排程通知：\(reqs.count) 条")
                // 到点通知（at-）与预告（pre-）分别计数，便于定位是哪一类没排上
                let at = reqs.filter { $0.identifier.hasPrefix("at-") }.count
                let pre = reqs.filter { $0.identifier.hasPrefix("pre-") }.count
                out.append("其中到点 \(at) 条 · 预告 \(pre) 条")
                let fmtS = DateFormatter()
                fmtS.dateFormat = "MM-dd HH:mm"
                let soon = reqs.compactMap { r -> String? in
                    guard let t = r.trigger as? UNTimeIntervalNotificationTrigger else { return nil }
                    return fmtS.string(from: Date().addingTimeInterval(t.timeInterval))
                }.sorted()
                if !soon.isEmpty {
                    out.append("最近 3 条：" + soon.prefix(3).joined(separator: " / "))
                }
                DispatchQueue.main.async { completion(out) }
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

/// SwiftUI 的最小宽度变更不一定会同步下发到已创建的 NSWindow，
/// 因此折叠侧栏时也显式更新原生窗口的尺寸限制。
private struct WindowMinimumSizeConfigurator: NSViewRepresentable {
    let minWidth: CGFloat
    let minHeight: CGFloat

    func makeNSView(context: Context) -> WindowMinimumSizeView {
        let view = WindowMinimumSizeView()
        view.minimumSize = NSSize(width: minWidth, height: minHeight)
        return view
    }

    func updateNSView(_ nsView: WindowMinimumSizeView, context: Context) {
        nsView.minimumSize = NSSize(width: minWidth, height: minHeight)
    }
}

private final class WindowMinimumSizeView: NSView {
    var minimumSize = NSSize.zero {
        didSet { applyMinimumSize() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMinimumSize()
    }

    private func applyMinimumSize() {
        guard let window else { return }
        window.minSize = minimumSize
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
    /// 待确认删除的记录（nil = 未点删除）。删除不可撤销，必须二次确认。
    @State private var pendingDelete: CropRecord? = nil
    /// 左侧录入面板是否收起。收起后记录区独占宽度，适合记录多时查看。
    @State private var inputCollapsed: Bool = false
    @State private var isShowingMinimumWindowSize: Bool = false
    private let compactRecordsBreakpoint: CGFloat = 520
    private let compactRecordsHeightBreakpoint: CGFloat = 520
    private let compactWindowMinimumWidth: CGFloat = 260
    private let compactWindowMinimumHeight: CGFloat = 322
    private let recordsOverviewWidth: CGFloat = 527
    private let recordsOverviewHeight: CGFloat = 755

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
            // 左右分栏：左侧录入、右侧收菜记录，首屏即可看到记录。
            // 左侧可折叠：记录多的时候收起，把宽度全让给记录区。
            GeometryReader { geometry in
                let compactRecords = geometry.size.height < compactRecordsHeightBreakpoint
                    || (inputCollapsed && geometry.size.width < compactRecordsBreakpoint)

                HStack(alignment: .top, spacing: 0) {
                    if inputCollapsed {
                        collapsedPane(compact: compactRecords)
                    } else {
                        inputPane
                            .frame(minWidth: 420, idealWidth: 480, maxWidth: 560)
                    }
                    Divider()
                    recordsPane(compact: compactRecords)
                        .frame(minWidth: compactRecords ? 0 : 380)
                }
                .frame(minWidth: inputCollapsed ? compactWindowMinimumWidth : 900)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationTitle("农场收菜")
            .navigationSubtitle("桌面实时倒计时")
            .background(.clear)
            .onAppear {
                records = CropStore.load()
                // bootstrap 内部会在授权回调里重排通知，
                // 不要在这里再排一次——那会在授权完成前被丢弃
                CropNotifier.bootstrap()
                diagLines = CropStore.diagnoseEnvironment()
                // 通知自检是异步的，稍后回填到诊断框
                CropNotifier.diagnose { lines in
                    diagLines += ["— 通知 —"] + lines
                }
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
        .background {
            WindowMinimumSizeConfigurator(
                minWidth: inputCollapsed ? compactWindowMinimumWidth : 900,
                minHeight: compactWindowMinimumHeight
            )
            .frame(width: 1, height: 1)
            .hidden()
        }
        .frame(minWidth: inputCollapsed ? compactWindowMinimumWidth : 900,
               minHeight: compactWindowMinimumHeight)
        .confirmationDialog("清除 \(readyCount) 条已收获的记录？",
                            isPresented: $clearReadyConfirm, titleVisibility: .visible) {
            Button("清除", role: .destructive) { clearReadyRecords() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已到收菜时间的记录将从列表中移除，此操作不可撤销。")
        }
        // 单条记录删除的二次确认。多茬时把各茬时间一并列出，
        // 让用户知道删掉的是什么，而不是只看到一个菜名。
        .alert("删除「\(pendingDelete?.name ?? "")」？",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) { confirmDelete() }
        } message: {
            Text(deleteConfirmMessage)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            // 回到前台时重排：等待期间有些通知已经触发或过期，
            // 不重排会留下失效条目，也会让新编辑的收菜时间漏掉提醒。
            records = CropStore.load()
            CropNotifier.reschedule(records)
            CropNotifier.diagnose { lines in
                let filtered = diagLines.filter { !$0.hasPrefix("—") && !$0.contains("通知") }
                diagLines = filtered + lines
            }
        }
    }

    private func formatPreviewText(_ s: String) -> String { s }

    // MARK: - 左栏：录入

    /// 收起态的左栏；窄屏再收窄，只保留展开和自定义入口。
    private func collapsedPane(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 14) {
            Button {
                withAnimation(.smooth) { inputCollapsed = false }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("展开录入面板")

            Button(action: toggleWindowSize) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("点击缩到最小宽高，再点展开五条记录视图")

            if !compact {
                // 收起时仍能看到最要紧的两个数。统计条本身低频刷新（5 秒），
                // 这里跟着它走即可，不必再单独包秒级 TimelineView。
                TimelineView(.periodic(from: .now, by: 5)) { ctx in
                    VStack(spacing: 8) {
                        collapsedStat("待收", count: countPending(at: ctx.date), tint: .orange)
                        collapsedStat("可收", count: countReady(at: ctx.date), tint: .green)
                    }
                }
                .padding(.top, 6)
            }

            // 快捷入口组：快速记录 + 自定义（蔬菜管理 / 导入导出）
            VStack(spacing: compact ? 0 : 10) {
                // 「种下并记录」是最高频操作，收起后不该消失——
                // 用当前选中的蔬菜和已填时长直接记一条，省得展开再点。
                if !compact {
                    Button {
                        addRecord()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAdd)
                    .opacity(canAdd ? 1 : 0.35)
                    .help(canAdd
                          ? "种下「\(selectedPreset?.name ?? "")」并记录"
                          : "请先选蔬菜并填写时长（需展开面板）")
                }

                // 自定义蔬菜 / 管理 / 导入导出备份。
                // 展开态这个入口在「选择蔬菜」标题行，收起后不能跟着消失。
                Button {
                    showAddCrop = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
                        .background(Color.primary.opacity(0.07),
                                    in: Circle())
                }
                .buttonStyle(.plain)
                .help("自定义蔬菜 / 管理已有蔬菜 / 导入导出备份")
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 8 : 16)
        .frame(width: compact ? 40 : 76)
        .background(Color.primary.opacity(0.02))
    }

    private func collapsedStat(_ title: String, count: Int, tint: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(count)")
                .font(.title3.bold()).foregroundStyle(tint)
            Text(title)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 56)
        .padding(.vertical, 6)
        .background(tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

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
                    Button {
                        withAnimation(.smooth) { inputCollapsed = true }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("收起左侧面板，记录区占满宽度")
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

                        NotePresetBar(noteText: $noteText)

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

    private func recordsPane(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !compact {
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
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(records) { r in
                            RecordRow(
                                r: r,
                                compact: compact,
                                onEdit: { editTarget = r },
                                onDelete: { delete(r) }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(compact ? 6 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    /// 点删除不立即执行，先挂起等用户确认——避免误触就丢数据
    private func delete(_ r: CropRecord) {
        pendingDelete = r
    }

    /// 删除确认框的正文：列出这条记录有几茬、什么时候收，
    /// 让用户在不可撤销的操作前明确知道会删掉什么。
    private var deleteConfirmMessage: String {
        guard let r = pendingDelete else { return "" }
        let n = r.harvests.count
        if n <= 1 {
            let when = r.harvests.first.map { fmt($0.date) } ?? "未设置"
            return "收菜时间 \(when)。此操作不可撤销。"
        }
        let pending = r.harvests.filter { !$0.harvested }.count
        let done = n - pending
        let next = r.nextHarvest.map { fmt($0) } ?? "无"
        return """
        共 \(n) 茬，已收 \(done) 茬，待收 \(pending) 茬。\
        下次收菜：\(next)。此操作不可撤销。
        """
    }

    /// 确认删除：真正落盘 + 重排通知 + 刷小组件
    private func confirmDelete() {
        guard let r = pendingDelete else { return }
        pendingDelete = nil
        records.removeAll { $0.id == r.id }
        CropStore.save(records)
        CropNotifier.reschedule(records)
        CropStore.reloadWidget()
    }

    /// 在最小窗口与五条记录视图之间切换。
    private func toggleWindowSize() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else {
            return
        }

        // State flips before the NSWindow animation starts, so a fast second click
        // still restores the overview instead of reapplying the minimum size.
        let isAtMinimumSize = isShowingMinimumWindowSize
            || (window.frame.width <= compactWindowMinimumWidth + 1
                && window.frame.height <= compactWindowMinimumHeight + 40)
        let targetSize = isAtMinimumSize
            ? CGSize(width: recordsOverviewWidth, height: recordsOverviewHeight)
            : CGSize(width: compactWindowMinimumWidth, height: compactWindowMinimumHeight)
        isShowingMinimumWindowSize = !isAtMinimumSize

        window.minSize = NSSize(width: compactWindowMinimumWidth,
                                height: compactWindowMinimumHeight)

        var frame = window.frame
        frame.size = targetSize
        window.setFrame(frame, display: true, animate: true)
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
    var compact: Bool = false
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if compact {
                HStack(alignment: .top, spacing: 6) {
                    avatar(size: 26, font: .caption.bold())
                    VStack(alignment: .leading, spacing: 4) {
                        if r.harvests.isEmpty {
                            Text("未设置收菜时间")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(r.harvests) { cycle in
                                let isUrgent = !cycle.harvested
                                    && cycle.date.timeIntervalSinceNow <= Self.urgentSeconds
                                let timeTint: Color = cycle.harvested ? .green
                                    : (isUrgent ? .orange : .secondary)

                                Text(fmt(cycle.date))
                                    .font(.callout.weight(isUrgent ? .bold : .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(timeTint)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .layoutPriority(1)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(
                                        isUrgent ? Color.orange.opacity(0.14) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    )
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onEdit)
                .contextMenu {
                    Button("编辑", systemImage: "pencil", action: onEdit)
                    Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint("点击编辑，或使用右键菜单删除")
                .help("点击编辑；右键可删除")
            } else {
                regularContent
            }
        }
        .padding(compact ? 6 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
        // 整卡左侧的橙色竖条：行内高亮只占小块位置，扫列表时容易漏看，
        // 加一条贯穿的边条让「快到点 / 已到点」的记录在余光里也能被捕捉到。
        .overlay(alignment: .leading) {
            if !compact, cardHighlightTint != nil {
                RoundedRectangle(cornerRadius: 2)
                    .fill(cardHighlightTint!)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 1)
            }
        }
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var regularContent: some View {
        HStack(spacing: 10) {
            avatar(size: 36, font: .subheadline.bold())
            VStack(alignment: .leading, spacing: 4) {
                Text(r.name).font(.subheadline.bold())

                // 每茬收菜时间单独一行：多茬时不再压缩成「第N茬」胶囊，
                // 全部时间点直接铺开，方便一眼看清哪几茬已收、哪几茬还等着。
                if r.harvests.isEmpty {
                    // 异常数据兜底：正常路径下 harvests 至少一茬（编辑弹窗不允许删空）
                    Text("未设置收菜时间")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(r.harvests) { c in
                        harvestLine(c)
                    }
                }

                if let note = r.note, !note.isEmpty {
                    NotePresetRecordNote(note: note)
                        .font(.caption2)
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
            .help("删除这条记录（会先弹出确认）")
        }
    }

    private func avatar(size: CGFloat, font: Font) -> some View {
        Circle()
            .fill(LinearGradient(colors: [Color(hex: r.colorHex),
                                          Color(hex: r.colorHex).opacity(0.7)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Text(String(r.name.prefix(1)))
                .foregroundColor(.white).font(font))
    }

    /// 卡片级高亮色：只要有任一茬到期或临近就返回橙色。nil = 无需高亮。
    private var cardHighlightTint: Color? {
        for h in r.harvests where !h.harvested {
            if h.date.timeIntervalSinceNow <= Self.urgentSeconds { return .orange }
        }
        return nil
    }

    /// 单茬收菜时间的一行：时间 + 该茬的倒计时/状态。
    /// 时间是这行的主角，用 callout + 半粗 + 底色块托住，倒计时用等宽数字紧随其后。
    private func harvestLine(_ c: HarvestCycle) -> some View {
        HStack(spacing: 8) {
            // 时刻是静态文本，不需要每秒重绘。
            // 颜色只区分「已收 / 临近 / 常态」——临近判定用 Date() 粗算即可，
            // 精确到秒的变化交给右侧倒计时（那里本来就在每秒重建）。
            let left = c.date.timeIntervalSinceNow
            let tint: Color = c.harvested ? .green
                : (left <= 0 || left <= Self.urgentSeconds ? .orange : .accentColor)
            let strength: Double = c.harvested ? 0.10
                : (left <= 0 || left <= Self.urgentSeconds ? 0.22 : 0.16)

            Text(fmt(c.date))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(c.harvested ? Color.secondary : tint)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(tint.opacity(strength),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            countdownView(c)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(c))
    }

    /// 倒计时单独包 TimelineView：
    /// **性能关键** —— 只有这一个 Text 会随时间重建，
    /// 外层的时刻底色、整张列表都不重绘。
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
            let left = c.date.timeIntervalSince(context.date)
            let overdue = left <= 0

            if overdue {
                // 到期未收：最需要被看到的状态，给实心胶囊而不是 00:00
                Text("可收")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
            } else if left <= Self.urgentSeconds {
                // 临近（≤20 分钟）：加深、加底色、加粗 —— 这段时间最可能
                // 需要马上处理，扫列表时必须一眼看到。
                Text(remainText(c.date, now: context.date))
                    .font(.callout.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 6,
                                                                    style: .continuous))
            } else {
                // 常规：灰色等宽，不抢视线
                Text(remainText(c.date, now: context.date))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        })
    }

    /// 临近阈值：30 分钟内高亮提示
    private static let urgentSeconds: TimeInterval = 30 * 60

    private func accessibilityText(_ c: HarvestCycle) -> String {
        let base = fmt(c.date)
        if c.harvested { return "\(base) 已收" }
        let left = max(0, Int(c.date.timeIntervalSinceNow))
        let h = left / 3600, m = (left % 3600) / 60, s = left % 60
        return h > 0
            ? "\(base) 还剩 \(h) 小时 \(m) 分"
            : "\(base) 还剩 \(m) 分 \(s) 秒"
    }
}

/// 编辑单条记录：改名称/备注，并管理各茬收菜时间（反复续期，每茬可单独编辑）
struct EditRecordSheet: View {
    let record: CropRecord
    let onSave: (CropRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    /// 新增一茬时可从现在起按时长计算，或指定绝对日期时间。
    enum NewMode: String, CaseIterable, Identifiable {
        case fromNow = "从现在起"
        case absoluteDate = "按指定时间"
        var id: String { rawValue }

        /// 是否需要填「小时 + 分钟」（绝对日期模式用DatePicker）
        var usesDuration: Bool { self != .absoluteDate }
    }

    @State private var nameText: String
    @State private var noteText: String
    /// 各茬收菜（可在列表里逐行编辑时间、标记已收、删除）
    @State private var harvests: [HarvestCycle]

    /// 待确认删除的茬（nil = 未点删除）
    @State private var pendingCycleDelete: HarvestCycle? = nil

    // 新增一茬的表单
    @State private var newMode: NewMode = .fromNow
    @State private var newHoursText: String = "1"
    @State private var newMinutesText: String = "0"
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

    private var previewNewDate: Date {
        switch newMode {
        case .fromNow:
            return Date().addingTimeInterval(TimeInterval(newTotalMinutes * 60))
        case .absoluteDate:
            return newDate
        }
    }

    /// 「添加」按钮的可用性：算出来的时间必须晚于现在。
    /// 否则会往列表里塞一个已经过期的茬，界面上立刻变成「可收」，没意义。
    private var canAddCycle: Bool {
        switch newMode {
        case .fromNow:
            return newTotalMinutes > 0
        case .absoluteDate:
            return newDate > Date()
        }
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

                            NotePresetBar(noteText: $noteText)
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
            // 删茬的二次确认。注意不能删掉最后一茬，否则这条记录就没有收菜时间了。
            .alert("删除这一茬？",
                   isPresented: Binding(get: { pendingCycleDelete != nil },
                                        set: { if !$0 { pendingCycleDelete = nil } })) {
                Button("取消", role: .cancel) { pendingCycleDelete = nil }
                Button("删除", role: .destructive) {
                    if let id = pendingCycleDelete?.id {
                        harvests.removeAll { $0.id == id }
                    }
                    pendingCycleDelete = nil
                }
            } message: {
                if let c = pendingCycleDelete {
                    Text(cycleDeleteMessage(c))
                }
            }
        }
    }

    /// 删茬确认正文：说清是哪一茬、什么时间、删完还剩几茬
    private func cycleDeleteMessage(_ c: HarvestCycle) -> String {
        let remain = harvests.count - 1
        let base = "收菜时间 \(fmt(c.date))"
        guard remain > 0 else {
            return base + "。这是唯一一茬，删除后需要重新添加。"
        }
        return base + "。删除后还剩 \(remain) 茬。"
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
                    .frame(maxWidth: 420)

                    HStack(spacing: 8) {
                        if newMode.usesDuration {
                            TextField("1", text: $newHoursText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 66)
                                .multilineTextAlignment(.trailing)
                            Text("小时").font(.subheadline).foregroundStyle(.secondary)
                            TextField("0", text: $newMinutesText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 66)
                                .multilineTextAlignment(.trailing)
                            Text("分钟").font(.subheadline).foregroundStyle(.secondary)
                            Text("从现在起 · \(fmt(previewNewDate))")
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
                        .disabled(!canAddCycle)
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
                // 删茬同样不可撤销，先挂起等确认
                pendingCycleDelete = h.wrappedValue
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(.red)
            .help("删除这一茬（会先弹出确认）")
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
    @State private var adjustBasis: AdjustBasis = .fromNow
    /// 负数表示往前拨，正数往后
    @State private var adjustDirection: AdjustDirection = .later

    enum AdjustBasis: String, CaseIterable, Identifiable {
        case currentCycle = "基于原时间"
        case fromNow = "从现在起"
        var id: String { rawValue }
    }

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
        adjustBasis = .fromNow
        adjustDirection = .later
    }

    private func closeAdjust() {
        adjustingID = nil
    }

    /// 面板里的调整时长（分钟）；非法、负数、溢出或零时长均不允许应用。
    private var adjustDurationMinutes: Int? {
        guard let hours = Int(adjustHoursText.trimmingCharacters(in: .whitespaces)),
              let minutes = Int(adjustMinutesText.trimmingCharacters(in: .whitespaces)),
              hours >= 0, minutes >= 0 else { return nil }
        let (hourMinutes, overflow1) = hours.multipliedReportingOverflow(by: 60)
        let (total, overflow2) = hourMinutes.addingReportingOverflow(minutes)
        guard !overflow1, !overflow2, total > 0 else { return nil }
        return total
    }

    private func adjustedDate(for cycle: HarvestCycle) -> Date? {
        guard let duration = adjustDurationMinutes else { return nil }
        let base = adjustBasis == .fromNow ? Date() : cycle.date
        let direction = adjustBasis == .fromNow || adjustDirection == .later ? 1.0 : -1.0
        return base.addingTimeInterval(TimeInterval(duration) * 60 * direction)
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

            Picker("起算方式", selection: $adjustBasis) {
                ForEach(AdjustBasis.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if adjustBasis == .currentCycle {
                Picker("调整方向", selection: $adjustDirection) {
                    ForEach(AdjustDirection.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

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

            if let c = cur, let newDate = adjustedDate(for: c) {
                Text(adjustBasis == .fromNow
                     ? "从现在起 → \(fmt(newDate))"
                     : "→ \(fmt(newDate))")
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
                .disabled(adjustDurationMinutes == nil)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func applyAdjust(for id: String) {
        guard let i = harvests.firstIndex(where: { $0.id == id }) else { return }
        guard let newDate = adjustedDate(for: harvests[i]) else { return }
        harvests[i].date = newDate
        // 调整后时间顺序可能变了，保持列表始终按时间先后展示
        harvests.sort { $0.date < $1.date }
    }

    private func addCycle() {
        let d = previewNewDate
        harvests.append(HarvestCycle(date: d))
        // 用户可能往回加时间，列表始终按时间先后展示
        harvests.sort { $0.date < $1.date }
        // 保留新增时间，切换到「按指定时间」时可直接沿用
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

/// 备注说明的预选标签栏：点标签可多选填入，再次点击取消，自动去重。
/// 两类预选值各占一行：第一行「种子」、第二行「树苗」。
/// 内部以「、」作为选中项的分隔符，noteText 同时仍是自由文本（可手写）。
/// 部分标签属于同一类（如豆类、名贵树苗），用色点 + 同色描边高亮区分。
struct NotePresetBar: View {
    @Binding var noteText: String

    // 预选值清单、分组与配色统一在 NotePresets / NotePresetGroup（CropStore.swift，主 App 与 Widget 共用）

    /// 当前已选中的 token 集合（按「、」切分）
    private var selectedTokens: Set<String> {
        Set(noteText.split(separator: "、")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            presetRow(NotePresets.seeds, label: "种子")
            presetRow(NotePresets.seedlings, label: "树苗")
            HStack(spacing: 14) {
                ForEach(NotePresetGroup.allCases) { g in
                    HStack(spacing: 4) {
                        Circle().fill(g.color).frame(width: 7, height: 7)
                        Text(g.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Text("点击标签多选填入，再次点击取消（自动去重）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func presetRow(_ presets: [NotePreset], label: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
                .padding(.top, 5)
            FlowLayout(spacing: 6) {
                ForEach(presets) { p in
                    chip(p)
                }
            }
        }
    }

    private func chip(_ p: NotePreset) -> some View {
        let on = selectedTokens.contains(p.id)
        let gc = p.group?.color
        return Button {
            withAnimation(.smooth(duration: 0.15)) { toggle(p.id) }
        } label: {
            HStack(spacing: 4) {
                if let gc {
                    Circle().fill(gc).frame(width: 6, height: 6)
                }
                Text(p.id).font(.caption2)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(bg(on: on, gc: gc),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(border(on: on, gc: gc), lineWidth: 1))
            .foregroundStyle(fg(on: on, gc: gc))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - 配色

    private func bg(on: Bool, gc: Color?) -> Color {
        if let gc { return gc.opacity(on ? 0.22 : 0.10) }
        return on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)
    }
    private func border(on: Bool, gc: Color?) -> Color {
        if let gc { return gc.opacity(on ? 1 : 0.5) }
        return on ? Color.accentColor : Color.primary.opacity(0.12)
    }
    private func fg(on: Bool, gc: Color?) -> Color {
        if let gc { return on ? gc : .primary }
        return on ? Color.accentColor : .primary
    }

    /// 切换某个预选值：未选则追加，已选则移除，结果以「、」拼接（天然去重）
    private func toggle(_ preset: String) {
        var arr = noteText.split(separator: "、")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let idx = arr.firstIndex(of: preset) {
            arr.remove(at: idx)
        } else {
            arr.append(preset)
        }
        noteText = arr.joined(separator: "、")
    }
}

/// 简单的流式布局：子视图按行自动换行（SwiftUI 原生无 flow 容器）。
/// 用于备注预选标签在有限宽度内折行展示。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        guard let maxWidth = proposal.width, maxWidth > 0 else {
            return subviews.map { $0.sizeThatFits(.unspecified) }
                .reduce(CGSize.zero) { CGSize(width: max($0.width, $1.width),
                                              height: $0.height + $1.height + spacing) }
        }
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, x - spacing)
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, x - spacing)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    ContentView()
}

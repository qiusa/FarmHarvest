import Foundation
import SwiftUI
import os.log

#if canImport(WidgetKit)
import WidgetKit
#endif

/// 单条收菜记录（两种 target 共用，通过 App Group 的 UserDefaults 持久化）
struct CropRecord: Identifiable, Codable {
    let id: String
    let name: String
    let colorHex: String
    let minutes: Int
    let plantedAt: Date
    let harvestAt: Date
    /// 种菜备注说明（可选，可在编辑弹窗修改；旧数据无此字段时解码为 nil）
    var note: String?
}

/// 蔬菜预设（默认成熟分钟数）
struct CropPreset: Codable, Identifiable {
    let id: String
    let name: String
    let colorHex: String
    let minutes: Int
}

/// 数据存取：主 App 写入，Widget 读取（共享同一 App Group）
enum CropStore {
    // 关键：macOS 上必须用「TeamID 前缀」的 App Group，无需 provisioning profile；
    // 若用 group. 前缀则强制要求 profile，本机没有 → 授权失败、App 与 Widget 无法共享数据。
    static let appGroup = "MWYKGVPTJP.com.yixin.farmharvest"

    // 存储根目录。优先 App Group 共享容器（Widget 与主 App 才能互通）；
// 关键：不能只看 containerURL != nil —— 容器路径存在但目录不可写（常见于
    // 目录由其它签名身份创建、本App adhoc 签名无写权限）时，写盘依然会失败，
    // 表现为「点��种下并记录」完全没反应。因此必须做真实写探测。
    //
    // 注意：此处绝不能调用 diag() —— diag 依赖 storageRoot，会触发
    // _dispatch_once 重入 → 无限递归 → SIGTRAP 崩溃。
    static let storageRoot: URL = {
        if let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup),
           Self.isWritable(u) {
            return u
        }
        let fallback = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FarmHarvest", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }()

    /// 目录写探测：真写一个临时文件再删掉，比看路径是否存在可靠得多
    private static func isWritable(_ dir: URL) -> Bool {
        let probe = dir.appendingPathComponent(".w-\(UUID().uuidString)")
        do {
            try Data("0".utf8).write(to: probe, options: .atomic)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// 共享容器是否真的可用于数据交换（能拿到路径且可写）
    static let isSharedContainerAvailable: Bool = {
        guard let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return false }
        return isWritable(u)
    }()

    /// 启动时自检：把存储根、容器可用性、读写探测结果摊开给用户，
    /// 用于定位「点了没反应」这类静默失败。
    static func diagnoseEnvironment() -> [String] {
        var lines: [String] = []
        lines.append("存储根：\(storageRoot.path)")
        lines.append("共享容器可用：\(isSharedContainerAvailable)")
        let probe = storageRoot.appendingPathComponent(".probe")
        do {
            try Data("1".utf8).write(to: probe, options: .atomic)
            let ok = (try? Data(contentsOf: probe)) != nil
            try? FileManager.default.removeItem(at: probe)
            lines.append("读写探测：\(ok ? "正常" : "写入后读不回")")
        } catch {
            lines.append("读写探测失败：\(error.localizedDescription)")
        }
        return lines
    }

    /// 仅写 os_log，不触碰 storageRoot（避免 static 初始化重入递归）
    private static func diag(_ msg: String) {
        os_log("%{public}@", log: .default, type: .error, msg)
    }

    private static var recordsURL: URL { storageRoot.appendingPathComponent("records.json") }
    private static var customCropsURL: URL { storageRoot.appendingPathComponent("customCrops.json") }
    private static var hiddenBuiltinsURL: URL { storageRoot.appendingPathComponent("hiddenBuiltins.json") }

    private static let builtinPresets: [CropPreset] = [
        CropPreset(id: "carrot", name: "胡萝卜", colorHex: "FF8C42", minutes: 20),
        CropPreset(id: "cabbage", name: "白菜", colorHex: "7AC74F", minutes: 40),
        CropPreset(id: "tomato", name: "番茄", colorHex: "E63946", minutes: 60),
        CropPreset(id: "corn", name: "玉米", colorHex: "FFD23F", minutes: 90),
        CropPreset(id: "potato", name: "土豆", colorHex: "C08457", minutes: 30),
        CropPreset(id: "strawberry", name: "草莓", colorHex: "F06595", minutes: 45),
    ]

    /// 内置蔬菜定义（供管理界面展示）
    static var builtinCrops: [CropPreset] { builtinPresets }

    /// 被用户删除掉的内置蔬菜 id（持久化，实现「默认蔬菜也能删除」）
    private static var hiddenBuiltinIDs: Set<String> {
        guard let data = try? Data(contentsOf: hiddenBuiltinsURL) else { return [] }
        return Set((try? JSONDecoder().decode([String].self, from: data)) ?? [])
    }

    private static func saveHiddenBuiltinIDs(_ ids: Set<String>) {
        let url = hiddenBuiltinsURL
        guard let data = try? JSONEncoder().encode(Array(ids).sorted()) else { return }
        do {
            try data.write(to: url, options: .atomic)
            reloadWidget()
        } catch {
            diag("隐藏内置蔬菜写入失败 \(url.path) -> \(error)")
        }
    }

    /// 可选蔬菜 = 未被删除的内置 + 自定义
    static var presets: [CropPreset] {
        let hidden = hiddenBuiltinIDs
        return builtinPresets.filter { !hidden.contains($0.id) } + customCrops()
    }

    static let cropPalette = ["FF8C42","7AC74F","E63946","FFD23F","C08457","F06595","9B5DE5","00BBF9","00F5D4","F15BB5"]

    static func customCrops() -> [CropPreset] {
        guard let data = try? Data(contentsOf: customCropsURL) else { return [] }
        return (try? JSONDecoder().decode([CropPreset].self, from: data)) ?? []
    }

    /// 新增自定义蔬菜（支持自定义名字 + 颜色 + 默认成熟时长），返回新蔬菜
    @discardableResult
    static func addCustomCrop(name: String, colorHex: String? = nil, minutes: Int = 30) -> CropPreset {
        let hex = (colorHex ?? cropPalette[customCrops().count % cropPalette.count])
        let c = CropPreset(id: UUID().uuidString, name: name, colorHex: hex,
                           minutes: max(1, minutes))
        var list = customCrops()
        list.append(c)
        saveCustom(list)
        return c
    }

    /// 删除自定义蔬菜
    static func removeCustomCrop(id: String) {
        saveCustom(customCrops().filter { $0.id != id })
    }

    /// 修改自定义蔬菜（名称 / 颜色 / 默认时长）
    static func updateCustomCrop(_ preset: CropPreset) {
        var list = customCrops()
        if let i = list.firstIndex(where: { $0.id == preset.id }) {
            list[i] = preset
            saveCustom(list)
        }
    }

    /// 删除内置蔬菜：记入隐藏列表（不破坏内置定义，可一键恢复）
    static func hideBuiltinCrop(id: String) {
        var ids = hiddenBuiltinIDs
        ids.insert(id)
        saveHiddenBuiltinIDs(ids)
    }

    /// 恢复单个内置蔬菜
    static func restoreBuiltinCrop(id: String) {
        var ids = hiddenBuiltinIDs
        ids.remove(id)
        saveHiddenBuiltinIDs(ids)
    }

    /// 恢复全部内置蔬菜
    static func restoreAllBuiltinCrops() {
        saveHiddenBuiltinIDs([])
    }

    /// 当前被删除的内置蔬菜列表（管理界面展示「恢复」用）
    static func hiddenBuiltinCrops() -> [CropPreset] {
        let hidden = hiddenBuiltinIDs
        return builtinPresets.filter { hidden.contains($0.id) }
    }

    /// 统一删除：自定义直接移除，内置记入隐藏列表
    static func removeCrop(id: String) {
        if builtinPresets.contains(where: { $0.id == id }) {
            hideBuiltinCrop(id: id)
        } else {
            removeCustomCrop(id: id)
        }
    }

    private static func saveCustom(_ list: [CropPreset]) {
        let url = customCropsURL
        guard let data = try? JSONEncoder().encode(list) else { return }
        do {
            try data.write(to: url, options: .atomic)
            reloadWidget()
        } catch {
            diag("自定义蔬菜写入失败 \(url.path) -> \(error)")
        }
    }

    static func load() -> [CropRecord] {
        let url = recordsURL
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CropRecord].self, from: data)) ?? []
    }

    static func save(_ records: [CropRecord]) {
        let url = recordsURL
        guard let data = try? JSONEncoder().encode(records) else {
            diag("记录编码失败")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            diag("已写入 \(url.path)（\(isSharedContainerAvailable ? "共享" : "沙盒")）")
            reloadWidget()
        } catch {
            diag("写入失败 \(url.path) -> \(error)")
        }
    }

    /// 主动通知 WidgetKit 刷新时间线（主 App 启动/回到前台时调用，确保桌面组件及时同步）
    static func reloadWidget() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// 填入一个数字（成熟分钟数）+ 选定蔬菜 -> 新增一条收菜记录
    static func add(preset: CropPreset, minutes: Int, note: String? = nil) {
        var records = load()
        let now = Date()
        let rec = CropRecord(
            id: UUID().uuidString,
            name: preset.name,
            colorHex: preset.colorHex,
            minutes: minutes,
            plantedAt: now,
            harvestAt: now.addingTimeInterval(TimeInterval(minutes * 60)),
            note: note
        )
        records.insert(rec, at: 0)
        save(records)
    }

    /// 按指定收菜时间新增一条记录（"新增时间"模式）
    static func addWithHarvestTime(preset: CropPreset, harvestAt: Date, note: String? = nil) {
        var records = load()
        let now = Date()
        let rec = CropRecord(
            id: UUID().uuidString,
            name: preset.name,
            colorHex: preset.colorHex,
            minutes: max(0, Int(harvestAt.timeIntervalSince(now) / 60)),
            plantedAt: now,
            harvestAt: harvestAt,
            note: note
        )
        records.insert(rec, at: 0)
        save(records)
    }

    /// 编辑已有记录（按 id 替换）-> 对应收菜时间变更
    static func update(_ updated: CropRecord) {
        var list = load()
        if let i = list.firstIndex(where: { $0.id == updated.id }) {
            list[i] = updated
            save(list)
        }
    }

    // MARK: - 导入 / 导出

    /// 备份文件格式（版本化，便于以后扩展）
    struct Backup: Codable {
        var version: Int = 1
        var exportedAt: Date = Date()
        var records: [CropRecord] = []
        var customCrops: [CropPreset] = []
        /// 被删除的内置蔬菜 id
        var hiddenBuiltins: [String] = []
    }

    enum ImportMode {
        /// 合并：同 id 覆盖，不同 id 追加
        case merge
        /// 替换：清空后完全采用备份内容
        case replace
    }

    struct ImportSummary {
        var recordsAdded: Int
        var cropsAdded: Int
        var mode: ImportMode
    }

    /// 导出全部数据为 JSON 字符串
    static func exportBackupJSON() throws -> Data {
        let backup = Backup(
            records: load(),
            customCrops: customCrops(),
            hiddenBuiltins: Array(hiddenBuiltinIDs).sorted()
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(backup)
    }

    /// 写入到指定 URL
    static func exportBackup(to url: URL) throws {
        try exportBackupJSON().write(to: url, options: .atomic)
    }

    /// 从 JSON 数据导入
    static func importBackup(from data: Data, mode: ImportMode) throws -> ImportSummary {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let backup = try dec.decode(Backup.self, from: data)
        guard backup.version <= 1 else {
            throw NSError(domain: "FarmHarvest", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "备份版本 \(backup.version) 高于当前 App 支持的版本"
            ])
        }

        // 合并：备份中同 id 的记录覆盖现有记录，仅追加本地没有的
        var addedRecords: Int
        if mode == .replace {
            save(backup.records)
            addedRecords = backup.records.count
        } else {
            var cur = load()
            let backupIDs = Set(backup.records.map(\.id))
            cur.removeAll { backupIDs.contains($0.id) }
            let existAfterRemove = Set(cur.map(\.id))
            let fresh = backup.records.filter { !existAfterRemove.contains($0.id) }
            cur.append(contentsOf: fresh)
            save(cur)
            addedRecords = backup.records.count
        }

        var addedCrops: Int
        if mode == .replace {
            saveCustom(backup.customCrops)
            saveHiddenBuiltinIDs(Set(backup.hiddenBuiltins))
            addedCrops = backup.customCrops.count
        } else {
            var cur = customCrops()
            let backupIDs = Set(backup.customCrops.map(\.id))
            cur.removeAll { backupIDs.contains($0.id) }
            let existAfterRemove = Set(cur.map(\.id))
            let fresh = backup.customCrops.filter { !existAfterRemove.contains($0.id) }
            cur.append(contentsOf: fresh)
            saveCustom(cur)
            saveHiddenBuiltinIDs(hiddenBuiltinIDs.union(backup.hiddenBuiltins))
            addedCrops = backup.customCrops.count
        }

        reloadWidget()
        return ImportSummary(recordsAdded: addedRecords,
                             cropsAdded: addedCrops,
                             mode: mode)
    }

    /// 从文件导入
    static func importBackup(from url: URL, mode: ImportMode) throws -> ImportSummary {
        let data = try Data(contentsOf: url)
        return try importBackup(from: data, mode: mode)
    }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xff) / 255.0
        let g = Double((int >> 8) & 0xff) / 255.0
        let b = Double(int & 0xff) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

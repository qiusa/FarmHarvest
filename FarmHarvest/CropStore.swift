import Foundation
import SwiftUI
import os.log

#if canImport(WidgetKit)
import WidgetKit
#endif

/// 一茬收菜（同一棵菜反复种续期时，每次采收是一个独立条目，可单独编辑）
struct HarvestCycle: Codable, Equatable, Identifiable {
    /// 稳定 id：列表行靠它做 Identifiable，编辑/删除都按 id 定位，不能用下标
    var id: String
    /// 这一茬的收菜时间
    var date: Date
    /// 是否已采收。续期场景必须区分「已收」和「已过期但还没收」：
    /// 前者已归档，后者还在等用户去收（界面上高亮可收获）。
    var harvested: Bool

    init(id: String = UUID().uuidString, date: Date, harvested: Bool = false) {
        self.id = id
        self.date = date
        self.harvested = harvested
    }
}

/// 单条收菜记录（两种 target 共用，通过 App Group 的 UserDefaults 持久化）
struct CropRecord: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let colorHex: String
    let minutes: Int
    let plantedAt: Date
    /// 各茬收菜记录（反复续期）。升序；空数组仅可能来自异常数据。
    var harvests: [HarvestCycle] = []
    /// 种菜备注说明（可选，可在编辑弹窗修改；旧数据无此字段时解码为 nil）
    var note: String?

    /// 全部收菜时间，升序
    var allHarvests: [Date] { harvests.map(\.date).sorted() }

    /// 下一茬待收时间：未采收且尚未到点的那一茬里最早的时间
    var nextHarvest: Date? {
        let n = Date()
        return harvests.filter { !$0.harvested && $0.date > n }.map(\.date).min()
    }

    /// 可收获：存在未采收、但时间已到的茬
    var isReady: Bool {
        let n = Date()
        return harvests.contains { !$0.harvested && $0.date <= n }
    }

    /// 全部了结：每一茬都已采收或已过期。「清除已收获」只清这类，
    /// 否则会误删还剩后续采收的记录。
    var isFullyHarvested: Bool {
        let n = Date()
        return harvests.allSatisfy { $0.harvested || $0.date <= n }
    }

    /// 待收茬数
    var pendingCount: Int {
        let n = Date()
        return harvests.filter { !$0.harvested && $0.date > n }.count
    }

    enum CodingKeys: String, CodingKey {
        case id, name, colorHex, minutes, plantedAt, harvests, note
        // 旧字段：仅用于解码迁移，不再写入
        case harvestAt, extraHarvests
    }

    /// 自定义解码：**必须**。
    /// 1) Swift 合成的 Decodable 遇缺字段直接抛 keyNotFound，属性默认值管不到 Codable；
    /// 2) 用户磁盘上同时存在两代历史格式（只有 harvestAt / 有 harvestAt+extraHarvests），
    ///    都要迁移成 harvests，否则升级后老记录读不出来（load() 静默返回空数组 = 记录全丢）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        minutes = try c.decode(Int.self, forKey: .minutes)
        plantedAt = try c.decode(Date.self, forKey: .plantedAt)
        note = try c.decodeIfPresent(String.self, forKey: .note)

        if let v = try c.decodeIfPresent([HarvestCycle].self, forKey: .harvests) {
            harvests = v
        } else {
            // 迁移路径：harvestAt（必需）+ extraHarvests（可选）
            let first = try c.decode(Date.self, forKey: .harvestAt)
            let extras = try c.decodeIfPresent([Date].self, forKey: .extraHarvests) ?? []
            harvests = ([first] + extras).sorted().map { HarvestCycle(date: $0) }
        }
    }

    /// 显式编码：写了 init(from:) 后 Swift 不再合成 encode(to:)。
    /// 只写新字段 harvests，harvestAt / extraHarvests 是迁移用的旧字段，
    /// 继续写入会让文件同时存在两套时间，导入时反而歧义。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(colorHex, forKey: .colorHex)
        try c.encode(minutes, forKey: .minutes)
        try c.encode(plantedAt, forKey: .plantedAt)
        try c.encode(harvests, forKey: .harvests)
        try c.encodeIfPresent(note, forKey: .note)
    }

    /// 显式成员初始化器：写了 init(from:) 后 Swift 不再合成它，构造点全靠这个
    init(id: String, name: String, colorHex: String, minutes: Int,
         plantedAt: Date, harvests: [HarvestCycle]? = nil,
         extraHarvests: [Date] = [], note: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.minutes = minutes
        self.plantedAt = plantedAt
        if let h = harvests {
            self.harvests = h
        } else {
            // 兼容旧的「首次时间 + 追加时间数组」调用方式
            let base = plantedAt.addingTimeInterval(TimeInterval(minutes * 60))
            self.harvests = ([base] + extraHarvests).sorted().map { HarvestCycle(date: $0) }
        }
        self.note = note
    }
}

/// 蔬菜预设（默认成熟分钟数）
struct CropPreset: Codable, Identifiable, Equatable {
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
    static let defaultRemoteBackupURLString =
        "https://qiniu.yixin.im/manage-web/manager-pulish/test-web/a.json"

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
            harvests: [HarvestCycle(date: now.addingTimeInterval(TimeInterval(minutes * 60)))],
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
            harvests: [HarvestCycle(date: harvestAt)],
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

    /// 续期：在已有记录后追加一茬（新菜重复种，不必新建记录）
    static func renew(_ record: CropRecord, after date: Date) {
        var updated = record
        updated.harvests.append(HarvestCycle(date: date))
        updated.harvests.sort { $0.date < $1.date }
        update(updated)
    }

    /// 标记/取消标记某一茬已采收。续期时用得上：收了这一茬，再续下一茬。
    static func setHarvested(recordID: String, cycleID: String, _ harvested: Bool) {
        var list = load()
        guard let i = list.firstIndex(where: { $0.id == recordID }),
              let j = list[i].harvests.firstIndex(where: { $0.id == cycleID })
        else { return }
        list[i].harvests[j].harvested = harvested
        save(list)
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
        /// 备份中本地原先没有、此次新追加的记录数
        var recordsAdded: Int
        /// 备份中与本地同 id、此次被覆盖的记录数
        var recordsOverwritten: Int
        /// 替换模式下等于备份里的总记录数
        var recordsTotal: Int
        var cropsAdded: Int
        var cropsOverwritten: Int
        var cropsTotal: Int
        var mode: ImportMode

        /// 面向用户的一句话摘要，说清真实变更量而不是笼统的「导入 N 条」
        var text: String {
            switch mode {
            case .replace:
                return "已替换：记录 \(recordsTotal) 条 · 蔬菜 \(cropsTotal) 个"
            case .merge:
                var parts: [String] = []
                parts.append(recordsAdded > 0 ? "新增记录 \(recordsAdded) 条" : "无新增记录")
                if recordsOverwritten > 0 { parts.append("覆盖 \(recordsOverwritten) 条") }
                var c: [String] = [cropsAdded > 0 ? "新增蔬菜 \(cropsAdded) 个" : "无新增蔬菜"]
                if cropsOverwritten > 0 { c.append("覆盖 \(cropsOverwritten) 个") }
                return "已合并：" + parts.joined(separator: " · ") + " · " + c.joined(separator: " ")
            }
        }
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
        var overwrittenRecords: Int
        if mode == .replace {
            save(backup.records)
            addedRecords = backup.records.count
            overwrittenRecords = 0
        } else {
            var cur = load()
            // curIDs 必须是**导入前**的本地 id 全集：新增 = 备份里本地完全没有的，
            // 覆盖 = 备份里本地已有（同 id）的。两者互斥，加起来才等于备份条数。
            let curIDs = Set(cur.map(\.id))
            let backupIDs = Set(backup.records.map(\.id))
            overwrittenRecords = curIDs.intersection(backupIDs).count
            addedRecords = backupIDs.subtracting(curIDs).count
            cur.removeAll { backupIDs.contains($0.id) }
            let existAfterRemove = Set(cur.map(\.id))
            let fresh = backup.records.filter { !existAfterRemove.contains($0.id) }
            cur.append(contentsOf: fresh)
            save(cur)
        }

        var addedCrops: Int
        var overwrittenCrops: Int
        if mode == .replace {
            saveCustom(backup.customCrops)
            saveHiddenBuiltinIDs(Set(backup.hiddenBuiltins))
            addedCrops = backup.customCrops.count
            overwrittenCrops = 0
        } else {
            var cur = customCrops()
            let curIDs = Set(cur.map(\.id))
            let backupIDs = Set(backup.customCrops.map(\.id))
            overwrittenCrops = curIDs.intersection(backupIDs).count
            addedCrops = backupIDs.subtracting(curIDs).count
            cur.removeAll { backupIDs.contains($0.id) }
            let existAfterRemove = Set(cur.map(\.id))
            let fresh = backup.customCrops.filter { !existAfterRemove.contains($0.id) }
            cur.append(contentsOf: fresh)
            saveCustom(cur)
            saveHiddenBuiltinIDs(hiddenBuiltinIDs.union(backup.hiddenBuiltins))
        }

        reloadWidget()
        return ImportSummary(recordsAdded: addedRecords,
                             recordsOverwritten: overwrittenRecords,
                             recordsTotal: backup.records.count,
                             cropsAdded: addedCrops,
                             cropsOverwritten: overwrittenCrops,
                             cropsTotal: backup.customCrops.count,
                             mode: mode)
    }

    /// 从 HTTPS 地址下载并导入备份。请求跳过本机缓存，并要求上游重新验证，
    /// 避免 CDN 长缓存让手机读到旧备份。
    static func importBackup(fromRemoteURL url: URL, mode: ImportMode) async throws -> ImportSummary {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw NSError(domain: "FarmHarvest", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "远程备份必须使用有效的 HTTPS 地址。"
            ])
        }

        // This Qiniu endpoint advertises a long CDN lifetime. A unique query item
        // makes each manual refresh fetch the latest uploaded JSON instead of a
        // cached earlier export. Leave signed URLs on other hosts untouched.
        var requestURL = url
        if url.host?.lowercased() == "qiniu.yixin.im",
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "_farmharvest_refresh", value: UUID().uuidString))
            components.queryItems = items
            requestURL = components.url ?? url
        }

        var request = URLRequest(
            url: requestURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw NSError(domain: "FarmHarvest", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "远程地址没有返回有效的 HTTP 响应。"
            ])
        }
        guard (200..<300).contains(response.statusCode) else {
            throw NSError(domain: "FarmHarvest", code: response.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "远程服务器返回 HTTP \(response.statusCode)。"
            ])
        }
        guard data.count <= 10 * 1024 * 1024 else {
            throw NSError(domain: "FarmHarvest", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "备份文件超过 10 MB，已取消导入。"
            ])
        }

        return try importBackup(from: data, mode: mode)
    }

    /// 从文件导入
    static func importBackup(from url: URL, mode: ImportMode) throws -> ImportSummary {
        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
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

// MARK: - 备注预选值与分组高亮（主 App 与 Widget 共用，两端展示必须一致）

/// 标签分组：用于高亮区分同一类预选值
enum NotePresetGroup: String, CaseIterable, Identifiable {
    case bean = "豆"          // 大豆/绿豆/红豆/蚕豆 种子
    case sandalwood = "名贵"  // 麻梨/老山檀/奇楠沉香 树苗
    var id: String { rawValue }
    /// 该组的主题色：豆=琥珀，名贵=紫
    var color: Color {
        switch self {
        case .bean:       return Color(red: 0.93, green: 0.60, blue: 0.18)
        case .sandalwood: return Color(red: 0.58, green: 0.36, blue: 0.82)
        }
    }
}

/// 单个备注预选值（文本 + 可选分组）
struct NotePreset: Identifiable {
    let id: String
    let group: NotePresetGroup?
    init(_ id: String, group: NotePresetGroup? = nil) {
        self.id = id
        self.group = group
    }
}

/// 备注预选值清单与渲染。预选栏（录入/编辑）与记录行（主 App / Widget）共用，
/// 保证三处展示一致。
enum NotePresets {
    /// 种子预选值（第一行），豆组高亮
    static let seeds: [NotePreset] = [
        NotePreset("甘薯种子"), NotePreset("番茄种子"), NotePreset("白菜种子"), NotePreset("酸模种子"),
        NotePreset("大豆种子", group: .bean), NotePreset("南瓜种子"), NotePreset("茄子种子"),
        NotePreset("千穗谷种子"), NotePreset("小麦种子"),
        NotePreset("绿豆种子", group: .bean), NotePreset("西瓜种子"), NotePreset("辣椒种子"),
        NotePreset("雪绯花种子"), NotePreset("大麦种子"),
        NotePreset("红豆种子", group: .bean), NotePreset("豆薯种子"), NotePreset("枸杞种子"),
        NotePreset("甘蓝种子"), NotePreset("山菊种子"),
        NotePreset("蚕豆种子", group: .bean), NotePreset("冬瓜种子"), NotePreset("土豆种子"),
        NotePreset("青桑种子"), NotePreset("燕麦种子"), NotePreset("豌豆种子")
    ]

    /// 树苗预选值（第二行），名贵组高亮
    static let seedlings: [NotePreset] = [
        NotePreset("乌木树苗"), NotePreset("金丝楠树苗"), NotePreset("黄花梨树苗"),
        NotePreset("小叶紫檀树苗"), NotePreset("奇楠沉香树苗", group: .sandalwood),
        NotePreset("枣树苗"), NotePreset("桃树苗"), NotePreset("黄杨树苗"), NotePreset("桑树苗"),
        NotePreset("麻梨树苗", group: .sandalwood), NotePreset("鸡翅树苗"), NotePreset("黄檀树苗"),
        NotePreset("大红酸枝苗"), NotePreset("老山檀树苗", group: .sandalwood), NotePreset("崖柏树苗")
    ]

    /// 给定预选文本，返回其所属分组（nil = 普通项，不高亮）
    static func groupOf(_ text: String) -> NotePresetGroup? {
        for p in seeds + seedlings where p.id == text {
            return p.group
        }
        return nil
    }

    /// 备注渲染：按「、」拆词，命中分组的词用组色 + ● 色点，其余保持灰色。
    /// 返回单段 Text（内部是 AttributedString），调用方可自由设置字体与 lineLimit。
    static func highlighted(_ note: String) -> Text {
        var result = AttributedString()
        let tokens = note.components(separatedBy: "、")
        for i in tokens.indices {
            let t = tokens[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if let g = groupOf(t) {
                var dot = AttributedString("●")
                dot.foregroundColor = g.color
                var word = AttributedString(t)
                word.foregroundColor = g.color
                result += dot
                result += AttributedString(" ")
                result += word
            } else {
                var word = AttributedString(t)
                word.foregroundColor = .secondary
                result += word
            }
            if i < tokens.count - 1 {
                var sep = AttributedString("、")
                sep.foregroundColor = .secondary
                result += sep
            }
        }
        return Text(result)
    }

    /// 记录列表里的备注按类别拆成两行：种子在第一行，树苗在第二行。
    /// 未识别的自由文本保留在第一行；没有任何预选标签时原样显示。
    static func recordRows(for note: String) -> [String] {
        let delimiters = CharacterSet(charactersIn: "、，,;；。")
        let tokens = note.components(separatedBy: delimiters)
            .flatMap { $0.components(separatedBy: .whitespacesAndNewlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let seedIDs = Set(seeds.flatMap {
            [$0.id, $0.id.replacingOccurrences(of: "种子", with: "")]
        } + ["雪菲花"])
        let seedlingIDs = Set(seedlings.flatMap {
            [
                $0.id,
                $0.id.replacingOccurrences(of: "树苗", with: "")
                    .replacingOccurrences(of: "苗", with: "")
            ]
        } + ["老山颤"])
        let hasPreset = tokens.contains { seedIDs.contains($0) || seedlingIDs.contains($0) }
        guard hasPreset else { return [note] }

        let seedAndOtherTokens = tokens.filter { !seedlingIDs.contains($0) }
        let seedlingTokens = tokens.filter { seedlingIDs.contains($0) }
        return [
            seedAndOtherTokens.joined(separator: "、"),
            seedlingTokens.joined(separator: "、")
        ]
        .filter { !$0.isEmpty }
    }
}

/// 收菜记录中的备注按「种子 / 树苗」分成两行，并沿用分组高亮。
struct NotePresetRecordNote: View {
    let note: String

    private var rows: [String] {
        NotePresets.recordRows(for: note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(rows.indices, id: \.self) { index in
                NotePresets.highlighted(rows[index])
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

// MARK: - 时间格式化（主 App 与 Widget 共用，保证两端展示一致）

/// 收菜时间统一格式：MM-dd HH:mm（与 App 记录行一致）
func fmt(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    return f.string(from: d)
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

/// 按记录倒计时：有多次采收时对准「下一茬」而不是首次，
/// 否则首次过了之后会永远停在 00:00，看不出还要等多久收第二茬。
func remainText(_ r: CropRecord) -> String {
    guard let next = r.nextHarvest else { return "可收获" }
    return remainText(next)
}

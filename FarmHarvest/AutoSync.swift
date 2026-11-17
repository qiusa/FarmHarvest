import Foundation
import os.log
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 自动同步：本地任何改动后防抖触发，拉取服务器最新备份，
/// 按「本地改过的以本地为准，没改的以服务器最新为准」合并，写回本地并上传。
/// 只被 macOS 与 iOS 主 App 编译，Widget 不含此文件。
enum AutoSync {
    private static let log = Logger(subsystem: "com.yixin.farmharvest", category: "AutoSync")
    private static let engine = Engine()
    private static var started = false

    /// 主 App 启动时调用一次：监听数据变更、回前台，并定时拉取服务器更新。
    static func start() {
        guard !started else { return }
        started = true

        NotificationCenter.default.addObserver(
            forName: CropStore.dataDidChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { await engine.schedule() }
        }

        #if os(macOS)
        let didBecomeActive = NSApplication.didBecomeActiveNotification
        #else
        let didBecomeActive = UIApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: didBecomeActive, object: nil, queue: .main) { _ in
            Task { await engine.schedule(delay: 1) }
        }

        // App 常驻前台时，别的设备可能改了数据：定时拉取保持未改数据最新
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { await engine.schedule(delay: 0) }
        }

        Task { await engine.schedule(delay: 1) }
    }

    // MARK: - 合并规则（纯函数，便于离线验证）

    /// 以服务器备份为基底：脏 id 用本地版本覆盖/追加，本地已删的脏 id 从基底移除；
    /// 未脏的记录一律采用服务器版本（服务器没有 = 别的设备删了，本地跟随删除）。
    static func mergedBackup(
        base: CropStore.Backup,
        localRecords: [CropRecord],
        localCrops: [CropPreset],
        localHidden: Set<String>,
        changes: CropStore.SyncChangeState
    ) -> CropStore.Backup {
        var records = base.records
        let localByID = Dictionary(localRecords.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in changes.dirtyRecordIDs {
            records.removeAll { $0.id == id }
            if let local = localByID[id] {
                records.append(local)
            }
        }
        records.sort { $0.plantedAt > $1.plantedAt }

        var merged = base
        merged.records = records
        merged.customCrops = changes.customCropsDirty ? localCrops : base.customCrops
        merged.hiddenBuiltins = changes.hiddenBuiltinsDirty ? Array(localHidden).sorted() : base.hiddenBuiltins
        return merged
    }

    /// 内容是否一致（忽略 exportedAt 与数组顺序），用于跳过无意义的覆盖上传
    static func sameContent(_ a: CropStore.Backup, _ b: CropStore.Backup) -> Bool {
        let ar = Dictionary(a.records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let br = Dictionary(b.records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let ac = Dictionary(a.customCrops.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let bc = Dictionary(b.customCrops.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return ar == br && ac == bc && Set(a.hiddenBuiltins) == Set(b.hiddenBuiltins)
    }

    // MARK: - 网络

    private enum FetchResult {
        case backup(CropStore.Backup)
        case notFound
        case failed
    }

    private static func fetch() async -> FetchResult {
        guard let url = URL(string: BuildManagerBackupUploader.backupURLString) else { return .failed }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 404 { return .notFound }
            guard (200..<300).contains(http.statusCode), data.count <= 10 * 1024 * 1024 else {
                log.error("拉取备份失败：HTTP \(http.statusCode)")
                return .failed
            }
            guard let backup = try? CropStore.decodeBackup(from: data) else {
                log.error("拉取备份失败：内容无法解析")
                return .failed
            }
            return .backup(backup)
        } catch {
            log.error("拉取备份失败：\(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    private static func upload(data: Data) async -> Bool {
        do {
            _ = try await BuildManagerBackupUploader.uploadBackup(data: data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: CropStore.lastSuccessfulBuildManagerUploadTimestampKey)
            log.info("自动同步上传成功")
            return true
        } catch {
            log.error("自动同步上传失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - 调度与执行

    private actor Engine {
        private var debounceTask: Task<Void, Never>?
        private var running = false
        private var needsRerun = false

        func schedule(delay: TimeInterval = 2) {
            debounceTask?.cancel()
            debounceTask = Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                await self?.run()
            }
        }

        private func run() async {
            if running {
                needsRerun = true
                return
            }
            running = true
            await syncOnce()
            running = false
            if needsRerun {
                needsRerun = false
                schedule(delay: 1)
            }
        }

        private func syncOnce() async {
            let state = CropStore.loadSyncChangeState()
            let localRecords = CropStore.load()
            let localCrops = CropStore.customCrops()
            let localHidden = CropStore.hiddenBuiltinIDs
            let localSnapshot = CropStore.Backup(
                records: localRecords,
                customCrops: localCrops,
                hiddenBuiltins: Array(localHidden).sorted()
            )

            let merged: CropStore.Backup
            var needsUpload: Bool
            switch await AutoSync.fetch() {
            case .backup(let base):
                merged = AutoSync.mergedBackup(
                    base: base,
                    localRecords: localRecords,
                    localCrops: localCrops,
                    localHidden: localHidden,
                    changes: state
                )
                needsUpload = !AutoSync.sameContent(merged, base)
            case .notFound:
                // 服务器可达但没有备份文件：用本地数据重新播种，不做合并删除
                merged = localSnapshot
                needsUpload = true
            case .failed:
                // 服务器不可达：不动本地数据，等下次触发再试
                AutoSync.log.error("服务器不可达，跳过本轮自动同步")
                return
            }

            // 拉取期间本地又有新改动：本轮结果作废，交给防抖后的下一轮
            guard CropStore.loadSyncChangeState().revision == state.revision else {
                schedule(delay: 1)
                return
            }

            if !AutoSync.sameContent(merged, localSnapshot) {
                CropStore.applySyncedData(
                    records: merged.records,
                    customCrops: merged.customCrops,
                    hiddenBuiltins: Set(merged.hiddenBuiltins)
                )
            }

            var anySuccess = !needsUpload
            if needsUpload {
                var toUpload = merged
                toUpload.exportedAt = Date()
                guard let data = try? CropStore.encodeBackup(toUpload) else {
                    AutoSync.log.error("合并结果编码失败，跳过上传")
                    return
                }
                anySuccess = await AutoSync.upload(data: data)
            }

            if anySuccess {
                CropStore.clearSyncChanges(matchingRevision: state.revision)
            }
        }
    }
}
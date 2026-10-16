import AppIntents
import Foundation
import os.log

enum WidgetPageNavigation {
    static let pageIndexKey = "FarmHarvestWidget.pageIndex"
    private static let stateFileName = "FarmHarvestWidget.page-index"
    private static let stateLock = NSLock()
    private static let logger = Logger(
        subsystem: "com.yixin.farmharvest",
        category: "WidgetPageNavigation"
    )

    static var currentPageIndex: Int {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CropStore.appGroup
        ) else {
            logger.error("Cannot open App Group container: \(CropStore.appGroup, privacy: .public)")
            return UserDefaults(suiteName: CropStore.appGroup)?.integer(forKey: pageIndexKey) ?? 0
        }

        return readPageIndex(in: container)
    }

    static func move(by amount: Int) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: CropStore.appGroup
        ) else {
            logger.error("Cannot open App Group container: \(CropStore.appGroup, privacy: .public)")
            throw WidgetPageNavigationError.sharedContainerUnavailable
        }

        // AppIntents may service rapid widget taps on separate tasks. Serialize
        // the read/modify/write so two taps cannot overwrite each other's page.
        stateLock.lock()
        defer { stateLock.unlock() }

        let nextPage = readPageIndex(in: container) + amount
        let stateURL = container.appendingPathComponent(stateFileName, isDirectory: false)
        do {
            try Data(String(nextPage).utf8).write(to: stateURL, options: .atomic)
        } catch {
            logger.error("Cannot save widget page index: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        logger.info("Changed widget page to \(nextPage, privacy: .public)")
        // WidgetKit automatically requests a new timeline after an interactive
        // widget intent completes. Requesting another reload here races that
        // interaction reload and can leave the current entry paused/stale.
    }

    private static func readPageIndex(in container: URL) -> Int {
        let stateURL = container.appendingPathComponent(stateFileName, isDirectory: false)
        if let data = try? Data(contentsOf: stateURL),
           let value = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }

        // Migrate the value written by earlier builds the first time the
        // shared file is used.
        return UserDefaults(suiteName: CropStore.appGroup)?.integer(forKey: pageIndexKey) ?? 0
    }
}

private enum WidgetPageNavigationError: Error {
    case sharedContainerUnavailable
}

/// Separate parameterless intents avoid runtime parameter resolution in the widget process.
struct PreviousWidgetPageIntent: AppIntent {
    static var title: LocalizedStringResource = "上一页提醒记录"

    @available(macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    func perform() async throws -> some IntentResult {
        try WidgetPageNavigation.move(by: -1)
        return .result()
    }
}

struct NextWidgetPageIntent: AppIntent {
    static var title: LocalizedStringResource = "下一页提醒记录"

    @available(macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    func perform() async throws -> some IntentResult {
        try WidgetPageNavigation.move(by: 1)
        return .result()
    }
}

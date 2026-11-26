import Foundation
import Observation
import ThunderCore
import ThunderSession

/// 把手機錄的場次交給 Mac（DESIGN.md 5.10 節，D36）：停止之後在手機上做結束處理的步驟 1–4（做到合併錄音），
/// 再放進收件匣（`SessionHandoff.export`），放好之後刪掉手機上的那一份；Mac 收走之後收件匣裡就沒有了。
///
/// 收件匣在這個 App 自己的 iCloud 空間（container）裡（D37）：使用者不用選資料夾，也看不到它。
/// 這支 iPhone 沒有登入 iCloud、或關掉了 iCloud 雲碟時，以及交不出去時，場次留在手機上，下次打開 App 或回到前景時再試。
@MainActor
@Observable
final class PhoneHandoff {
    /// 一場的狀態。
    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            /// 還在手機上（還沒選收件匣、還在收尾、或交不出去）。
            case onPhone
            /// 已經放進收件匣，等 Mac 收走。
            case inInbox
            /// Mac 已經收走了。
            case collected
        }

        var id: UUID
        var startedAt: Date
        var durationSeconds: Double
        var state: State
    }

    /// 交出去的場次（給清單用；手機上的那一份已經刪了）。
    struct Record: Codable, Equatable {
        var id: UUID
        var startedAt: Date
        var durationSeconds: Double
    }

    private(set) var items: [Item] = []
    /// iCloud 能不能用（收件匣在不在）；還沒看過是 nil。
    private(set) var inboxAvailable: Bool?
    /// 最近一次交接失敗的原因（給畫面說明）。
    private(set) var problem: String?
    /// 要告訴使用者的事（例如上次的錄音沒有正常結束，已經收尾）。畫面顯示之後清掉。
    var notice: String?

    @ObservationIgnored private var processing = false

    private static let recordsKey = "handedOffSessions"
    /// 清單最多記幾場交出去的。
    private static let recordLimit = 50

    init() {
        // 舊版（D36）記下的、使用者選的收件匣：改用 App 自己的 iCloud 空間之後不用了
        UserDefaults.standard.removeObject(forKey: "inboxBookmark")
    }

    /// 錄音中的場次放在這裡（App 自己的資料夾，不在「檔案」App 裡，也不備份到 iCloud）。
    nonisolated static var workingRoot: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Working", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = root
        try? url.setResourceValues(values)
        return root
    }

    // MARK: 收件匣

    /// iCloud 不能用時的說明。
    static let unavailable = "這支 iPhone 沒有登入 iCloud，或關掉了 iCloud 雲碟：錄好的場次先留在手機上，iCloud 能用之後會自動交給 Mac。"

    /// 收件匣的位置：App 自己的 iCloud container 裡的 `Inbox/`，沒有就建立。iCloud 不能用時是 nil。
    /// 第一次可能要等一下（系統要先準備 container），不要在主執行緒上呼叫。
    /// 自動測試用 `-selfTestInbox <資料夾>` 換成 App 自己資料夾裡的一個資料夾（模擬器沒有 iCloud）。
    nonisolated static func inboxLocation() -> URL? {
        if let path = UserDefaults.standard.string(forKey: "selfTestInbox") { return URL(fileURLWithPath: path) }
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: SessionHandoff.containerIdentifier)
        else { return nil }
        let inbox = SessionHandoff.inbox(inContainer: container)
        if !FileManager.default.fileExists(atPath: inbox.path) {
            // iCloud 的 container 裡要協調著寫，iCloud 才知道有新的資料夾
            var coordinationError: NSError?
            var createError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: inbox, options: [], error: &coordinationError) { url in
                do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) } catch { createError = error }
            }
            if coordinationError != nil || createError != nil { return nil }
        }
        return inbox
    }

    // MARK: 交接

    /// 按停止之後：做到合併錄音、交到收件匣。
    func finish(_ directory: SessionDirectory) async {
        await processPending()
    }

    /// 把留在手機上的場次交出去：上次沒有正常結束的（App 被關掉）先收尾，沒做完結束處理的做到合併錄音，
    /// 有收件匣就交出去，交好就刪掉手機上的那一份。錄音中的那一場有鎖，不會被動到。
    func processPending() async {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        let working = Self.workingRoot
        let (outcome, available) = await Task.detached(priority: .utility) { () -> (Outcome, Bool) in
            let inbox = Self.inboxLocation()
            return (await Self.handOff(working: working, inbox: inbox), inbox != nil)
        }.value
        inboxAvailable = available
        if !outcome.handedOff.isEmpty { remember(outcome.handedOff) }
        problem = outcome.problems.first ?? (available ? nil : Self.unavailable)
        if outcome.recovered > 0 {
            notice = "上次的錄音沒有正常結束（App 被關掉了）。已經收尾，錄到的部分都在。"
        }
        await refresh()
    }

    private struct Outcome: Sendable {
        var handedOff: [Record] = []
        var problems: [String] = []
        var recovered = 0
    }

    nonisolated private static func handOff(working: URL, inbox: URL?) async -> Outcome {
        var outcome = Outcome()
        // 上次沒有正常結束的場次：照當機復原收尾（手機不能「接著錄同一場」，所以不問）
        for interrupted in (try? SessionRecovery.findInterrupted(in: working)) ?? [] {
            if (try? SessionRecovery.recover(interrupted)) != nil { outcome.recovered += 1 }
        }
        var options = FinalizationOptions(libraryRoot: working)
        options.lastStep = .audio
        options.summarize = false
        let finalizer = SessionFinalizer(options: options)
        for item in SessionLibrary.list(root: working) where item.meta.state != .recording {
            do {
                try await finalizer.finalize(item.directory)
            } catch {
                outcome.problems.append("收尾失敗（\(error)），下次打開時再試")
                continue
            }
            guard let inbox else { continue }
            do {
                let meta = try item.directory.loadMeta()
                try SessionHandoff.export(item.directory, to: inbox)
                try FileManager.default.removeItem(at: item.directory.url)
                outcome.handedOff.append(Record(id: meta.id, startedAt: meta.startedAt, durationSeconds: meta.durationSeconds))
            } catch {
                outcome.problems.append("交不到收件匣（\(error)），留在手機上，下次打開時再試")
            }
        }
        return outcome
    }

    /// 重新整理清單：手機上的場次，加上交出去的場次（收件匣裡還有就是「等 Mac 收」，沒有了就是「Mac 已收走」）。
    func refresh() async {
        let working = Self.workingRoot
        let records = loadRecords()
        let (local, waiting, available) = await Task.detached(priority: .utility) {
            () -> ([SessionLibrary.Item], Set<UUID>, Bool) in
            let local = SessionLibrary.list(root: working)
            guard let inbox = Self.inboxLocation() else { return (local, Set(records.map(\.id)), false) }
            let waiting = records.filter {
                FileManager.default.fileExists(atPath: inbox.appendingPathComponent($0.id.uuidString).path)
            }
            return (local, Set(waiting.map(\.id)), true)
        }.value
        inboxAvailable = available
        if !available, problem == nil { problem = Self.unavailable }
        if available, problem == Self.unavailable { problem = nil }
        var list = local.map {
            Item(id: $0.id, startedAt: $0.meta.startedAt, durationSeconds: $0.meta.durationSeconds, state: .onPhone)
        }
        let localIDs = Set(list.map(\.id))
        for record in records where !localIDs.contains(record.id) {
            list.append(
                Item(
                    id: record.id, startedAt: record.startedAt, durationSeconds: record.durationSeconds,
                    state: waiting.contains(record.id) ? .inInbox : .collected))
        }
        list.sort { $0.startedAt > $1.startedAt }
        items = list
    }

    private func loadRecords() -> [Record] {
        guard let data = UserDefaults.standard.data(forKey: Self.recordsKey) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private func remember(_ handedOff: [Record]) {
        var records = loadRecords().filter { record in !handedOff.contains { $0.id == record.id } } + handedOff
        records.sort { $0.startedAt > $1.startedAt }
        if let data = try? JSONEncoder().encode(Array(records.prefix(Self.recordLimit))) {
            UserDefaults.standard.set(data, forKey: Self.recordsKey)
        }
    }

    /// 自動測試印出來的交接結果。
    func report() -> [String] {
        var lines = ["handoff: inbox=\(inboxAvailable == true ? "ok" : "-") items=\(items.map { "\($0.state)" }.joined(separator: ","))"]
        if let problem { lines.append("handoff: problem=\(problem)") }
        return lines
    }
}

import Foundation
import Observation
import ThunderCore
import ThunderSession

/// 把手機錄的場次交給 Mac（DESIGN.md 5.10 節，D36）：停止之後在手機上做結束處理的步驟 1–4（做到合併錄音），
/// 再放進 iCloud 雲碟裡的收件匣（`SessionHandoff.export`），放好之後刪掉手機上的那一份；Mac 收走之後收件匣裡就沒有了。
///
/// 收件匣是使用者用系統的資料夾選擇器選的（不需要 iCloud 的 entitlement），記成 bookmark，每次用的時候再取得一次權限。
/// 還沒選收件匣、或交不出去時，場次留在手機上，下次打開 App 或回到前景時再試。
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
    /// 收件匣資料夾的名稱（給畫面看）；還沒選是 nil。
    private(set) var inboxName: String?
    /// 最近一次交接失敗的原因（給畫面說明）。
    private(set) var problem: String?
    /// 要告訴使用者的事（例如上次的錄音沒有正常結束，已經收尾）。畫面顯示之後清掉。
    var notice: String?

    @ObservationIgnored private var processing = false

    private static let bookmarkKey = "inboxBookmark"
    private static let recordsKey = "handedOffSessions"
    /// 清單最多記幾場交出去的。
    private static let recordLimit = 50

    init() {
        inboxName = resolveInbox()?.lastPathComponent
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

    /// 使用者選了收件匣（系統的資料夾選擇器給的網址）：記成 bookmark，接著把留在手機上的場次交出去。
    func chooseInbox(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData()
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            inboxName = url.lastPathComponent
            problem = nil
        } catch {
            problem = "記不住這個資料夾（\(error.localizedDescription)）。請再選一次。"
        }
        Task { await refresh() }
    }

    /// 收件匣的位置；還沒選、或找不到了是 nil。用之前要 `startAccessingSecurityScopedResource()`。
    /// 自動測試用 `-selfTestInbox <資料夾>` 換成 App 自己資料夾裡的一個資料夾。
    func resolveInbox() -> URL? {
        if let path = UserDefaults.standard.string(forKey: "selfTestInbox") { return URL(fileURLWithPath: path) }
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey) }
        return url
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
        let inbox = resolveInbox()
        let outcome = await Task.detached(priority: .utility) { await Self.handOff(working: working, inbox: inbox) }.value
        if !outcome.handedOff.isEmpty { remember(outcome.handedOff) }
        problem = outcome.problems.first
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
        let scoped = inbox?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { inbox?.stopAccessingSecurityScopedResource() } }
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
        inboxName = resolveInbox()?.lastPathComponent
        let working = Self.workingRoot
        let inbox = resolveInbox()
        let records = loadRecords()
        let (local, waiting) = await Task.detached(priority: .utility) { () -> ([SessionLibrary.Item], Set<UUID>) in
            let local = SessionLibrary.list(root: working)
            guard let inbox else { return (local, Set(records.map(\.id))) }
            let scoped = inbox.startAccessingSecurityScopedResource()
            defer { if scoped { inbox.stopAccessingSecurityScopedResource() } }
            let waiting = records.filter {
                FileManager.default.fileExists(atPath: inbox.appendingPathComponent($0.id.uuidString).path)
            }
            return (local, Set(waiting.map(\.id)))
        }.value
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
        var lines = ["handoff: inbox=\(inboxName ?? "-") items=\(items.map { "\($0.state)" }.joined(separator: ","))"]
        if let problem { lines.append("handoff: problem=\(problem)") }
        return lines
    }
}

import Foundation
import Observation
import ThunderCore
import ThunderSession

/// 把手機錄的場次交給 Mac（DESIGN.md 5.10 節，D36）：停止之後在手機上做結束處理的步驟 1–4，
/// 再放進 iCloud 雲碟裡的收件匣；Mac 收走之後收件匣裡就沒有了。
///
/// 收件匣是使用者用系統的資料夾選擇器選的（不需要 iCloud 的 entitlement），記成 bookmark，
/// 每次用的時候再取得一次權限。
@MainActor
@Observable
final class PhoneHandoff {
    /// 一場在手機上的狀態。
    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            /// 還在手機上（還沒選收件匣、或放進收件匣失敗）。
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

    private(set) var items: [Item] = []
    /// 收件匣資料夾的名稱（給畫面看）；還沒選是 nil。
    private(set) var inboxName: String?
    /// 最近一次交接失敗的原因（給畫面說明）。
    private(set) var problem: String?

    private static let bookmarkKey = "inboxBookmark"
    private static let handedOffKey = "handedOffSessions"

    init() {
        inboxName = resolveInbox()?.lastPathComponent
    }

    /// 錄音中的場次放在這裡（App 自己的資料夾，不在「檔案」App 裡，也不備份到 iCloud）。
    static var workingRoot: URL {
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

    /// 使用者選了收件匣（系統的資料夾選擇器給的網址）：記成 bookmark。
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
    func resolveInbox() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey) }
        return url
    }

    // MARK: 交接

    /// 按停止之後：做結束處理的步驟 1–4，放進收件匣。
    func finish(_ directory: SessionDirectory) async {
        problem = nil
        await refresh()
    }

    /// 重新整理清單：手機上的場次，加上交給收件匣、還沒被 Mac 收走的場次。
    func refresh() async {
        let working = PhoneHandoff.workingRoot
        let local = await Task.detached { SessionLibrary.list(root: working) }.value
        var list = local.map {
            Item(id: $0.id, startedAt: $0.meta.startedAt, durationSeconds: $0.meta.durationSeconds, state: .onPhone)
        }
        list.sort { $0.startedAt > $1.startedAt }
        items = list
    }

    /// 自動測試印出來的交接結果。
    func report() -> [String] {
        ["handoff: inbox=\(inboxName ?? "-") items=\(items.map { "\($0.state)" }.joined(separator: ","))"]
    }
}

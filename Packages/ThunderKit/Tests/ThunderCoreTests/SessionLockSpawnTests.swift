import Darwin
import Foundation
import Synchronization
import Testing
import ThunderCore
import ThunderTestKit

/// 子程式不會多拿一下鎖：別的執行緒啟動外部程式（例如 workshop-archive）的那一瞬間，子程式會拿到程式裡所有描述子的複本，
/// 只設 close-on-exec 的話要等它 exec 才關掉。這段時間裡剛放掉的鎖還在，馬上再拿就會被誤報「這一場正在處理中」
/// （2026-11-25 找到：另一條執行緒不停啟動 `/usr/bin/true` 時，20,000 次裡失敗 273 次）。
@Suite("SessionLock：別的執行緒正在啟動外部程式時")
struct SessionLockSpawnTests {
    /// 在自己的執行緒上不停啟動 `/usr/bin/true` 並等它結束（不占用 Swift concurrency 的執行緒）。
    private final class Spawner: Sendable {
        let count = Atomic<Int>(0)
        private let stopping = Atomic<Bool>(false)
        private let finished = DispatchSemaphore(value: 0)

        func start() {
            Thread { [self] in
                let path = "/usr/bin/true"
                let argument = strdup(path)
                defer { free(argument) }
                var argv: [UnsafeMutablePointer<CChar>?] = [argument, nil]
                var envp: [UnsafeMutablePointer<CChar>?] = [nil]
                while !stopping.load(ordering: .relaxed) {
                    var pid: pid_t = 0
                    if posix_spawn(&pid, path, nil, nil, &argv, &envp) == 0 {
                        var status: Int32 = 0
                        _ = waitpid(pid, &status, 0)
                        count.add(1, ordering: .relaxed)
                    }
                }
                finished.signal()
            }.start()
        }

        func stop() {
            stopping.store(true, ordering: .relaxed)
            _ = finished.wait(timeout: .now() + 5)
        }
    }

    @Test("放掉的鎖馬上就拿得到，查詢也回答沒有人持有：啟動中的子程式不會多拿一下")
    func releaseIsImmediateWhileSpawning() throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let directory = SessionDirectory(url: tmp.url.appendingPathComponent("session", isDirectory: true))
        try directory.create()

        let spawner = Spawner()
        spawner.start()
        defer { spawner.stop() }

        var rounds = 0
        var missed = 0
        let deadline = ContinuousClock.now + .seconds(3)
        // 跨過幾百次啟動子程式，或到時限為止
        while spawner.count.load(ordering: .relaxed) < 400, ContinuousClock.now < deadline {
            rounds += 1
            guard let lock = try SessionLock.acquire(directory) else {
                missed += 1
                continue
            }
            lock.release()
            if SessionLock.isHeld(directory) { missed += 1 }
        }
        #expect(spawner.count.load(ordering: .relaxed) >= 50, "子程式要真的一直在啟動，這個測試才有意義")
        #expect(missed == 0, "\(rounds) 次裡有 \(missed) 次，剛放掉的鎖還被占著")
    }
}

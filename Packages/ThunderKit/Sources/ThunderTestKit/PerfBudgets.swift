import Foundation

/// 效能預算：全專案只有一份，放在 repo 根目錄的 `Benchmarks/perf-budgets.json`。
///
/// 預算以參考機器（M1 Max、release 模式）為準。比較慢的機器（例如共用的 CI）
/// 用環境變數 `THUNDER_PERF_FACTOR` 放寬：上限型預算乘上它，下限型預算除以它。
public struct PerfBudgets: Sendable {
    public struct MissingBudget: Error, CustomStringConvertible {
        public let key: String
        public var description: String { "perf-budgets.json 裡找不到預算「\(key)」" }
    }

    public struct BudgetFileNotFound: Error, CustomStringConvertible {
        public let startedFrom: String
        public var description: String { "從 \(startedFrom) 往上找不到 Benchmarks/perf-budgets.json" }
    }

    public static let factorEnvironmentVariable = "THUNDER_PERF_FACTOR"
    public static let relativePath = "Benchmarks/perf-budgets.json"

    public let factor: Double
    public let values: [String: Double]

    public init(values: [String: Double], factor: Double = 1) {
        self.values = values
        self.factor = factor
    }

    /// 從呼叫端的原始檔位置往上找預算檔並載入。
    public static func load(near sourceFile: String = #filePath) throws -> PerfBudgets {
        var directory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try load(from: candidate)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw BudgetFileNotFound(startedFrom: sourceFile)
    }

    public static func load(from url: URL) throws -> PerfBudgets {
        struct File: Decodable {
            struct Budget: Decodable { var value: Double }
            var budgets: [String: Budget]
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        let factor = ProcessInfo.processInfo.environment[factorEnvironmentVariable].flatMap(Double.init) ?? 1
        return PerfBudgets(values: file.budgets.mapValues(\.value), factor: max(factor, 1))
    }

    /// 上限型預算（時間、記憶體）：不可以超過這個值。
    public func maximum(_ key: String) throws -> Double {
        guard let value = values[key] else { throw MissingBudget(key: key) }
        return value * factor
    }

    /// 下限型預算（處理速度）：至少要有這個值。
    public func minimum(_ key: String) throws -> Double {
        guard let value = values[key] else { throw MissingBudget(key: key) }
        return value / factor
    }
}

public enum Perf {
    /// 測試是不是以最佳化（release）模式編譯。效能預算只在這個模式下有意義。
    public static var isOptimizedBuild: Bool {
        #if DEBUG
            false
        #else
            true
        #endif
    }

    /// 執行 `body` 數次，回傳耗時的中位數。
    public static func measure(runs: Int = 5, _ body: () throws -> Void) rethrows -> Duration {
        var times: [Duration] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try body()
            times.append(ContinuousClock.now - start)
        }
        times.sort()
        return times[times.count / 2]
    }
}

extension Duration {
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

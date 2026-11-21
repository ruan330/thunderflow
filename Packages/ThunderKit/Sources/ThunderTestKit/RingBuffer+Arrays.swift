import ThunderAudio

/// 測試用的陣列版本，省去每次都寫 `withUnsafeBufferPointer`。
extension RingBuffer {
    @discardableResult
    public func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { write($0) }
    }

    /// 讀出最多 `maxCount` 個樣本。
    public func read(maxCount: Int) -> [Float] {
        var scratch = [Float](repeating: 0, count: maxCount)
        let count = scratch.withUnsafeMutableBufferPointer { read(into: $0) }
        return Array(scratch.prefix(count))
    }
}

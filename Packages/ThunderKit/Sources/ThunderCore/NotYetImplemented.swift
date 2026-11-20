/// 測試先行階段的佔位錯誤：介面已定、測試已寫，但實作還沒開始。
/// 里程碑完成時，程式碼裡不應該再有任何地方丟出這個錯誤。
public struct NotYetImplemented: Error, CustomStringConvertible {
    public let what: String

    public init(_ what: String) { self.what = what }

    public var description: String { "尚未實作：\(what)" }
}

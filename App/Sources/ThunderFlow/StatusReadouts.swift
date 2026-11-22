import AppKit
import Observation
import SwiftUI

// 狀態列上錄音中每 0.25 秒更新的時間、費用與音量（DESIGN.md 4.3 節）：AppKit 的小元件直接看著 `AppModel`，
// 顯示的字或亮起的格數真的變了才重畫，SwiftUI 不參與（HANDOVER.md P9：SwiftUI 每一次更新都要重算整個視窗的版面，
// 約 10 ms；這三個數字一秒更新四次）。外觀和原本的 SwiftUI 版一樣：時間與費用用 SF Mono（callout），
// 時間是主要文字色、費用是次要灰；音量是 12 格，亮暗直接換、不加動畫。顏色都從 `Theme` 來，系統色用會跟著
// 「增加對比」調整的動態顏色。讀螢幕軟體讀得到名稱與數值，但數值改變時不主動通知（一秒四次，會一直唸）。

/// 錄音的時間（SF Mono）。
struct ElapsedTime: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ReadoutText(model: model, color: .labelColor, label: "錄音時間", spoken: { "已錄 \($0)" }) {
            Format.duration($0.elapsed)
        }
    }
}

/// 預估費用（SF Mono、次要灰）。
struct CostEstimate: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 「約 $0.01」唸成「約 0.01 美元」
        ReadoutText(model: model, color: .secondaryLabelColor, label: "預估費用", spoken: { "\($0.replacingOccurrences(of: "$", with: "")) 美元" }) {
            Format.cost(audioSeconds: $0.elapsed, provisional: $0.settings.showsProvisional)
        }
    }
}

/// 音量：12 格。亮起的格子是磷光綠；超過 85% 時最上面亮起的那一格變黃，超過 95% 變紅。
struct LevelMeter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LevelMeterRepresentable(model: model)
    }
}

// MARK: - 文字

/// 一行會變的文字。寬度只有在字數變了才會變（數字等寬，例如滿一小時），那時才請 SwiftUI 重新排版。
private struct ReadoutText: View {
    let model: AppModel
    let color: NSColor
    /// 讀螢幕軟體唸的名稱，以及把顯示的字換成唸的數值。
    let label: String
    let spoken: @MainActor (String) -> String
    let text: @MainActor (AppModel) -> String
    /// 寬度改變的次數：改變了，SwiftUI 才會重新問大小。
    @State private var resizes = 0

    var body: some View {
        ReadoutTextRepresentable(
            model: model, color: color, label: label, spoken: spoken, text: text, resizes: resizes
        ) { resizes += 1 }
    }
}

private struct ReadoutTextRepresentable: NSViewRepresentable {
    let model: AppModel
    let color: NSColor
    let label: String
    let spoken: @MainActor (String) -> String
    let text: @MainActor (AppModel) -> String
    let resizes: Int
    let onResize: () -> Void

    func makeNSView(context: Context) -> ReadoutTextView {
        let view = ReadoutTextView(color: color, label: label, spoken: spoken, text: text)
        view.onResize = onResize
        view.start(model: model)
        return view
    }

    func updateNSView(_ view: ReadoutTextView, context: Context) {
        view.onResize = onResize
    }

    static func dismantleNSView(_ view: ReadoutTextView, coordinator: ()) {
        view.stop()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReadoutTextView, context: Context) -> CGSize? {
        // 和 SwiftUI 的 Text 一樣把寬度往上取到像素格（Retina 是 0.5 pt），旁邊的元件才會在同一個位置
        let scale = max(context.environment.displayScale, 1)
        return CGSize(width: ceil(nsView.textSize.width * scale) / scale, height: nsView.textSize.height)
    }
}

@MainActor
final class ReadoutTextView: NSView {
    private let font: NSFont
    private let color: NSColor
    private let spoken: @MainActor (String) -> String
    private let text: @MainActor (AppModel) -> String
    private weak var model: AppModel?
    private var observing = false
    private var shown = ""
    /// 目前這一行字的大小（SwiftUI 排版時問的）。
    private(set) var textSize = CGSize.zero
    var onResize: (() -> Void)?

    init(color: NSColor, label: String, spoken: @escaping @MainActor (String) -> String, text: @escaping @MainActor (AppModel) -> String) {
        // 和 `.font(.system(.callout, design: .monospaced))` 一樣：SF Mono、callout 的大小
        font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        self.color = color
        self.spoken = spoken
        self.text = text
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start(model: AppModel) {
        self.model = model
        observing = true
        observe()
    }

    func stop() {
        observing = false
    }

    /// 看著這一行字用到的值；值一變，就在這一輪的事件處理完之後更新一次。
    private func observe() {
        guard observing, let model else { return }
        let value = withObservationTracking {
            text(model)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        show(value)
    }

    private func show(_ value: String) {
        guard value != shown else { return }
        shown = value
        setAccessibilityValue(spoken(value))
        needsDisplay = true
        let size = NSSize(width: attributed.size().width, height: NSLayoutManager().defaultLineHeight(for: font))
        guard size != textSize else { return }
        let first = textSize == .zero
        textSize = size
        // 第一次的大小 SwiftUI 排版時會來問；之後變了才通知它。等這一輪做完再通知：可能正在 SwiftUI 更新畫面的途中
        if !first {
            Task { @MainActor [weak self] in self?.onResize?() }
        }
    }

    private var attributed: NSAttributedString {
        NSAttributedString(string: shown, attributes: [.font: font, .foregroundColor: color])
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 基線取整數，和 SwiftUI 的 Text 一樣（字幕區比對截圖得到的規則）。沒有 usesLineFragmentOrigin 時原點就是基線
        attributed.draw(with: NSRect(x: 0, y: font.ascender.rounded(), width: bounds.width, height: bounds.height), options: [])
    }
}

// MARK: - 音量

private struct LevelMeterRepresentable: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> LevelMeterView {
        let view = LevelMeterView()
        view.start(model: model)
        return view
    }

    func updateNSView(_ view: LevelMeterView, context: Context) {}

    static func dismantleNSView(_ view: LevelMeterView, coordinator: ()) {
        view.stop()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LevelMeterView, context: Context) -> CGSize? {
        LevelMeterView.size
    }
}

@MainActor
final class LevelMeterView: NSView {
    private static let bars = 12
    /// 每格 3 × 10 pt、間隔 2 pt。
    static let size = CGSize(width: CGFloat(bars) * 3 + CGFloat(bars - 1) * 2, height: 10)
    private static let bolt = NSColor(Theme.bolt)
    private static let peakColors = [bolt, NSColor(Theme.mark), NSColor(Theme.danger)]
    private weak var model: AppModel?
    private var observing = false
    /// 亮起幾格、最上面那一格的顏色（0 綠、1 黃、2 紅）。
    private var shown: (lit: Int, peak: Int) = (-1, -1)

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("音量")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { Self.size }

    func start(model: AppModel) {
        self.model = model
        observing = true
        observe()
    }

    func stop() {
        observing = false
    }

    private func observe() {
        guard observing, let model else { return }
        let level = withObservationTracking {
            model.level
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        show(level)
    }

    private func show(_ level: Float) {
        // 音量以分貝顯示才看得出變化：-50 dB 到 0 dB
        let decibels = 20 * log10(max(Double(level), 0.000_01))
        let fraction = min(1, max(0, (decibels + 50) / 50))
        let lit = Int((fraction * Double(Self.bars)).rounded())
        let peak = fraction > 0.95 ? 2 : fraction > 0.85 ? 1 : 0
        guard lit != shown.lit || peak != shown.peak else { return }
        shown = (lit, peak)
        setAccessibilityValue("\(Int(fraction * 100))%")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let peak = Self.peakColors[max(0, shown.peak)]
        for index in 0..<Self.bars {
            let color = index < shown.lit ? (index == shown.lit - 1 ? peak : Self.bolt) : NSColor.white.withAlphaComponent(0.1)
            color.setFill()
            let bar = NSRect(x: CGFloat(index) * 5, y: 0, width: 3, height: Self.size.height)
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
    }
}

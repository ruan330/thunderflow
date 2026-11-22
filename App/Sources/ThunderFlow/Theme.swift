import AppKit
import SwiftUI
import ThunderUI

/// 外觀（DESIGN.md 4.10 節）：顏色、動態、閃電的形狀、狀態的表示與按鈕的樣式。
///
/// 只自訂兩種顏色：墨黑與磷光綠（D28）。文字的灰階與狀態色用系統顏色，使用者打開「增加對比」時由系統調整。
/// 綠色只給正在運作或可以按的東西；品牌元素（閃電、即時燈、主要按鈕、時間碼）直接用 `bolt`，不經過系統強調色。
enum Theme {
    // MARK: 墨黑

    /// 墨黑 0：視窗與內容區的底。
    static let ink0 = Color(hex: 0x0C0D0B)
    /// 墨黑 1：抬高一層（狀態列、橫幅）。
    static let ink1 = Color(hex: 0x141612)
    /// 墨黑 2：控制項的底。
    static let ink2 = Color(hex: 0x1C1F1A)
    /// 墨黑 3：按下、選取。
    static let ink3 = Color(hex: 0x262A24)
    /// 1 px 的分隔線。
    static let hairline = Color.white.opacity(0.08)

    // MARK: 磷光綠

    static let bolt = Color(hex: 0xA6F24A)
    /// 滑過、圖示的高光。
    static let boltHighlight = Color(hex: 0xC8F78F)
    /// 主要按鈕按下時。
    static let boltPressed = Color(hex: 0x8BCB3E)
    /// 開關開啟、綠色標籤的底。
    static let boltWash = bolt.opacity(0.15)
    /// 綠色底上的字：一律用深色（白字在磷光綠上只有 1.4 : 1）。
    static let onBolt = ink0

    // MARK: 文字與狀態（系統顏色）

    /// 正在說的那一行英文：白 45%，在墨黑 0 上 4.5 : 1。
    static let speaking = Color.white.opacity(0.45)
    /// 錄音中。
    static let recording = Color(nsColor: .systemRed)
    /// 出了問題：翻譯停止、處理步驟失敗。
    static let danger = Color(nsColor: .systemRed)
    /// 要留意：暫停、翻譯連線中、已復原、橫幅。
    static let attention = Color(nsColor: .systemOrange)
    /// 使用者的標記。
    static let mark = Color(nsColor: .systemYellow)

    /// 狀態的色調畫成的顏色（只畫在符號上）。
    static func color(for tone: IndicatorTone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .live: bolt
        case .recording: recording
        case .attention: attention
        case .danger: danger
        case .mark: mark
        }
    }

    // MARK: 動態

    /// 滑過與小變化：120 ms。按下不加動畫（0 ms）。
    static let quick = Animation.easeOut(duration: 0.12)
    /// 按鈕換狀態、提示出現與消失：200 ms。
    static let standard = Animation.easeInOut(duration: 0.2)
    /// 版面變化：280 ms，不回彈。
    static let layout = Animation.smooth(duration: 0.28)

    /// 會移動的轉場加上淡入淡出；使用者打開「減少動態效果」時只淡入淡出。
    static func transition(_ moving: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : moving.combined(with: .opacity)
    }
}

extension Color {
    /// sRGB 的 `0xRRGGBB`。
    fileprivate init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - 閃電

/// App 圖示上的那道閃電（DESIGN.md 4.10.2 節）：側邊欄的「即時翻譯」、翻譯狀態、空白狀態都用這個形狀。
///
/// 頂點取自圖示的 100 × 100 格子，外框（x 29.5–70.5、y 16–84）縮放到畫的範圍裡。
/// 寬高比是 41 : 68，畫的時候用 `aspectRatio(BoltShape.aspectRatio, contentMode: .fit)` 保持形狀。
struct BoltShape: Shape {
    /// 寬除以高。
    static let aspectRatio: CGFloat = 41.0 / 68.0

    private static let points: [CGPoint] = [
        CGPoint(x: 60.5, y: 16), CGPoint(x: 29.5, y: 55), CGPoint(x: 48.5, y: 55),
        CGPoint(x: 39.5, y: 84), CGPoint(x: 70.5, y: 45), CGPoint(x: 51.5, y: 45),
    ]
    private static let bounds = CGRect(x: 29.5, y: 16, width: 41, height: 68)

    func path(in rect: CGRect) -> Path {
        let bounds = Self.bounds
        var path = Path()
        path.addLines(
            Self.points.map { point in
                CGPoint(
                    x: rect.minX + (point.x - bounds.minX) / bounds.width * rect.width,
                    y: rect.minY + (point.y - bounds.minY) / bounds.height * rect.height)
            })
        path.closeSubpath()
        return path
    }
}

/// 劃掉的閃電：空心的閃電加一條斜線。斜線兩旁挖出一道縫，小尺寸也分得出線條。
private struct BoltSlash: View {
    var body: some View {
        ZStack {
            BoltShape().stroke(style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                .aspectRatio(BoltShape.aspectRatio, contentMode: .fit)
            Slash().stroke(style: StrokeStyle(lineWidth: 3.4, lineCap: .round)).blendMode(.destinationOut)
            Slash().stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        .compositingGroup()
    }

    private struct Slash: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.minY + rect.height * 0.08))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.maxY - rect.height * 0.08))
            return path
        }
    }
}

// MARK: - 狀態的表示

/// 一個狀態（`Indicator`）：符號加上文字（DESIGN.md 4.10.4 節）。色調只畫在符號上；文字是主要文字色，
/// 一般的狀態用次要灰。大小跟著字級走，例如清單裡用 `.font(.caption)`。
struct IndicatorView: View {
    let indicator: Indicator

    init(_ indicator: Indicator) {
        self.indicator = indicator
    }

    var body: some View {
        HStack(spacing: 5) {
            IndicatorSymbolView(symbol: indicator.symbol)
                .foregroundStyle(Theme.color(for: indicator.tone))
            Text(indicator.text)
                .foregroundStyle(indicator.tone == .neutral ? .secondary : .primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 狀態的符號。
struct IndicatorSymbolView: View {
    let symbol: IndicatorSymbol

    var body: some View {
        // 看不見的佔位符號決定大小：跟著字級走，而且每一種符號一樣寬，換狀態時旁邊的文字不會跳動
        Image(systemName: "circle.fill")
            .hidden()
            .overlay { glyph }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        switch symbol {
        case .dot: Circle().scaleEffect(0.6)
        case .pause: Image(systemName: "pause.fill")
        case .spinner: ProgressView().controlSize(.mini)
        case .bolt: BoltShape().aspectRatio(BoltShape.aspectRatio, contentMode: .fit)
        case .boltOutline:
            BoltShape().stroke(style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                .aspectRatio(BoltShape.aspectRatio, contentMode: .fit)
        case .boltSlash: BoltSlash()
        case .warning: Image(systemName: "exclamationmark.triangle.fill")
        case .recovered: Image(systemName: "arrow.uturn.backward")
        case .flag: Image(systemName: "flag.fill")
        }
    }
}

// MARK: - 按鈕

/// 按鈕的留白與圓角。`.controlSize(.small)` 以下是小按鈕（狀態列），其他是一般按鈕。
private struct ButtonMetrics {
    let horizontal: CGFloat
    let vertical: CGFloat
    let radius: CGFloat

    init(_ size: ControlSize) {
        switch size {
        case .mini, .small: (horizontal, vertical, radius) = (8, 3, 6)
        default: (horizontal, vertical, radius) = (14, 5, 8)
        }
    }
}

/// 主要按鈕（每頁只有一個）：磷光綠的底、深色的半粗體字（DESIGN.md 4.10.5 節）。
///
/// 按下的那一幀就變暗並縮到 98%（不加動畫），放開時才在 120 ms 內回來；拖出去放開就取消，和系統的按鈕一樣。
/// `isHeld` 讓按鈕維持按下的樣子：例如按下開始之後、「準備中」還沒出現之前。
struct PrimaryButtonStyle: ButtonStyle {
    var isHeld = false

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration, isHeld: isHeld)
    }
}

private struct PrimaryButton: View {
    let configuration: ButtonStyleConfiguration
    let isHeld: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed || isHeld
        let metrics = ButtonMetrics(controlSize)
        let shape = RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(Theme.onBolt)
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .background(pressed ? Theme.boltPressed : hovering && isEnabled ? Theme.boltHighlight : Theme.bolt, in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            // 按下的那一幀就變（不加動畫）；放開時才用動畫回來
            .animation(pressed ? nil : Theme.quick, value: pressed)
            .onHover { hovering = $0 }
            .animation(Theme.quick, value: hovering)
    }
}

/// 次要按鈕：墨黑 2 的底加 1 px 的框線；按下時換成墨黑 3 並縮到 98%。
/// `isOn` 是開關開啟的樣子（例如浮動字幕開著）：淡綠的底。圖示要不要變綠由內容自己決定。
/// `isHeld` 讓按鈕維持按下的樣子：例如按下停止之後、「收尾中」還沒出現之前。
struct NeutralButtonStyle: ButtonStyle {
    var isOn = false
    var isHeld = false

    func makeBody(configuration: Configuration) -> some View {
        NeutralButton(configuration: configuration, isOn: isOn, isHeld: isHeld)
    }
}

private struct NeutralButton: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    let isHeld: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    /// 滑過時稍微亮一點：墨黑 2 和墨黑 3 的中間。
    private static let hoverFill = Theme.ink2.mix(with: Theme.ink3, by: 0.5)
    private static let hoverWash = Theme.bolt.opacity(0.2)

    var body: some View {
        let pressed = configuration.isPressed || isHeld
        let metrics = ButtonMetrics(controlSize)
        let shape = RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
        let hover = hovering && isEnabled
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .background(
                pressed ? Theme.ink3 : isOn ? (hover ? Self.hoverWash : Theme.boltWash) : hover ? Self.hoverFill : Theme.ink2,
                in: shape
            )
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1 / max(displayScale, 1)))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            .animation(pressed ? nil : Theme.quick, value: pressed)
            .onHover { hovering = $0 }
            .animation(Theme.quick, value: hovering)
    }
}

// MARK: - 分隔線

/// 1 px 的分隔線（白 8%）。黑底上的層次靠明暗與這條線，不靠陰影。
struct Hairline: View {
    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let width = 1 / max(displayScale, 1)
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: axis == .vertical ? width : nil, height: axis == .horizontal ? width : nil)
            .accessibilityHidden(true)
    }
}

// MARK: - 字幕

extension View {
    /// 還在更新的那一行（暫定譯文、正在說的英文）：左邊一條 3 pt 的磷光綠線。
    /// 畫在字幕區左邊的留白裡，文字的位置不動。
    func updatingMarker() -> some View {
        overlay(alignment: .leading) {
            Capsule()
                .fill(Theme.bolt)
                .frame(width: 3)
                .offset(x: -12)
                .accessibilityHidden(true)
        }
    }
}

extension Text {
    /// 標記過重點的那一行：文字後面加一面小的黃色旗子，跟著文字換行。
    func flagged(_ marked: Bool, size: CGFloat) -> Text {
        guard marked else { return self }
        let flag = Text(Image(systemName: "flag.fill")).font(.system(size: size * 0.6)).foregroundStyle(Theme.mark)
        return Text("\(self) \(flag)")
    }
}

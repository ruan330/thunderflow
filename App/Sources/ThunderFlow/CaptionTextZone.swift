import AppKit
import Observation
import SwiftUI
import ThunderUI

// 字幕區（DESIGN.md 4.3 節）：每一區是 AppKit 的唯讀文字元件（TextKit 1），字幕每一次更新只改有變的段落，
// SwiftUI 不參與（HANDOVER.md P9：用 SwiftUI 畫字幕，每一次更新要花主執行緒約 20 ms）。
// 要改哪幾段由 ThunderUI 的 `CaptionZoneSync` 決定（有測試），這裡只把段落畫成文字。
// 外觀照 DESIGN.md 4.10.3、4.10.4 節，和原本的 SwiftUI 版一樣：行高與基線用系統字型的，
// 中文區行距約 1.45 倍，段落之間 10 pt，還在更新的段左邊一條綠線，標記的段後面一面黃色旗子。

/// 一區字幕：中文或英文。新的內容出現時捲到最下面；使用者往上捲之後就不再自動捲，並出現「回到最新」。
struct CaptionZone: View {
    @Environment(AppModel.self) private var model
    let style: CaptionZoneStyle
    @State private var pinned = true
    @State private var returnRequests = 0

    var body: some View {
        CaptionTextZone(model: model, style: style, returnRequests: returnRequests, pinned: $pinned)
            .overlay(alignment: .bottomTrailing) {
                if !pinned {
                    Button {
                        pinned = true
                        returnRequests += 1
                    } label: {
                        Label("回到最新", systemImage: "arrow.down")
                    }
                    .buttonStyle(NeutralButtonStyle())
                    .padding(12)
                }
            }
    }
}

/// 一區字幕的外觀。換了就整區重畫（很少發生：換字級、顯示模式、暫定譯文的開關）。
struct CaptionZoneStyle: Equatable {
    var title: String
    var options: CaptionZoneOptions
    var fontSize: CGFloat
    /// 同一段裡行與行之間多出來的距離（中文區是字級的 0.25 倍，行距約 1.45 倍）。
    var lineSpacing: CGFloat
}

private struct CaptionTextZone: NSViewRepresentable {
    let model: AppModel
    let style: CaptionZoneStyle
    let returnRequests: Int
    @Binding var pinned: Bool

    func makeCoordinator() -> CaptionZoneController {
        CaptionZoneController(model: model)
    }

    func makeNSView(context: Context) -> CaptionZoneView {
        let controller = context.coordinator
        controller.onPinnedChange = { pinned = $0 }
        controller.returnRequests = returnRequests
        controller.apply(style: style)
        controller.startObserving()
        return controller.view
    }

    func updateNSView(_ view: CaptionZoneView, context: Context) {
        let controller = context.coordinator
        controller.onPinnedChange = { pinned = $0 }
        controller.apply(style: style)
        if returnRequests != controller.returnRequests {
            controller.returnRequests = returnRequests
            controller.returnToLatest()
        }
    }

    static func dismantleNSView(_ view: CaptionZoneView, coordinator: CaptionZoneController) {
        coordinator.stopObserving()
    }
}

// MARK: - 更新

/// 看著字幕與標記，有變就算出要改的段落、改文字、捲到最新、擺好綠線。
@MainActor
final class CaptionZoneController {
    let view = CaptionZoneView()
    private weak var model: AppModel?
    private var style: CaptionZoneStyle?
    private var renderer: CaptionRenderer?
    private var sync = CaptionZoneSync()
    private var layout = CaptionTextLayout(headerLength: 0)
    private var observing = false
    /// 使用者在最下面附近：新的內容出現時自動捲到最下面。
    private var pinned = true
    var returnRequests = 0
    var onPinnedChange: ((Bool) -> Void)?

    init(model: AppModel) {
        self.model = model
        view.onResize = { [weak self] in self?.followLatest() }
        view.onLayout = { [weak self] in self?.followLatest() }
        view.onUserScroll = { [weak self] in self?.userScrolled() }
    }

    /// 換了外觀就整區重畫。
    func apply(style: CaptionZoneStyle) {
        guard style != self.style else { return }
        self.style = style
        let renderer = CaptionRenderer(style: style)
        self.renderer = renderer
        let storage = view.storage
        storage.beginEditing()
        storage.setAttributedString(renderer.title)
        storage.endEditing()
        layout = CaptionTextLayout(headerLength: storage.length)
        sync = CaptionZoneSync()
        view.markerRanges = []
        view.setAccessibilityTitle(style.title)
        refresh()
    }

    func startObserving() {
        guard !observing else { return }
        observing = true
        observe()
    }

    func stopObserving() {
        observing = false
    }

    /// 字幕或標記一有變，就在這一輪的事件處理完之後更新一次（同一輪裡的好幾個改變合成一次）。
    private func observe() {
        guard observing, let model else { return }
        withObservationTracking {
            _ = model.captions.board
            _ = model.markedLines
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    /// 照目前的字幕改文字。只改有變的段落：成本跟著改變的量，不跟著場次的長度。
    private func refresh() {
        guard let model, let style, let renderer else { return }
        let edits = sync.update(board: model.captions.board, marked: model.markedLines, options: style.options)
        guard !edits.isEmpty else { return }
        let storage = view.storage
        storage.beginEditing()
        for edit in edits {
            switch edit {
            case .set(let index, let paragraph):
                let content = renderer.render(paragraph)
                let change = layout.set(index, length: content.length)
                if change.insertsSeparator {
                    let text = NSMutableAttributedString(attributedString: renderer.separator)
                    text.append(content)
                    storage.replaceCharacters(in: NSRange(change.range), with: text)
                } else {
                    storage.replaceCharacters(in: NSRange(change.range), with: content)
                }
            case .truncate(let index):
                storage.deleteCharacters(in: NSRange(layout.truncate(index).range))
            }
        }
        storage.endEditing()
        view.markerRanges = sync.updating.sorted().map { NSRange(layout.range(of: $0)) }
        followLatest()
    }

    /// 「回到最新」：捲到最下面，之後新的內容出現時照樣自動捲。按鈕那邊已經記下了，這裡不再通知
    /// （這是在 SwiftUI 更新畫面的途中呼叫的，不可以在這時候改它的狀態）。
    func returnToLatest() {
        pinned = true
        view.scrollToBottom()
    }

    /// 內容變了、寬度變了，或排版補完了前面估計的高度：在看最新的就捲到最下面。
    private func followLatest() {
        if pinned { view.scrollToBottom() }
    }

    /// 使用者自己捲動（觸控板、滑鼠滾輪、拖捲軸）：離最下面 60 pt 以內算是在看最新的。
    /// 改變視窗大小、程式自己捲動都不算，不會因此停止自動捲動。
    private func userScrolled() {
        setPinned(view.distanceFromBottom <= 60)
    }

    private func setPinned(_ pinned: Bool) {
        guard pinned != self.pinned else { return }
        self.pinned = pinned
        onPinnedChange?(pinned)
    }
}

// MARK: - 畫面

/// 一區字幕的 AppKit 元件：捲動區裡一個唯讀、可選取的文字元件。
///
/// 只排看得到的地方附近（`allowsNonContiguousLayout`）：一場 8 小時的字幕全部重排要約 0.45 秒（改變視窗寬度時），
/// 1 小時約 56 ms，在最後加一段約 1 ms（實測，M1 Max）。還沒排到的地方先用估計的高度，之後由系統在閒置時補排；
/// 所以綠線在畫的時候才算位置（`CaptionTextView`），補排之後如果在看最新的，就再捲到最下面一次。
final class CaptionZoneView: NSView {
    let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private let lineMetrics = CaptionLineMetrics()
    private let scrollView = NSScrollView()
    private let textView: CaptionTextView
    private var lastWidth: CGFloat = -1
    private var layoutCheckScheduled = false
    /// 寬度變了。
    var onResize: (() -> Void)?
    /// 排版補完了一部分（高度可能變了）。
    var onLayout: (() -> Void)?
    /// 使用者自己捲動了。
    var onUserScroll: (() -> Void)?

    /// 還在更新、左邊要畫綠線的段（文字裡的範圍）。
    var markerRanges: [NSRange] {
        get { textView.markerRanges }
        set { textView.markerRanges = newValue }
    }

    /// 文字和字幕區邊緣的距離（DESIGN.md：左右 20 pt、上下 12 pt）。
    static let inset = NSSize(width: 20, height: 12)

    /// 讀螢幕軟體唸出來的名稱，例如「中文字幕」。
    func setAccessibilityTitle(_ title: String) {
        textView.setAccessibilityLabel("\(title)字幕")
    }

    init() {
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.delegate = lineMetrics
        // 只排看得到的地方附近：場次很長、視窗改變寬度時，不必一次重排整場的字幕
        layoutManager.allowsNonContiguousLayout = true
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        textView = CaptionTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)

        // 加了一行、文字元件變高時不要整片重畫：只重畫 TextKit 標出來改過的地方（實測每次更新省下大部分的點陣化）
        textView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        // 不透明的底（和內容區一樣的墨黑 0）：捲動時系統可以沿用已經畫好的字，只畫新露出來的地方。
        // 透明的話，每一次捲到最新都要把看得到的字全部重畫一次
        textView.drawsBackground = true
        textView.backgroundColor = CaptionRenderer.ink0
        textView.textContainerInset = Self.inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.drawsBackground = true
        scrollView.backgroundColor = CaptionRenderer.ink0
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        // 只有使用者自己捲動才會送這兩個通知（觸控板、滑鼠滾輪、拖捲軸）
        for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(userScrolled), name: name, object: scrollView)
        }
        lineMetrics.onLayout = { [weak self] in
            Task { @MainActor [weak self] in self?.layoutCompleted() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = scrollView.contentSize.width
        if textView.frame.width != width { textView.setFrameSize(NSSize(width: width, height: textView.frame.height)) }
        if width != lastWidth {
            lastWidth = width
            onResize?()
        }
    }

    @objc private func userScrolled() {
        onUserScroll?()
    }

    /// 排版補完了一部分：同一輪裡的好幾次合成一次。
    private func layoutCompleted() {
        guard !layoutCheckScheduled else { return }
        layoutCheckScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.layoutCheckScheduled = false
            self.onLayout?()
        }
    }

    /// 最下面還有多少看不到（pt）。
    var distanceFromBottom: CGFloat {
        let visible = scrollView.contentView.bounds
        return max(0, textView.frame.height - visible.maxY)
    }

    /// 捲到最下面。先排好最後一段（約一個畫面多一點的字），文字元件的高度才包含它。
    /// 還沒有寬度時（剛建立、還沒放進視窗）不排：寬度是 0 時排出來的都要重排。
    func scrollToBottom() {
        guard textView.frame.width > 0 else { return }
        let tail = min(storage.length, Self.tailLength)
        if tail > 0 { layoutManager.ensureLayout(forCharacterRange: NSRange(location: storage.length - tail, length: tail)) }
        textView.sizeToFit()
        let clip = scrollView.contentView
        let top = max(0, textView.frame.height - clip.bounds.height)
        if abs(clip.bounds.origin.y - top) >= 0.5 {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: top))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// 捲到最下面之前先排好最後幾個字：比一個大視窗、小字級的畫面多。已經排好的不會重排，所以平常幾乎不花時間。
    private static let tailLength = 20_000
}

/// 唯讀的字幕文字：複製時只給純文字，不含旗子與「未翻譯」標籤。還在更新的段左邊畫一條綠線。
final class CaptionTextView: NSTextView {
    /// 還在更新、左邊要畫綠線的段（文字裡的範圍）。
    var markerRanges: [NSRange] = [] {
        didSet {
            guard markerRanges != oldValue else { return }
            // 只重畫左邊留白的那一條（看得到的範圍）
            setNeedsDisplay(NSRect(x: 0, y: visibleRect.minY, width: textContainerInset.width, height: visibleRect.height))
        }
    }

    // 文字重畫時，連同它左邊的留白一起重畫：段落移動或改變時，綠線才會跟著動
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(widened(invalidRect))
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(widened(rect), avoidAdditionalLayout: flag)
    }

    private func widened(_ rect: NSRect) -> NSRect {
        guard rect.minX > 0, rect.minX <= textContainerInset.width + 1 else { return rect }
        return NSRect(x: 0, y: rect.minY, width: rect.maxX, height: rect.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !markerRanges.isEmpty else { return }
        // 文字元件畫字時只畫在留白以內；綠線在左邊的留白裡，所以把範圍放寬回這一次要重畫的地方
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: dirtyRect.intersection(bounds)).setClip()
        CaptionRenderer.bolt.setFill()
        for range in markerRanges {
            guard let frame = paragraphFrame(range) else { continue }
            // 3 pt 寬，在文字左邊 12 pt，高度是那一段文字從第一行頂端到最後一行底部
            let marker = NSRect(x: textContainerOrigin.x - 12, y: frame.minY, width: 3, height: frame.height)
            if marker.intersects(dirtyRect) { NSBezierPath(roundedRect: marker, xRadius: 1.5, yRadius: 1.5).fill() }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 一段文字從第一行的頂端到最後一行的底部（這個元件的座標）。
    private func paragraphFrame(_ range: NSRange) -> NSRect? {
        guard let layoutManager, range.length > 0, NSMaxRange(range) <= (textStorage?.length ?? 0) else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var top = CGFloat.greatestFiniteMagnitude
        var bottom = -CGFloat.greatestFiniteMagnitude
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            top = min(top, used.minY)
            bottom = max(bottom, used.maxY)
        }
        guard top < bottom else { return nil }
        return NSRect(x: 0, y: top + textContainerOrigin.y, width: 0, height: bottom - top)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        let text = string as NSString
        let selected = selectedRanges.map { text.substring(with: $0.rangeValue) }.joined(separator: "\n")
        // 旗子與標籤是附件（U+FFFC），旗子前面還有一個空格
        let plain = selected.replacingOccurrences(of: " \u{FFFC}", with: "").replacingOccurrences(of: "\u{FFFC}", with: "")
        return pboard.setString(plain, forType: .string)
    }
}

// MARK: - 行高與基線

/// 一段的行高、基線、行距與段距（pt）。放在每一段文字的屬性裡，排版時照著用。
final class CaptionParagraphMetrics: NSObject {
    let lineHeight: CGFloat
    let baseline: CGFloat
    let lineSpacing: CGFloat
    let spacingAfter: CGFloat

    init(font: NSFont, lineSpacing: CGFloat, spacingAfter: CGFloat) {
        // 和 SwiftUI 的 Text 一樣用這個字型自己的行高（系統字型 26 pt 是 30 pt），中文字（蘋方）不會把行撐高
        lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        // 基線取整數：和 SwiftUI 的位置一模一樣（實測比對截圖，每一行都在同一個像素）
        baseline = font.ascender.rounded()
        self.lineSpacing = lineSpacing
        self.spacingAfter = spacingAfter
    }
}

extension NSAttributedString.Key {
    static let captionMetrics = NSAttributedString.Key("ThunderFlowCaptionMetrics")
}

/// 照每一段的 `CaptionParagraphMetrics` 決定每一行的高度與基線：同一段的行與行之間加行距，最後一行之後加段距。
/// 只讀文字的屬性，不記排版的狀態。
final class CaptionLineMetrics: NSObject, NSLayoutManagerDelegate {
    /// 排版補完了一部分。
    var onLayout: (@Sendable () -> Void)?

    func layoutManager(
        _ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool
    ) {
        onLayout?()
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let storage = layoutManager.textStorage else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard characters.length > 0, characters.location < storage.length,
            let metrics = storage.attribute(.captionMetrics, at: characters.location, effectiveRange: nil)
                as? CaptionParagraphMetrics
        else { return false }
        // 這一行是一段的最後一行：結束在換行，或是整份文字的最後
        let end = NSMaxRange(characters)
        let last = end >= storage.length || (storage.string as NSString).character(at: end - 1) == 0x0A
        lineFragmentRect.pointee.size.height = metrics.lineHeight + (last ? metrics.spacingAfter : metrics.lineSpacing)
        lineFragmentUsedRect.pointee.size.height = metrics.lineHeight
        baselineOffset.pointee = metrics.baseline
        return true
    }
}

// MARK: - 段落的樣子

/// 把一段字幕畫成文字：字型、顏色、旗子、「未翻譯」標籤（DESIGN.md 4.10.3、4.10.4 節）。
@MainActor
struct CaptionRenderer {
    static let bolt = NSColor(Theme.bolt)
    /// 內容區的底：墨黑 0。
    static let ink0 = NSColor(Theme.ink0)
    /// 正在說的那一行英文：白 45%。
    static let speaking = NSColor(Theme.speaking)

    let title: NSAttributedString
    /// 新的一段前面的換行。
    let separator: NSAttributedString
    private let settled: [NSAttributedString.Key: Any]
    private let updating: [NSAttributedString.Key: Any]
    private let untranslated: [NSAttributedString.Key: Any]
    private let flag: NSAttributedString
    private let tag: NSAttributedString

    init(style: CaptionZoneStyle) {
        let font = NSFont.systemFont(ofSize: style.fontSize)
        let metrics = CaptionParagraphMetrics(font: font, lineSpacing: style.lineSpacing, spacingAfter: 10)
        let base: [NSAttributedString.Key: Any] = [.font: font, .captionMetrics: metrics]
        let chinese = style.options.language == .chinese
        // 中文區：定稿是主要文字色，其他是次要灰；英文區：每一行是次要灰，正在說的那一行是白 45%
        settled = base.merging([.foregroundColor: chinese ? NSColor.labelColor : NSColor.secondaryLabelColor]) { $1 }
        updating = base.merging([.foregroundColor: chinese ? NSColor.secondaryLabelColor : Self.speaking]) { $1 }
        untranslated = base.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }
        separator = NSAttributedString(string: "\n", attributes: settled)

        let caption = NSFont.preferredFont(forTextStyle: .caption1)
        title = NSAttributedString(
            string: style.title,
            attributes: [
                .font: caption, .foregroundColor: NSColor.secondaryLabelColor,
                .captionMetrics: CaptionParagraphMetrics(font: caption, lineSpacing: 0, spacingAfter: 10),
            ])

        let flagText = NSMutableAttributedString(string: " ", attributes: base)
        flagText.append(Self.attachment(Self.flagImage(size: style.fontSize * 0.6), attributes: base))
        flag = flagText
        tag = Self.attachment(Self.untranslatedTag(), attributes: base)
    }

    func render(_ paragraph: CaptionParagraph) -> NSAttributedString {
        let attributes =
            switch paragraph.kind {
            case .settled: settled
            case .updating: updating
            case .untranslated: untranslated
            }
        guard paragraph.flagged || paragraph.kind == .untranslated else {
            return NSAttributedString(string: paragraph.text, attributes: attributes)
        }
        let text = NSMutableAttributedString(string: paragraph.text, attributes: attributes)
        if paragraph.flagged { text.append(flag) }
        if paragraph.kind == .untranslated { text.append(tag) }
        return text
    }

    /// 文字裡的一張小圖。`bounds` 的 y 是圖的底部相對於基線的位置。
    private static func attachment(_ image: (NSImage, baseline: CGFloat), attributes: [NSAttributedString.Key: Any])
        -> NSAttributedString
    {
        let attachment = NSTextAttachment()
        attachment.image = image.0
        attachment.bounds = NSRect(x: 0, y: -image.baseline, width: image.0.size.width, height: image.0.size.height)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// 標記的旗子：黃色、字級的 0.6 倍（`Text.flagged`）。回傳圖與它的底部在基線下面多少。
    private static func flagImage(size: CGFloat) -> (NSImage, baseline: CGFloat) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(Theme.mark)]))
        guard
            let image = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: "標記")?
                .withSymbolConfiguration(configuration)
        else { return (NSImage(), 0) }
        // 符號圖的對齊框底部就是它的基線
        return (image, image.alignmentRect.minY)
    }

    /// 「未翻譯」：橘色的外框標籤，左右 6 pt、上下 1 pt 的留白，和前面的文字隔 8 pt（原本的 `UntranslatedTag`）。
    /// 標籤裡的字和前面的文字對齊基線。回傳圖與它的底部在基線下面多少。
    private static func untranslatedTag() -> (NSImage, baseline: CGFloat) {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let orange = NSColor(Theme.attention)
        let text = NSAttributedString(string: "未翻譯", attributes: [.font: font, .foregroundColor: orange])
        let gap: CGFloat = 8
        // 字的方框高 13 pt（caption 含行距），基線在方框頂端往下 10 pt：和 SwiftUI 一樣（比對截圖）
        let box = NSSize(width: ceil(text.size().width) + 12, height: NSLayoutManager().defaultLineHeight(for: font) + 2)
        let below = box.height - 1 - font.ascender.rounded()
        let image = NSImage(size: NSSize(width: gap + box.width, height: box.height), flipped: false) { _ in
            let frame = NSRect(x: gap, y: 0, width: box.width, height: box.height).insetBy(dx: 0.5, dy: 0.5)
            orange.withAlphaComponent(0.7).setStroke()
            let path = NSBezierPath(roundedRect: frame, xRadius: 5.5, yRadius: 5.5)
            path.lineWidth = 1
            path.stroke()
            // 沒有 usesLineFragmentOrigin 時，方框的原點就是第一行的基線
            text.draw(with: NSRect(x: gap + 6, y: below, width: box.width, height: box.height), options: [])
            return true
        }
        return (image, below)
    }
}

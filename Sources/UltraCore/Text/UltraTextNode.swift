import Foundation
import UltraLayout

/// Styled text, the counterpart of a `Text` element: nested spans that
/// inherit their parent's style, line limits with ellipsizing, Dynamic Type,
/// and pressable spans.
///
/// The node is also a box: `style` gives it a size, padding, background and
/// borders like any `UltraNode`. It can't have child nodes; nest `TextSpan`s
/// instead.
///
/// Text is flattened, measured (as the node's Yoga measure function) and
/// drawn off the main thread. Measuring and drawing share one layout per
/// width, so a node is usually laid out once and drawn from that layout.
public final class UltraTextNode: UltraNode, @unchecked Sendable {
    // @unchecked Sendable: as `UltraNode`; text lives in the locked state.

    public convenience init(
        _ text: String = "",
        style: Style = Style(),
        textStyle: TextStyle = TextStyle(),
        numberOfLines: Int = 0,
        ellipsizeMode: EllipsizeMode = .tail
    ) {
        self.init(
            spans: text.isEmpty ? [] : [TextSpan(text)],
            style: style,
            textStyle: textStyle,
            numberOfLines: numberOfLines,
            ellipsizeMode: ellipsizeMode
        )
    }

    public init(
        spans: [TextSpan],
        style: Style = Style(),
        textStyle: TextStyle = TextStyle(),
        numberOfLines: Int = 0,
        ellipsizeMode: EllipsizeMode = .tail
    ) {
        super.init(style: style)
        var content = TextContent()
        content.spans = spans
        content.style = textStyle
        content.numberOfLines = numberOfLines
        content.ellipsizeMode = ellipsizeMode
        state.withLock { $0.text = content }
        // Not attached to any tree yet, so no pass can see the shadow.
        shadow.layout.isText = true
        shadow.layout.measureFunction = { [weak self] width, widthMode, height, heightMode in
            self?.measure(width: width, widthMode: widthMode, height: height, heightMode: heightMode) ?? .zero
        }
    }

    // MARK: Content

    /// The text without styling. Setting it replaces every span.
    public var text: String {
        get { content.plainText }
        set { updateContent { $0.spans = newValue.isEmpty ? [] : [TextSpan(newValue)] } }
    }

    public var spans: [TextSpan] {
        get { content.spans }
        set { updateContent { $0.spans = newValue } }
    }

    /// The style every span inherits.
    public var textStyle: TextStyle {
        get { content.style }
        set { updateContent { $0.style = newValue } }
    }

    /// The most lines to show; 0 for no limit.
    public var numberOfLines: Int {
        get { content.numberOfLines }
        set { updateContent { $0.numberOfLines = newValue } }
    }

    public var ellipsizeMode: EllipsizeMode {
        get { content.ellipsizeMode }
        set { updateContent { $0.ellipsizeMode = newValue } }
    }

    /// Whether font sizes follow the system text size (Dynamic Type).
    public var allowFontScaling: Bool {
        get { content.allowFontScaling }
        set { updateContent { $0.allowFontScaling = newValue } }
    }

    /// The most the system text size may enlarge this text; `nil` or a
    /// value below 1 means no limit.
    public var maxFontSizeMultiplier: CGFloat? {
        get { content.maxFontSizeMultiplier }
        set { updateContent { $0.maxFontSizeMultiplier = newValue } }
    }

    /// Turns off the highlight over a pressed span.
    public var suppressHighlighting: Bool {
        get { content.suppressHighlighting }
        set { updateContent { $0.suppressHighlighting = newValue } }
    }

    private var content: TextContent {
        state.withLock { $0.text ?? TextContent() }
    }

    private func updateContent(_ body: (inout TextContent) -> Void) {
        state.withLock { state in
            var content = state.text ?? TextContent()
            body(&content)
            content.version += 1
            state.text = content
        }
        setNeedsSync(redraw: true)
    }

    /// The pressable span with this index, if the text is still the one at
    /// `version`. Main thread, at touch time.
    func link(at index: Int, version: UInt64) -> TextSpan? {
        state.withLock { state -> TextSpan? in
            guard let content = state.text, content.version == version else { return nil }
            let links = content.links
            return links.indices.contains(index) ? links[index] : nil
        }
    }

    override var acceptsChildren: Bool { false }

    // MARK: Pipeline (layout queue)

    override func syncContent(previous: NodeState?, current: NodeState, pass: Pass) {
        guard let content = current.text else { return }
        // The text's layouts outlive a host: another host (or a measurement)
        // in the same environment keeps them.
        guard content.version != shadow.textVersion || shadow.textEnvironment != pass.environment
            || shadow.attributedText == nil else { return }
        shadow.textVersion = content.version
        shadow.textEnvironment = pass.environment
        shadow.attributedText = content.attributedText(
            fontScale: pass.environment.fontScale,
            isDark: pass.environment.isDark
        )
        shadow.textSource = nil
        #if canImport(UIKit)
        if pass.measuresTextInParallel, let text = shadow.attributedText, text.length > 0 {
            if !shadow.textLayouts.isEmpty {
                let width = shadow.hasTextMeasureWidth ? shadow.textMeasureWidth : shadow.textLayout?.maxWidth
                pass.textPreparations.append(TextPreparation(node: self, text: text, width: width))
            } else {
                pass.textSources.append(TextPreparation(node: self, text: text, width: nil))
            }
        }
        #endif
        shadow.textLayouts = []
        shadow.textLayout = nil
        shadow.layout.markDirty()
    }

    /// Yoga's measure function. Runs inside the pass's layout computation.
    private func measure(width: CGFloat, widthMode: MeasureMode, height: CGFloat, heightMode: MeasureMode) -> CGSize {
        let limit: CGFloat? = widthMode == .undefined || width.isNaN ? nil : width
        shadow.textMeasureWidth = limit
        shadow.hasTextMeasureWidth = true
        var size = textLayout(fitting: limit).size
        switch widthMode {
        case .exactly: size.width = width
        case .atMost: size.width = min(size.width, width)
        case .undefined: break
        }
        if heightMode == .exactly {
            size.height = height
        }
        return size
    }

    /// A layout for `width`: a recent one if it breaks lines the same way,
    /// otherwise a new one.
    private func textLayout(fitting width: CGFloat?) -> TextLayout {
        if let cached = shadow.textLayouts.first(where: { $0.fits(width: width) }) {
            return cached
        }
        let text = shadow.attributedText ?? AttributedText(string: "", runs: [], paragraph: .init(), linkCount: 0)
        let renderer = shadow.renderer
        let measurer: any TextMeasurer = renderer?.measurer ?? ApproximateTextMeasurer()
        Diagnostics.shared.recordMeasurement()
        let layout: TextLayout
        #if canImport(UIKit)
        if let measurer = measurer as? CoreTextMeasurer {
            layout = measurer.layout(
                text,
                maxWidth: width,
                scale: renderer?.environment.scale ?? 1,
                reusing: shadow.textLayouts.first,
                source: shadow.textSource as? CoreTextSource
            )
            // The layout keeps the source for later widths.
            shadow.textSource = nil
        } else {
            layout = measurer.layout(text, maxWidth: width, scale: renderer?.environment.scale ?? 1)
        }
        #else
        layout = measurer.layout(text, maxWidth: width, scale: renderer?.environment.scale ?? 1)
        #endif
        shadow.textLayouts.insert(layout, at: 0)
        if shadow.textLayouts.count > 4 {
            shadow.textLayouts.removeLast()
        }
        return layout
    }

    /// Padding plus border: where the text sits inside the node's box.
    private var contentInset: Insets {
        let padding = shadow.layout.resolvedPadding
        let border = shadow.layout.resolvedBorder
        return Insets(
            top: padding.top + border.top,
            left: padding.left + border.left,
            bottom: padding.bottom + border.bottom,
            right: padding.right + border.right
        )
    }

    private var contentWidth: CGFloat {
        let inset = contentInset
        return shadow.frame.width - inset.left - inset.right
    }

    override func updateContentForFrame(pass: Pass) {
        let width = contentWidth
        guard width > 0 else { return }
        if let current = shadow.textLayout, current.fits(width: width) {
            return
        }
        shadow.textLayout = textLayout(fitting: width)
    }

    override func contributeProps(_ props: inout ViewProps, state: NodeState, pass: Pass) {
        guard let content = state.text else { return }
        let inset = contentInset
        let links = (shadow.textLayout?.linkRegions(inWidth: contentWidth) ?? []).map { region in
            TextLinkRegion(index: region.index, rects: region.rects.map { $0.offsetBy(dx: inset.left, dy: inset.top) })
        }
        props.text = TextViewProps(version: content.version, links: links, highlightsPress: !content.suppressHighlighting)
        if state.accessibility.label == nil {
            props.accessibility.label = shadow.attributedText?.string
        }
        if state.accessibility.isElement == nil {
            props.accessibility.isElement = true
        }
        if state.accessibility.role == nil {
            props.accessibility.role = links.isEmpty ? .text : .link
        }
    }

    override func contentDrawing(state: NodeState) -> (drawing: any Drawing, key: DrawingKey.Content)? {
        guard let layout = shadow.textLayout, !layout.lines.isEmpty else { return nil }
        let inset = contentInset
        return (TextDrawing(layout: layout, inset: inset), .text(layout.id, inset: inset))
    }

    /// The layout the node is drawn from, as of the last pass. Layout queue
    /// and tests only.
    var currentTextLayout: TextLayout? { shadow.textLayout }
}

/// Draws a text layout. The drawing code lives with the Core Text measurer.
struct TextDrawing: Drawing {
    var layout: TextLayout
    /// Padding plus border, around the text.
    var inset = Insets.zero
}

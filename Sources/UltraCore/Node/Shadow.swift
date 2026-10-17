import Foundation
import UltraLayout

/// The pipeline's own record of a node: its Yoga node, the last state it
/// synced, the frame it computed and what it last sent to the main thread.
///
/// Touched only on the layout queue. Every node owns exactly one.
final class Shadow {
    let layout = LayoutNode()

    // MARK: Tree, as last synced

    weak var parent: UltraNode?
    weak var renderer: Renderer?
    var children: [UltraNode] = []
    var depth = 0
    var isAttached = false
    /// The pass that attached the node, so a pass doesn't sync it twice.
    var attachedInPass: UInt64 = 0
    /// The node's state as of the last sync.
    var snapshot: NodeState?

    // MARK: Results

    /// Relative to the parent, from the last layout.
    var frame = CGRect.zero
    var interfaceState: InterfaceState = []
    /// Whether the main thread has (or is about to have) a view for it.
    var isMounted = false
    var sentProps: ViewProps?
    var sentFrame: CGRect?
    /// The bitmap the main thread shows, kept while in the display range.
    var contents: Contents?
    var drawnKey: DrawingKey?

    // MARK: Text

    var textVersion: UInt64?
    /// The environment the attributed text and its layouts were made for.
    var textEnvironment: RenderEnvironment?
    var attributedText: AttributedText?
    /// The attributed text prepared for layout (a typesetter), built ahead of
    /// the layout pass when the measurer supports it.
    var textSource: AnyObject?
    /// Recent layouts of the current text, newest first. Measuring and
    /// drawing share them.
    var textLayouts: [TextLayout] = []
    /// The layout for the current frame.
    var textLayout: TextLayout?
    /// The last constraint supplied by the flex layout measure callback.
    var textMeasureWidth: CGFloat?
    var hasTextMeasureWidth = false

    // MARK: Scrolling

    var contentOffset = CGPoint.zero
}

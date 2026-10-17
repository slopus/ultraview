import Foundation
import UltraLayout

/// Measures trees that aren't shown, off the main thread.
///
/// A measurement runs the same layout as a pass, on the pipeline's layout
/// queue, and leaves its results in the nodes: Yoga's caches and the text
/// layouts. A host that later shows the tree at the measured width, in the
/// same environment, reuses them instead of measuring again.
public enum NodeMeasurement {
    /// The size of `root` laid out at `width`, with no limit on its height.
    ///
    /// The tree must not be hosted, or measured elsewhere, while this runs.
    public static func measure(
        _ root: UltraNode,
        width: CGFloat,
        environment: RenderEnvironment = RenderEnvironment()
    ) async -> CGSize {
        await measure(root, width: width, environment: environment, measurer: defaultMeasurer)
    }

    static func measure(
        _ root: UltraNode,
        width: CGFloat,
        environment: RenderEnvironment,
        measurer: any TextMeasurer
    ) async -> CGSize {
        await withCheckedContinuation { continuation in
            Pipeline.layoutQueue.async {
                continuation.resume(returning: measureNow(root, width: width, environment: environment, measurer: measurer))
            }
        }
    }

    /// Measures on the layout queue, where the caller already is.
    static func measureNow(
        _ root: UltraNode,
        width: CGFloat,
        environment: RenderEnvironment,
        measurer: any TextMeasurer
    ) -> CGSize {
        dispatchPrecondition(condition: .onQueue(Pipeline.layoutQueue))
        // A renderer that is never in a window: it lays out and measures,
        // and mounts and draws nothing.
        let renderer = Renderer(root: root, measurer: measurer, rasterizer: NoRasterizer(), automatic: false) { _ in }
        renderer.update { inputs in
            inputs.width = width
            inputs.height = nil
            inputs.environment = environment
        }
        renderer.runPass()
        renderer.detach()
        return root.shadow.frame.size
    }

    private static var defaultMeasurer: any TextMeasurer {
        #if canImport(UIKit)
        CoreTextMeasurer()
        #else
        ApproximateTextMeasurer()
        #endif
    }
}

/// Draws nothing; a measurement never draws.
private struct NoRasterizer: Rasterizer {
    func rasterize(_ drawing: any Drawing, size: CGSize, scale: CGFloat, isCancelled: () -> Bool) -> Contents? {
        nil
    }
}

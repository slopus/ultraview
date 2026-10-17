import Dispatch
import Foundation
import Synchronization
import Testing
@testable import UltraCore
import UltraLayout

/// Lays text out with `ApproximateTextMeasurer` (a 20-point font gives
/// 10-point characters and 24-point lines) and records every call.
final class CountingMeasurer: TextMeasurer {
    struct Call: Sendable {
        var text: String
        var maxWidth: CGFloat?
        var onMain: Bool
    }

    let calls = Mutex<[Call]>([])
    private let base = ApproximateTextMeasurer(characterWidth: 0.5)

    var count: Int { calls.withLock { $0.count } }

    func layout(_ text: AttributedText, maxWidth: CGFloat?, scale: CGFloat) -> TextLayout {
        calls.withLock { $0.append(Call(text: text.string, maxWidth: maxWidth, onMain: Thread.isMainThread)) }
        return base.layout(text, maxWidth: maxWidth, scale: scale)
    }
}

/// Records what it is asked to draw and returns a token bitmap. A gate can
/// hold the drawing of one text until the test releases it.
final class RecordingRasterizer: Rasterizer {
    struct Draw: Sendable {
        var size: CGSize
        var text: String?
        var layoutID: UInt64?
        var hasBox: Bool
        var onMain: Bool
    }

    struct Gate: Sendable {
        var text: String
        var started = DispatchSemaphore(value: 0)
        var release = DispatchSemaphore(value: 0)
    }

    let draws = Mutex<[Draw]>([])
    let cancelled = Mutex<[String]>([])
    let gate = Mutex<Gate?>(nil)

    var count: Int { draws.withLock { $0.count } }

    var drawnTexts: [String] {
        draws.withLock { $0.compactMap(\.text) }
    }

    func rasterize(_ drawing: any Drawing, size: CGSize, scale: CGFloat, isCancelled: () -> Bool) -> Contents? {
        let node = drawing as? NodeDrawing
        let layout = (node?.content as? TextDrawing)?.layout
        let text = layout?.text.string
        draws.withLock {
            $0.append(Draw(size: size, text: text, layoutID: layout?.id, hasBox: node?.box != nil, onMain: Thread.isMainThread))
        }
        if let gate = gate.withLock({ $0 }), gate.text == text {
            gate.started.signal()
            gate.release.wait()
            if isCancelled() {
                cancelled.withLock { $0.append(text ?? "") }
                return nil
            }
        }
        return Contents(size: size, scale: scale, image: "bitmap of \(text ?? "box")")
    }
}

/// A tree hosted by a renderer whose commits are collected.
final class Harness: Sendable {
    let renderer: Renderer
    let measurer = CountingMeasurer()
    let rasterizer = RecordingRasterizer()
    let mailbox = CommitMailbox()
    private let collected = Collected()

    private final class Collected: Sendable {
        let commits = Mutex<[Commit]>([])
    }

    init(
        root: UltraNode,
        automatic: Bool = false,
        width: CGFloat? = 300,
        height: CGFloat? = 600,
        inWindow: Bool = true,
        environment: RenderEnvironment = RenderEnvironment(scale: 2)
    ) {
        let collected = collected
        let mailbox = mailbox
        renderer = Renderer(root: root, measurer: measurer, rasterizer: rasterizer, automatic: automatic) { commit in
            collected.commits.withLock { $0.append(commit) }
            mailbox.post(commit)
        }
        renderer.update { inputs in
            inputs.width = width
            inputs.height = height
            inputs.inWindow = inWindow
            inputs.environment = environment
        }
    }

    var commits: [Commit] { collected.commits.withLock { $0 } }

    /// Runs one pass and returns its commit, if it posted one.
    @discardableResult
    func pass() -> Commit? {
        let before = commits.count
        renderer.runPassNow()
        let after = commits
        return after.count > before ? after.last : nil
    }

    func update(_ body: (inout Renderer.Inputs) -> Void) {
        renderer.update(body)
    }

    /// Reads pipeline state where it lives.
    func read<Value: Sendable>(_ body: () -> Value) -> Value {
        Pipeline.layoutQueue.sync(execute: body)
    }
}

func box(_ configure: (inout Style) -> Void = { _ in }, children: [UltraNode] = []) -> UltraNode {
    var style = Style()
    configure(&style)
    return UltraNode(style: style, children: children)
}

func text(_ string: String, fontSize: CGFloat = 20, _ configure: (inout Style) -> Void = { _ in }) -> UltraTextNode {
    var style = Style()
    configure(&style)
    return UltraTextNode(string, style: style, textStyle: TextStyle(fontSize: fontSize))
}

extension Commit {
    func kinds() -> [ObjectIdentifier: CommitEntry.Kind] {
        entries.mapValues(\.kind)
    }

    func nodes(_ kind: CommitEntry.Kind) -> Set<ObjectIdentifier> {
        Set(entries.values.filter { $0.kind == kind }.map { ObjectIdentifier($0.node) })
    }
}

func ids(_ nodes: [UltraNode]) -> Set<ObjectIdentifier> {
    Set(nodes.map(ObjectIdentifier.init))
}

func same(_ lhs: [UltraNode]?, _ rhs: [UltraNode]) -> Bool {
    guard let lhs else { return false }
    return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0 === $1 }
}

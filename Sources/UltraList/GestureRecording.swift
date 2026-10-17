import Foundation

/// Public-API gesture observations. Timestamps are relative to the recording start.
public struct GestureRecording: Sendable, Codable {
    public struct Frame: Sendable, Codable {
        public var time: Double
        public var offset: Double
        public var dragging: Bool
        public var translation: ScrollVector
        public var velocity: ScrollVector
        public init(time: Double, offset: Double, dragging: Bool, translation: ScrollVector = .zero, velocity: ScrollVector = .zero) {
            self.time = time; self.offset = offset; self.dragging = dragging; self.translation = translation; self.velocity = velocity
        }
    }
    public struct Event: Sendable, Codable {
        public enum Phase: String, Sendable, Codable { case touchDown, began, changed, ended, cancelled }
        public var time: Double
        public var phase: Phase
        public var translation: ScrollVector
        public var velocity: ScrollVector
        public init(time: Double, phase: Phase, translation: ScrollVector = .zero, velocity: ScrollVector = .zero) {
            self.time = time; self.phase = phase; self.translation = translation; self.velocity = velocity
        }
    }
    public var name: String
    public var viewport: Double
    public var edges: ScrollEdges
    public var scale: Double
    public var indirect: Bool
    public var frames: [Frame]
    public var events: [Event]
    public init(name: String, viewport: Double, edges: ScrollEdges, scale: Double = 3, indirect: Bool = false, frames: [Frame] = [], events: [Event] = []) {
        self.name = name; self.viewport = viewport; self.edges = edges; self.scale = scale; self.indirect = indirect; self.frames = frames; self.events = events
    }
    /// Event replay follows the production seam. Frame replay isolates integration and drag mapping.
    public func replay(events useEvents: Bool) -> [Double] {
        guard let first = frames.first else { return [] }
        var core = ScrollCore(offset: first.offset + (first.dragging ? first.translation.y : 0), viewport: viewport)
        core.scale = scale; core.coefficient = indirect ? 0.715 : 0.55; core.setEdges(edges)
        var result: [Double] = [], eventIndex = 0, wasDragging = false, lastTime = first.time
        let intervals = zip(frames, frames.dropFirst()).filter { !$0.dragging && !$1.dragging }.map { $1.time - $0.time }.sorted()
        let frameStep = intervals.isEmpty ? 1 / 60.0 : intervals[intervals.count / 2]
        var releasedThisFrame = false
        for frame in frames {
            releasedThisFrame = false
            if useEvents {
                while eventIndex < events.count && events[eventIndex].time <= frame.time + 1e-6 {
                    let event = events[eventIndex]; eventIndex += 1
                    switch event.phase {
                    case .touchDown: core.halt(); core.touchDown(at: event.time)
                    case .began:
                        core.beginDrag(); core.drag(translation: event.translation, velocity: event.velocity)
                    case .changed: core.drag(translation: event.translation, velocity: event.velocity)
                    case .ended, .cancelled:
                        core.endDrag(velocity: event.phase == .cancelled ? .zero : event.velocity, at: event.time)
                        releasedThisFrame = true
                    }
                }
            } else if frame.dragging {
                if !wasDragging { core.touchDown(at: frame.time); core.beginDrag() }
                core.drag(translation: frame.translation, velocity: frame.velocity)
            } else if wasDragging {
                core.endDrag(velocity: core.decision.latest == .zero ? .zero : .init(y: -core.decision.latest.y * 1000), at: frame.time)
                releasedThisFrame = true
            }
            if core.isDecelerating { _ = core.step(seconds: releasedThisFrame ? frameStep : max(0, frame.time - lastTime)) }
            result.append(frame.dragging ? core.offset : ScrollMath.pixelRound(core.offset, scale: scale))
            wasDragging = frame.dragging; lastTime = frame.time
        }
        return result
    }
    public func maximumDivergence(events: Bool) -> Double {
        zip(replay(events: events), frames).map { abs($0 - $1.offset) }.max() ?? 0
    }
}
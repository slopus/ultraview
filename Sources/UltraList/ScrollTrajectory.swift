import Foundation

public struct ScrollTrajectory: Sendable, Equatable, Codable {
    public struct Sample: Sendable, Equatable, Codable {
        public var time: Double
        public var offset: Double
        public var velocity: Double
        public init(time: Double, offset: Double, velocity: Double) { self.time = time; self.offset = offset; self.velocity = velocity }
    }
    public var samples: [Sample]
    public var multiplierResetTime: Double?
    public init(samples: [Sample], multiplierResetTime: Double? = nil) {
        precondition(zip(samples, samples.dropFirst()).allSatisfy { $0.time < $1.time })
        self.samples = samples; self.multiplierResetTime = multiplierResetTime
    }
    public init(baking original: ScrollAxis, step: Double = 1 / 120) {
        precondition(step > 0)
        var axis = original
        samples = [.init(time: 0, offset: axis.offset, velocity: axis.velocity)]
        var index = 0
        repeat {
            index += 1
            let result = axis.step(milliseconds: step * 1000), time = Double(index) * step
            samples.append(.init(time: time, offset: result.written, velocity: axis.velocity))
            if result.endedDeceleration, multiplierResetTime == nil { multiplierResetTime = time }
            if result.settled { break }
        } while Double(index) * step < 10
    }
    public var duration: Double { samples.last?.time ?? 0 }
    public var finalOffset: Double { samples.last?.offset ?? 0 }
    public var additiveValues: [Double] { samples.map { $0.offset - finalOffset } }
    public var keyTimes: [Double] { samples.map { duration > 0 ? $0.time / duration : 0 } }
    public func sample(at time: Double) -> Sample {
        guard let first = samples.first else { return .init(time: time, offset: 0, velocity: 0) }
        if time <= first.time { return first }
        if time >= duration { return samples.last! }
        var low = 1, high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < time { low = mid + 1 } else { high = mid }
        }
        let a = samples[low - 1], b = samples[low], phase = (time - a.time) / (b.time - a.time)
        return .init(time: time, offset: a.offset + (b.offset - a.offset) * phase, velocity: a.velocity + (b.velocity - a.velocity) * phase)
    }
    public func extent(after time: Double) -> ClosedRange<Double> {
        extent(from: time, through: max(time, duration))
    }
    /// The exact envelope of the piecewise-linear trajectory over an interval.
    public func extent(from start: Double, through end: Double) -> ClosedRange<Double> {
        precondition(end >= start)
        let first = sample(at: start).offset, last = sample(at: end).offset
        var low = min(first, last), high = max(first, last)
        var lower = 0, upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].time <= start { lower = middle + 1 } else { upper = middle }
        }
        var index = lower
        while index < samples.count, samples[index].time < end {
            low = min(low, samples[index].offset); high = max(high, samples[index].offset)
            index += 1
        }
        return low...high
    }
    public func truncated(at time: Double) -> ScrollTrajectory {
        guard time < duration else { return self }
        let end = max(samples.first?.time ?? 0, time)
        var vertices = samples.filter { $0.time < end - 1e-9 }
        var last = sample(at: end); last.time = end; vertices.append(last)
        return .init(samples: vertices, multiplierResetTime: multiplierResetTime.flatMap { $0 <= end + 1e-9 ? $0 : nil })
    }
    public func splicing(beginTime: Double, now: Double, future: ScrollTrajectory, shift: Double = 0) -> (trajectory: ScrollTrajectory, beginTime: Double) {
        let origin = max(beginTime, now - 1), elapsed = now - origin
        var vertices = samples.compactMap { vertex -> Sample? in
            let global = beginTime + vertex.time
            guard global >= origin - 1e-9, global < now - 1e-9 else { return nil }
            return .init(time: max(0, global - origin), offset: vertex.offset + shift, velocity: vertex.velocity)
        }
        vertices.append(.init(time: elapsed, offset: sample(at: now - beginTime).offset + shift, velocity: future.samples.first?.velocity ?? 0))
        vertices += future.samples.filter { $0.time > 1e-9 }.map { .init(time: elapsed + $0.time, offset: $0.offset, velocity: $0.velocity) }
        let reset = future.multiplierResetTime.map { elapsed + $0 } ?? multiplierResetTime.map { max(0, beginTime + $0 - origin) }
        return (.init(samples: vertices, multiplierResetTime: reset), origin)
    }
}
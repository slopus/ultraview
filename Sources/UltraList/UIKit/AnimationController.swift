#if canImport(UIKit)
import UIKit
import QuartzCore

private final class AnimationCompletion: NSObject, CAAnimationDelegate {
    let completion: @MainActor @Sendable () -> Void
    init(_ completion: @escaping @MainActor @Sendable () -> Void) { self.completion = completion }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        let callback = completion
        Task { @MainActor in callback() }
    }
}

@MainActor
final class AnimationController {
    var model = ListAnimationModel()
    var durationScale: Double = 1
    private var layers: [AnimationOwner: CALayer] = [:]
    private var snapshots: [AnimationOwner: Double] = [:]
    private var baseSnapshots: [AnimationOwner: Double] = [:]
    private var heightSnapshots: [String: Double] = [:]
    private var snapshotTime: Double?
    private var emitted: [ListAnimationModel.Key: UInt64] = [:]
    private var origins: [ListAnimationModel.Key: (generation: UInt64, time: Double)] = [:]
    private var completions: [ListAnimationModel.Key: (UInt64, () -> Void)] = [:]
    private var mirrors: [CALayer] = []
    private var changedPositionLayers: Set<AnimationOwner> = []
    private var layoutTrack: AnimationTrack?
    private var layoutOrigin: Double?
    weak var referenceLayer: CALayer?
    /// The highest rate of the screen the list is on.
    var maximumFramesPerSecond: () -> Float = { 60 }
    private let rate = FrameRateHold()
    var now: Double { referenceLayer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime() }
    func bind(_ owner: AnimationOwner, layer: CALayer) {
        if layers[owner] === layer { return }
        if layers[owner] != nil { unbind(owner) }
        for (other, bound) in layers where bound === layer { unbind(other, removeModel: other != owner) }
        layers[owner] = layer
        for (key, track) in model.tracks where key.owner == owner {
            let remembered = origins[key].flatMap { $0.generation == track.generation ? $0.time : nil }
            install(key, track: track, explicitOrigin: remembered ?? track.startTime)
        }
    }
    func mirrorViewport(on layer: CALayer) { mirrors.append(layer) }
    func owner(boundTo layer: CALayer) -> AnimationOwner? { layers.first { $0.value === layer }?.key }
    func capturePositions() {
        snapshots.removeAll(keepingCapacity: true); baseSnapshots.removeAll(keepingCapacity: true)
        heightSnapshots.removeAll(keepingCapacity: true)
        changedPositionLayers.removeAll(keepingCapacity: true)
        let capturedTime = now
        for (owner, layer) in layers {
            guard case .row(let identity) = owner else { continue }
            if let presentation = layer.presentation() {
                snapshots[owner] = presentation.position.y - layer.position.y
                heightSnapshots[identity] = presentation.bounds.height
            } else {
                heightSnapshots[identity] = model.tracks[.init(owner, .height)] == nil
                    ? layer.bounds.height : baseValue(owner, .height, at: capturedTime)
            }
        }
        snapshotTime = capturedTime
        for owner in layers.keys {
            guard case .row = owner, snapshots[owner] == nil else { continue }
            snapshots[owner] = value(owner, .positionY, at: capturedTime)
        }
        for (owner, value) in snapshots {
            baseSnapshots[owner] = value - positionLayerValue(owner, at: capturedTime)
        }
    }
    func clearPositions() {
        snapshots.removeAll(keepingCapacity: true); baseSnapshots.removeAll(keepingCapacity: true)
        heightSnapshots.removeAll(keepingCapacity: true); snapshotTime = nil
        changedPositionLayers.removeAll(keepingCapacity: true)
    }
    func value(_ owner: AnimationOwner, _ property: AnimatedProperty, at time: Double) -> Double {
        baseValue(owner, property, at: time) + (property == .positionY ? positionLayerValue(owner, at: time) : 0)
    }
    func presentedDisplacement(_ owner: AnimationOwner, at time: Double) -> Double {
        if let captured = snapshots[owner] { return captured }
        if let layer = layers[owner], let presentation = layer.presentation() {
            return presentation.position.y - layer.position.y
        }
        return value(owner, .positionY, at: time)
    }
    func baseValue(_ owner: AnimationOwner, _ property: AnimatedProperty, at time: Double) -> Double {
        let key = ListAnimationModel.Key(owner, property)
        return model.tracks[key].map { trackValue(key, track: $0, at: time) } ?? model.baseValue(owner, property, at: time)
    }
    func positionLayersChanged(_ owner: AnimationOwner) -> Bool { changedPositionLayers.contains(owner) }
    func positionLayerValue(_ owner: AnimationOwner, at time: Double) -> Double {
        model.tracks.reduce(0) { value, entry in
            guard entry.key.owner == owner, let source = entry.key.positionSource else { return value }
            return value + (capturedHeightContribution(source, track: entry.value) ?? trackValue(entry.key, track: entry.value, at: snapshotTime ?? time))
        }
    }
    func positionLayerValue(_ layer: PositionLayer, at time: Double) -> Double {
        capturedHeightContribution(layer.source, track: layer.track) ?? layer.value(at: snapshotTime ?? time)
    }
    private func capturedHeightContribution(_ source: ListAnimationModel.PositionSource, track: AnimationTrack) -> Double? {
        guard case .height(let identity) = source, let height = heightSnapshots[identity],
              let size = model.tracks[.init(.row(identity), .height)] else { return nil }
        let difference = size.from - size.to
        guard abs(difference) > 1e-6 else { return 0 }
        // Both resumes must read the same presented frame. Wall time can be
        // ahead of that frame while the renderer is preparing the next commit.
        return (height - size.to) * track.from / difference
    }
    struct HeightMotion {
        var identity: String
        var track: AnimationTrack
        var origin: Double?
    }
    struct PositionLayer {
        var source: ListAnimationModel.PositionSource
        var track: AnimationTrack
        var origin: Double?
        func value(at time: Double) -> Double {
            origin.map { track.value(at: track.startTime + time - $0) } ?? track.from
        }
    }
    func layoutPosition(at time: Double) -> PositionLayer? {
        guard let track = layoutTrack else { return nil }
        if let (key, installed) = model.tracks.first(where: {
            $0.key.positionSource == .layout && $0.value.startTime == track.startTime
        }), let origin = animationOrigin(key, generation: installed.generation) { layoutOrigin = origin }
        guard time < (layoutOrigin ?? track.startTime) + track.transition.duration else {
            layoutTrack = nil; layoutOrigin = nil; return nil
        }
        return .init(source: .layout, track: track, origin: layoutOrigin)
    }
    func layoutPosition(from value: Double, at time: Double, transition: ListTransition) -> PositionLayer? {
        let current = layoutPosition(at: time)
        if abs(value - (current?.value(at: snapshotTime ?? time) ?? 0)) <= 1e-6 { return current }
        guard !transition.isImmediate, abs(value) > 1e-6 else { layoutTrack = nil; layoutOrigin = nil; return nil }
        let track = AnimationTrack(generation: 0, from: value, to: 0, startTime: time,
                                   transition: transition.scaled(by: durationScale))
        layoutTrack = track; layoutOrigin = nil
        return .init(source: .layout, track: track, origin: nil)
    }
    func heightMotions(at time: Double) -> [HeightMotion] {
        model.tracks.compactMap { key, track in
            guard key.property == .height, case .row(let identity) = key.owner else { return nil }
            let origin = animationOrigin(key, generation: track.generation)
            guard time < (origin ?? track.startTime) + track.transition.duration else { return nil }
            return .init(identity: identity, track: track, origin: origin)
        }
    }
    func positionLayer(_ owner: AnimationOwner, source: ListAnimationModel.PositionSource) -> PositionLayer? {
        let key = ListAnimationModel.Key(owner, source: source)
        guard let track = model.tracks[key] else { return nil }
        return .init(source: source, track: track, origin: animationOrigin(key, generation: track.generation))
    }
    func clockOrigin(_ key: ListAnimationModel.Key, generation: UInt64, fallback: Double? = nil) -> Double? {
        if let origin = animationOrigin(key, generation: generation) { return origin }
        // An installed animation with a zero beginTime is waiting for its
        // transaction's clock. Followers in that transaction must wait too.
        if let animation = layers[key.owner]?.animation(forKey: key.animationKey),
           (animation.value(forKey: "ultraviewGeneration") as? NSNumber)?.uint64Value == generation,
           animation.beginTime == 0 { return nil }
        return fallback
    }
    func inheritPosition(_ owner: AnimationOwner, from reference: AnimationOwner) {
        let key = ListAnimationModel.Key(reference, .positionY)
        guard let track = model.tracks[key] else {
            model.replace(owner, .positionY, from: 0, to: 0, at: now, transition: .immediate)
            clear(owner, .positionY); origins.removeValue(forKey: .init(owner, .positionY))
            return
        }
        let origin = clockOrigin(key, generation: track.generation, fallback: track.startTime)
        if let inherited = model.replace(owner, .positionY, from: track.from, to: track.to,
                                         at: track.startTime, transition: track.transition) {
            install(owner, .positionY, track: inherited, explicitOrigin: origin)
        }
    }
    func joinPosition(_ owner: AnimationOwner, shown: Double, target: Double, at time: Double) {
        let key = ListAnimationModel.Key(owner, .positionY)
        let own = model.tracks[key]
        var clock = own.map { (key: key, track: $0) }
        if clock == nil {
            var deadline = -Double.infinity
            for (source, track) in model.tracks where source.owner == owner && source.positionSource != nil {
                let end = (animationOrigin(source, generation: track.generation) ?? track.startTime) + track.transition.duration
                if end > deadline { deadline = end; clock = (source, track) }
            }
        }
        guard let clock else { return }
        let track = clock.track
        let origin = clockOrigin(clock.key, generation: track.generation, fallback: track.startTime)
        let current = origin.map { track.value(at: track.startTime + time - $0) } ?? track.from
        let remaining = abs(track.from - track.to) > 1e-6 ? (current - track.to) / (track.from - track.to) : 0
        let residual = shown - target - positionLayerValue(owner, at: time)
        let from = remaining > 0 ? residual / remaining : 0
        if own != nil, remaining >= 0.15, abs(track.from) > 1e-6, abs(from) <= 3 * abs(track.from) {
            if let joined = model.replace(owner, .positionY, from: from, to: 0,
                                          at: track.startTime, transition: track.transition) {
                install(owner, .positionY, track: joined, explicitOrigin: origin)
            }
        } else if abs(residual) > 1e-6 {
            var transition = track.transition
            transition.duration = max((origin ?? time) + transition.duration - time, 0.2 * transition.duration)
            replace(owner, .positionY, from: residual, to: 0, at: time, transition: transition.scaled(by: 1 / durationScale))
        } else {
            replace(owner, .positionY, from: 0, to: 0, at: time, transition: .immediate)
        }
    }
    func setPositionLayers(_ owner: AnimationOwner, _ desired: [PositionLayer]) {
        let retained = Set(desired.map(\.source))
        for key in model.removePositionLayers(owner, except: retained) {
            clear(key); origins.removeValue(forKey: key); changedPositionLayers.insert(owner)
        }
        for layer in desired {
            let key = ListAnimationModel.Key(owner, source: layer.source)
            let previous = model.tracks[key]
            let track = model.setPositionLayer(owner, source: layer.source, track: layer.track)
            if track.generation != previous?.generation {
                changedPositionLayers.insert(owner)
                install(key, track: track, explicitOrigin: layer.origin)
            }
        }
    }
    func seed(_ owner: AnimationOwner, width: Double, height: Double, opacity: Double = 1) {
        for (property, value) in [(AnimatedProperty.width, width), (.height, height), (.opacity, opacity)] {
            if let track = model.tracks[.init(owner, property)], abs(track.to - value) <= 1e-6 { continue }
            model.replace(owner, property, from: value, to: value, at: 0, transition: .immediate)
            clear(owner, property); origins.removeValue(forKey: .init(owner, property))
        }
    }
    @discardableResult
    func transition(_ owner: AnimationOwner, _ property: AnimatedProperty, old: Double, new: Double, at time: Double, transition: ListTransition, restarts: Bool = false, completion: (() -> Void)? = nil) -> UInt64? {
        let key = ListAnimationModel.Key(owner, property)
        let prior = model.tracks[key]
        let resolvedCompletion = completion ?? completions[key]?.1
        let resume = resumeValue(owner, property)
        if property == .positionY, let resume, let captured = baseSnapshots[owner],
           abs(old + resume - new - captured) <= 1e-6 {
            // A height follower can change settled positions without changing
            // the row's own displacement. Its existing clock still applies.
            if let prior, let resolvedCompletion { completions[key] = (prior.generation, resolvedCompletion) }
            else if prior == nil { resolvedCompletion?() }
            return prior?.generation
        }
        let track = model.transition(owner, property, old: old, new: new, resume: resume, at: time, transition: transition.scaled(by: durationScale), restarts: restarts)
        if property == .height, transition.isImmediate, case .row(let identity) = owner,
           let prior, let track, prior.startTime == track.startTime, prior.transition == track.transition,
           let height = heightSnapshots[identity] {
            heightSnapshots[identity] = height + track.to - prior.to
        }
        if let track {
            if track.generation != prior?.generation {
                // A track moved by an immediate change keeps its timing, so it keeps the running animation's begin.
                let running = animationOrigin(key, generation: prior?.generation)
                let keepsTiming = prior.map { $0.startTime == track.startTime && $0.transition == track.transition } ?? false
                install(owner, property, track: track, explicitOrigin: keepsTiming ? running.flatMap { $0 != 0 ? $0 : nil } : nil)
            }
            if let resolvedCompletion { completions[key] = (track.generation, resolvedCompletion) }
        } else { clear(owner, property); completions.removeValue(forKey: key); resolvedCompletion?() }
        return track?.generation
    }
    @discardableResult
    func replace(_ owner: AnimationOwner, _ property: AnimatedProperty, from: Double, to: Double, at time: Double, transition: ListTransition, completion: (() -> Void)? = nil) -> UInt64? {
        let key = ListAnimationModel.Key(owner, property)
        let resolvedCompletion = completion ?? completions[key]?.1
        let track = model.replace(owner, property, from: from, to: to, at: time, transition: transition.scaled(by: durationScale))
        if let track {
            if let resolvedCompletion { completions[key] = (track.generation, resolvedCompletion) }
            install(owner, property, track: track)
        } else { clear(owner, property); completions.removeValue(forKey: key); resolvedCompletion?() }
        return track?.generation
    }
    private func resumeValue(_ owner: AnimationOwner, _ property: AnimatedProperty) -> Double? {
        if property == .positionY { return snapshots[owner].map { $0 - positionLayerValue(owner, at: now) } }
        if property == .height, case .row(let identity) = owner, let height = heightSnapshots[identity] { return height }
        guard !property.additive, let layer = layers[owner]?.presentation() else { return nil }
        switch property {
        case .height: return layer.bounds.height
        case .width: return layer.bounds.width
        case .opacity: return Double(layer.opacity)
        default: return nil
        }
    }
    func unbind(_ owner: AnimationOwner, removeModel: Bool = false) {
        let keys = Set(model.tracks.keys.filter { $0.owner == owner }).union(emitted.keys.filter { $0.owner == owner })
        for key in keys {
            if let track = model.tracks[key], let origin = animationOrigin(key, generation: track.generation) {
                origins[key] = (track.generation, origin)
            }
            clear(key)
            if removeModel { completions.removeValue(forKey: key); origins.removeValue(forKey: key) }
        }
        layers.removeValue(forKey: owner)
        if removeModel { model.remove(owner) }
        else if !model.hasTracks(owner) { model.remove(owner) }
        else {
            let deadline = model.tracks.filter { $0.key.owner == owner }.map { key, track in
                (animationOrigin(key, generation: track.generation) ?? track.startTime) + track.transition.duration
            }.max() ?? now
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - now)) { [weak self] in
                guard let self, layers[owner] == nil else { return }
                for (key, track) in model.tracks where key.owner == owner {
                    let end = (animationOrigin(key, generation: track.generation) ?? track.startTime) + track.transition.duration
                    if now >= end { model.finish(key, generation: track.generation); origins.removeValue(forKey: key) }
                }
                if !model.hasTracks(owner) { model.remove(owner) }
            }
        }
    }
    func reset() {
        for owner in Array(layers.keys) { unbind(owner, removeModel: true) }
        model = .init(); completions.removeAll(); clearPositions()
        origins.removeAll(); changedPositionLayers.removeAll()
        layoutTrack = nil; layoutOrigin = nil
    }
    func retentionDeadline(_ owner: AnimationOwner) -> Double {
        retentionDeadline(owners: [owner])
    }
    func retentionDeadline(owners: Set<AnimationOwner>) -> Double {
        var deadline = now
        for (key, track) in model.tracks where owners.contains(key.owner) {
            deadline = max(deadline, (animationOrigin(key, generation: track.generation) ?? track.startTime) + track.transition.duration)
        }
        return deadline
    }
    private func clear(_ owner: AnimationOwner, _ property: AnimatedProperty) {
        clear(.init(owner, property))
    }
    private func clear(_ key: ListAnimationModel.Key) {
        layers[key.owner]?.removeAnimation(forKey: key.animationKey)
        if key.owner == .viewport { for mirror in mirrors { mirror.removeAnimation(forKey: key.animationKey) } }
        emitted.removeValue(forKey: key)
    }
    private func install(_ owner: AnimationOwner, _ property: AnimatedProperty, track: AnimationTrack, explicitOrigin: Double? = nil) {
        install(.init(owner, property), track: track, explicitOrigin: explicitOrigin)
    }
    private func install(_ key: ListAnimationModel.Key, track: AnimationTrack, explicitOrigin: Double? = nil) {
        guard let layer = layers[key.owner] else { return }
        emitted[key] = track.generation
        let animation = Self.compile(key.property, track: track)
        if let explicitOrigin {
            animation.beginTime = layer.convertTime(explicitOrigin, from: referenceLayer)
            origins[key] = (track.generation, explicitOrigin)
        } else { origins.removeValue(forKey: key) }
        animation.delegate = AnimationCompletion { [weak self] in self?.finalize(key, generation: track.generation) }
        layer.add(animation, forKey: key.animationKey)
        if key.owner == .viewport { for mirror in mirrors { mirror.add(animation, forKey: key.animationKey) } }
        if abs(track.to - track.from) > 1e-6 {
            rate.hold(maximumFramesPerSecond: maximumFramesPerSecond(), until: CACurrentMediaTime() + track.deadline - now)
        }
        if abs(track.to - track.from) <= 1e-6 || referenceLayer?.presentation() == nil {
            let delay = max(0, track.deadline - now)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.finalize(key, generation: track.generation) }
        }
    }
    private func finalize(_ key: ListAnimationModel.Key, generation: UInt64) {
        guard let track = model.tracks[key], track.generation == generation else { return }
        let deadline = (animationOrigin(key, generation: generation) ?? track.startTime) + track.transition.duration
        if now + 1e-6 < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + deadline - now) { [weak self] in self?.finalize(key, generation: generation) }
            return
        }
        guard model.finish(key, generation: generation) else { return }
        clear(key); origins.removeValue(forKey: key)
        if let entry = completions[key], entry.0 == generation { completions.removeValue(forKey: key); entry.1() }
    }
    private func animationOrigin(_ key: ListAnimationModel.Key, generation: UInt64?) -> Double? {
        if let generation, let layer = layers[key.owner], let animation = layer.animation(forKey: key.animationKey),
           (animation.value(forKey: "ultraviewGeneration") as? NSNumber)?.uint64Value == generation,
           animation.beginTime != 0 {
            return referenceLayer?.convertTime(animation.beginTime, from: layer) ?? layer.convertTime(animation.beginTime, to: nil)
        }
        return origins[key].flatMap { $0.generation == generation ? $0.time : nil }
    }
    private func trackValue(_ key: ListAnimationModel.Key, track: AnimationTrack, at time: Double) -> Double {
        if let origin = animationOrigin(key, generation: track.generation) {
            return track.value(at: track.startTime + time - origin)
        }
        if layers[key.owner]?.animation(forKey: key.animationKey) != nil { return track.from }
        return track.value(at: time)
    }
    static func compile(_ property: AnimatedProperty, track: AnimationTrack) -> CAPropertyAnimation {
        let logical = track.transition.duration / track.transition.durationFactor
        if let curve = track.viewportCurve {
            let animation = CAKeyframeAnimation(keyPath: property.keyPath)
            animation.values = curve.progress.map { track.from + (track.to - track.from) * $0 }
            animation.calculationMode = .linear
            animation.duration = logical; animation.speed = Float(1 / track.transition.durationFactor)
            configure(animation, property: property, track: track)
            return animation
        }
        let curve = track.transition.curve
        let animation: CABasicAnimation
        if case .dampedSpring(let damping) = curve {
            let spring = CASpringAnimation(keyPath: property.keyPath)
            spring.mass = 1; spring.stiffness = 180; spring.damping = max(0.1, damping)
            spring.initialVelocity = 0; spring.duration = logical
            spring.speed = Float(1 / track.transition.durationFactor)
            animation = spring
        } else if curve == .keyboardSpring || curve == .smoothDeceleration || (curve == .spring && (logical == 0.5 || abs(logical - 0.3832) <= 1e-4)) {
            let spring = CASpringAnimation(keyPath: property.keyPath)
            spring.mass = 1
            if curve == .smoothDeceleration {
                let omega = 2 * Double.pi / 0.6
                spring.stiffness = omega * omega; spring.damping = 2 * omega; spring.duration = 1.6
            } else { spring.stiffness = 555.027; spring.damping = 47.118; spring.duration = logical }
            spring.initialVelocity = 0; spring.speed = Float(spring.duration / max(1e-9, track.transition.duration))
            if curve == .keyboardSpring { spring.timingFunction = CAMediaTimingFunction(name: .linear); spring.allowsOverdamping = false }
            animation = spring
        } else {
            animation = CABasicAnimation(keyPath: property.keyPath)
            animation.duration = logical; animation.speed = Float(1 / track.transition.durationFactor)
            switch curve {
            case .linear: animation.timingFunction = CAMediaTimingFunction(name: .linear)
            case .easeIn: animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            case .easeInOut: animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            case .uiKitScroll: animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.3643, 0, 0.6357, 1)
            case .spring: animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.380, 0.700, 0.125, 1)
            case .bezier(let a, let b, let c, let d): animation.timingFunction = CAMediaTimingFunction(controlPoints: Float(a), Float(b), Float(c), Float(d))
            case .smoothDeceleration, .dampedSpring, .keyboardSpring: break
            }
        }
        animation.fromValue = track.from; animation.toValue = track.to
        configure(animation, property: property, track: track)
        return animation
    }
    private static func configure(_ animation: CAPropertyAnimation, property: AnimatedProperty, track: AnimationTrack) {
        animation.isAdditive = property.additive
        animation.fillMode = .both; animation.isRemovedOnCompletion = false
        animation.setValue(track.generation, forKey: "ultraviewGeneration")
        animation.setValue(track.startTime, forKey: "ultraviewStartTime")
        if property.additive { animation.preferredFrameRateRange = .init(minimum: 30, maximum: 120, preferred: 120) }
    }
}
#endif
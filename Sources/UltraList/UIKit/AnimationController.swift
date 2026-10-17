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
    private var emitted: [ListAnimationModel.Key: UInt64] = [:]
    private var origins: [ListAnimationModel.Key: (generation: UInt64, time: Double)] = [:]
    private var completions: [ListAnimationModel.Key: (UInt64, () -> Void)] = [:]
    private var mirrors: [CALayer] = []
    weak var referenceLayer: CALayer?
    var now: Double { referenceLayer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime() }
    func bind(_ owner: AnimationOwner, layer: CALayer) {
        if layers[owner] === layer { return }
        if layers[owner] != nil { unbind(owner) }
        for (other, bound) in layers where bound === layer { unbind(other, removeModel: other != owner) }
        layers[owner] = layer
        for property in AnimatedProperty.allCases {
            if let track = model.tracks[.init(owner, property)] {
                let key = ListAnimationModel.Key(owner, property)
                let remembered = origins[key].flatMap { $0.generation == track.generation ? $0.time : nil }
                install(owner, property, track: track, explicitOrigin: remembered ?? track.startTime)
            }
        }
    }
    func mirrorViewport(on layer: CALayer) { mirrors.append(layer) }
    func owner(boundTo layer: CALayer) -> AnimationOwner? { layers.first { $0.value === layer }?.key }
    func capturePositions() {
        snapshots.removeAll(keepingCapacity: true)
        for (owner, layer) in layers {
            guard case .row = owner, let presentation = layer.presentation() else { continue }
            snapshots[owner] = presentation.position.y - layer.position.y
        }
    }
    func clearPositions() { snapshots.removeAll(keepingCapacity: true) }
    func value(_ owner: AnimationOwner, _ property: AnimatedProperty, at time: Double) -> Double { model.value(owner, property, at: time) }
    func seed(_ owner: AnimationOwner, width: Double, height: Double, opacity: Double = 1) {
        for (property, value) in [(AnimatedProperty.width, width), (.height, height), (.opacity, opacity)] {
            model.replace(owner, property, from: value, to: value, at: 0, transition: .immediate)
        }
    }
    @discardableResult
    func transition(_ owner: AnimationOwner, _ property: AnimatedProperty, old: Double, new: Double, at time: Double, transition: ListTransition, completion: (() -> Void)? = nil) -> UInt64? {
        let key = ListAnimationModel.Key(owner, property)
        let prior = model.tracks[key]?.generation
        let resolvedCompletion = completion ?? completions[key]?.1
        var resume: Double?
        if property == .positionY { resume = snapshots[owner] }
        else if !property.additive, let layer = layers[owner]?.presentation() {
            switch property {
            case .height: resume = layer.bounds.height
            case .width: resume = layer.bounds.width
            case .opacity: resume = Double(layer.opacity)
            default: break
            }
        }
        let track = model.transition(owner, property, old: old, new: new, resume: resume, at: time, transition: transition.scaled(by: durationScale))
        if let track {
            if track.generation != prior { install(owner, property, track: track) }
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
    func unbind(_ owner: AnimationOwner, removeModel: Bool = false) {
        for property in AnimatedProperty.allCases {
            let key = ListAnimationModel.Key(owner, property)
            if let animation = layers[owner]?.animation(forKey: "ultraview.list.\(property.rawValue)"), animation.beginTime != 0, let track = model.tracks[key] {
                origins[key] = (track.generation, animation.beginTime)
            }
            clear(owner, property)
            if removeModel { completions.removeValue(forKey: .init(owner, property)) }
        }
        layers.removeValue(forKey: owner)
        if removeModel { model.remove(owner) }
        else if !model.hasTracks(owner) { model.remove(owner) }
        else {
            let deadline = model.tracks.filter { $0.key.owner == owner }.map { $0.value.deadline }.max() ?? now
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - now)) { [weak self] in
                guard let self, layers[owner] == nil else { return }
                for (key, generation) in model.completed(at: now) where key.owner == owner { model.finish(key, generation: generation) }
                if !model.hasTracks(owner) { model.remove(owner) }
            }
        }
    }
    func reset() {
        for owner in Array(layers.keys) { unbind(owner, removeModel: true) }
        model = .init(); completions.removeAll(); snapshots.removeAll(); origins.removeAll()
    }
    private func clear(_ owner: AnimationOwner, _ property: AnimatedProperty) {
        layers[owner]?.removeAnimation(forKey: "ultraview.list.\(property.rawValue)")
        if owner == .viewport { for mirror in mirrors { mirror.removeAnimation(forKey: "ultraview.list.\(property.rawValue)") } }
        emitted.removeValue(forKey: .init(owner, property))
    }
    private func install(_ owner: AnimationOwner, _ property: AnimatedProperty, track: AnimationTrack, explicitOrigin: Double? = nil) {
        guard let layer = layers[owner] else { return }
        let key = ListAnimationModel.Key(owner, property)
        emitted[key] = track.generation
        let animation = Self.compile(property, track: track)
        if let explicitOrigin { animation.beginTime = explicitOrigin }
        animation.delegate = AnimationCompletion { [weak self] in self?.finalize(key, generation: track.generation) }
        layer.add(animation, forKey: "ultraview.list.\(property.rawValue)")
        if owner == .viewport { for mirror in mirrors { mirror.add(animation, forKey: "ultraview.list.\(property.rawValue)") } }
        if abs(track.to - track.from) <= 1e-6 || referenceLayer?.presentation() == nil {
            let delay = max(0, track.deadline - now)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.finalize(key, generation: track.generation) }
        }
    }
    private func finalize(_ key: ListAnimationModel.Key, generation: UInt64) {
        guard let track = model.tracks[key], track.generation == generation else { return }
        if now + 1e-6 < track.deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + track.deadline - now) { [weak self] in self?.finalize(key, generation: generation) }
            return
        }
        guard model.finish(key, generation: generation) else { return }
        clear(key.owner, key.property)
        if let entry = completions[key], entry.0 == generation { completions.removeValue(forKey: key); entry.1() }
    }
    static func compile(_ property: AnimatedProperty, track: AnimationTrack) -> CABasicAnimation {
        let logical = track.transition.duration / track.transition.durationFactor
        let curve = track.transition.curve
        let animation: CABasicAnimation
        if curve == .smoothDeceleration || (curve == .spring && (logical == 0.5 || abs(logical - 0.3832) <= 1e-4)) {
            let spring = CASpringAnimation(keyPath: property.keyPath)
            spring.mass = 1
            if curve == .smoothDeceleration {
                let omega = 2 * Double.pi / 0.6
                spring.stiffness = omega * omega; spring.damping = 2 * omega; spring.duration = 1.6
            } else { spring.stiffness = 555.027; spring.damping = 47.118; spring.duration = logical }
            spring.initialVelocity = 0; spring.speed = Float(spring.duration / max(1e-9, track.transition.duration))
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
            case .smoothDeceleration: break
            }
        }
        animation.fromValue = track.from; animation.toValue = track.to
        animation.isAdditive = property.additive
        animation.fillMode = .both; animation.isRemovedOnCompletion = false
        animation.setValue(track.generation, forKey: "ultraviewGeneration")
        animation.setValue(track.startTime, forKey: "ultraviewStartTime")
        if property.additive { animation.preferredFrameRateRange = .init(minimum: 30, maximum: 120, preferred: 120) }
        return animation
    }
}
#endif
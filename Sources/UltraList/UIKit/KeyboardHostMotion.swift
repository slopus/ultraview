#if canImport(UIKit)
import UIKit

@MainActor
enum KeyboardHostMotion {
    /// A new show may keep the interrupted hide's position motion. Once the
    /// shown model frame is committed, the owner can replace both motions.
    static func positionKeys(_ host: KeyboardHostLookup.Host, in window: UIWindow, targetTop: Double, notBefore origin: Double?, ownedKey: String) -> [String]? {
        let layer = host.view.layer
        guard layer.contents == nil, (layer.backgroundColor?.alpha ?? 0) == 0,
              layer.shadowOpacity == 0 else { return nil }
        let modelTop = Double(host.view.convert(host.view.bounds, to: window).minY)
        guard abs(modelTop - targetTop) <= 0.5 else { return nil }
        var ancestor = host.view.superview
        while let view = ancestor {
            for key in view.layer.animationKeys() ?? [] {
                if let path = (view.layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath,
                   path.hasPrefix("position") || path.hasPrefix("bounds") || path.hasPrefix("transform") { return nil }
            }
            ancestor = view.superview
        }
        var keys: [String] = [], starts: [Double] = []
        for key in layer.animationKeys() ?? [] {
            guard key != ownedKey, let property = layer.animation(forKey: key) as? CAPropertyAnimation else { continue }
            if let path = property.keyPath, path.hasPrefix("bounds") || path.hasPrefix("transform") { return nil }
            guard property.keyPath == "position" else { continue }
            guard property.beginTime > 0 else { return nil }
            keys.append(key); starts.append(layer.convertTime(property.beginTime, to: nil))
        }
        guard !keys.isEmpty else { return [] }
        if let origin, !starts.contains(where: { $0 >= origin - 1e-6 }) { return nil }
        return keys
    }
}
#endif
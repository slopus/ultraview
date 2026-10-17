import Foundation
import Synchronization
internal import yoga

/// Settings shared by every node of a layout tree: the pixel grid that frames
/// are rounded to, and which of Yoga's historical behaviors to keep.
///
/// Configs are interned per value and live for the life of the process, so
/// nodes can point at them without ownership questions.
public final class LayoutConfig: @unchecked Sendable {
    // @unchecked: the Yoga config is written once, in `init`, and only read
    // after that (by Yoga, on whichever thread computes a layout).
    let yogaConfig: YGConfigRef

    /// Points per pixel: frames land on multiples of `1 / pointScaleFactor`.
    /// 0 turns rounding off.
    public let pointScaleFactor: CGFloat
    public let errata: Errata

    public enum Errata: Sendable, Hashable {
        /// Strict, web-conformant behavior.
        case none
        /// Every behavior Yoga keeps for compatibility with older layouts,
        /// which is what most existing flexbox styles were written against.
        case all
    }

    private init(pointScaleFactor: CGFloat, errata: Errata) {
        self.pointScaleFactor = pointScaleFactor
        self.errata = errata
        yogaConfig = YGConfigNew()
        YGConfigSetPointScaleFactor(yogaConfig, Float(pointScaleFactor))
        YGConfigSetErrata(yogaConfig, errata == .all ? Yoga.errataAll : Yoga.errataNone)
    }

    private struct Key: Hashable {
        var pointScaleFactor: CGFloat
        var errata: Errata
    }

    private static let cache = Mutex<[Key: LayoutConfig]>([:])

    /// The config for these settings. Equal settings return the same object.
    public static func shared(pointScaleFactor: CGFloat, errata: Errata = .all) -> LayoutConfig {
        let key = Key(pointScaleFactor: pointScaleFactor, errata: errata)
        return cache.withLock { cache in
            if let config = cache[key] {
                return config
            }
            let config = LayoutConfig(pointScaleFactor: pointScaleFactor, errata: errata)
            cache[key] = config
            return config
        }
    }
}

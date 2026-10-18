#if canImport(UIKit)
import QuartzCore

@MainActor
extension CAPropertyAnimation {
    var probeIsSupported: Bool { self is CABasicAnimation || self is CAKeyframeAnimation }
    var probeFromValue: Any? {
        (self as? CABasicAnimation)?.fromValue ?? (self as? CAKeyframeAnimation)?.values?.first
    }
    var probeToValue: Any? {
        (self as? CABasicAnimation)?.toValue ?? (self as? CAKeyframeAnimation)?.values?.last
    }
    var probeScalarValues: [Double] {
        if let values = (self as? CAKeyframeAnimation)?.values {
            return values.compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        return [probeFromValue, probeToValue].compactMap { ($0 as? NSNumber)?.doubleValue }
    }
}
#endif
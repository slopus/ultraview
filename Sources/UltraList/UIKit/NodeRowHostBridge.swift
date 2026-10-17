#if canImport(UIKit)
import UIKit
import UltraCore

@MainActor
func configureNodeRowHost(_ host: NodeHostView, size: CGSize) {
    host.frame.size = size
    host.prepare(size: size)
}

func environmentKey(_ environment: RenderEnvironment) -> UInt64 {
    var hash = Hasher()
    hash.combine(Double(environment.scale)); hash.combine(Double(environment.fontScale))
    hash.combine(environment.isDark); hash.combine(environment.isRightToLeft)
    return UInt64(bitPattern: Int64(hash.finalize()))
}
#endif
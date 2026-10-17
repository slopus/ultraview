#if canImport(UIKit)
import UIKit
import UltraCore

@MainActor
func configureNodeRowHost(_ host: NodeHostView, size: CGSize) {
    host.firstCommitTimeout = 0
    host.frame.size = size
    host.setNeedsLayout()
}
#endif
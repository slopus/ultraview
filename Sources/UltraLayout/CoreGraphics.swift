// CGFloat, CGRect and friends come from CoreGraphics on Apple platforms and
// from Foundation elsewhere. Foundation alone doesn't bring CoreGraphics'
// Swift API (initializers, Equatable) with every SDK, so re-export it: code
// that imports UltraLayout gets the same geometry types everywhere.
#if canImport(CoreGraphics)
@_exported import CoreGraphics
#endif

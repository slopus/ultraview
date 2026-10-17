import Foundation
import UltraLayout

/// One step of a view transform. A list of them applies like a CSS
/// `transform`: the last one acts on the view first, all around its center.
public enum Transform: Sendable, Equatable {
    case translate(x: CGFloat, y: CGFloat)
    case translateX(CGFloat)
    case translateY(CGFloat)
    case scale(CGFloat)
    case scaleX(CGFloat)
    case scaleY(CGFloat)
    /// Radians, clockwise on screen.
    case rotate(CGFloat)
    case rotateX(CGFloat)
    case rotateY(CGFloat)
    case skewX(CGFloat)
    case skewY(CGFloat)
    /// Distance from the viewer to the plane, in points.
    case perspective(CGFloat)
    case matrix(Transform3D)

    public static func rotate(degrees: CGFloat) -> Transform {
        .rotate(degrees * .pi / 180)
    }

    var matrix: Transform3D {
        var m = Transform3D.identity
        switch self {
        case .translate(let x, let y):
            m[3, 0] = x
            m[3, 1] = y
        case .translateX(let x):
            m[3, 0] = x
        case .translateY(let y):
            m[3, 1] = y
        case .scale(let s):
            m[0, 0] = s
            m[1, 1] = s
        case .scaleX(let s):
            m[0, 0] = s
        case .scaleY(let s):
            m[1, 1] = s
        case .rotate(let a):
            m[0, 0] = cos(a)
            m[0, 1] = sin(a)
            m[1, 0] = -sin(a)
            m[1, 1] = cos(a)
        case .rotateX(let a):
            m[1, 1] = cos(a)
            m[1, 2] = sin(a)
            m[2, 1] = -sin(a)
            m[2, 2] = cos(a)
        case .rotateY(let a):
            m[0, 0] = cos(a)
            m[0, 2] = -sin(a)
            m[2, 0] = sin(a)
            m[2, 2] = cos(a)
        case .skewX(let a):
            m[1, 0] = tan(a)
        case .skewY(let a):
            m[0, 1] = tan(a)
        case .perspective(let d):
            if d != 0 {
                m[2, 3] = -1 / d
            }
        case .matrix(let matrix):
            m = matrix
        }
        return m
    }
}

/// A 4×4 matrix for row vectors, laid out like Core Animation's: a point
/// `p` maps to `p · M`, and `m41`/`m42` hold the translation.
public struct Transform3D: Sendable, Equatable {
    /// Row-major: `values[row * 4 + column]`.
    public var values: [CGFloat]

    public init(values: [CGFloat]) {
        precondition(values.count == 16, "a 4×4 matrix has 16 values")
        self.values = values
    }

    public static let identity = Transform3D(values: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ])

    /// Composes `operations` in list order, so the first operation is the
    /// outermost one and the last acts on the view first.
    public init(_ operations: [Transform]) {
        var result = Transform3D.identity
        for operation in operations {
            result = operation.matrix * result
        }
        self = result
    }

    public subscript(row: Int, column: Int) -> CGFloat {
        get { values[row * 4 + column] }
        set { values[row * 4 + column] = newValue }
    }

    public var isIdentity: Bool { self == .identity }

    /// `lhs` applies first, then `rhs`.
    public static func * (lhs: Transform3D, rhs: Transform3D) -> Transform3D {
        var result = [CGFloat](repeating: 0, count: 16)
        for row in 0..<4 {
            for column in 0..<4 {
                var sum: CGFloat = 0
                for k in 0..<4 {
                    sum += lhs[row, k] * rhs[k, column]
                }
                result[row * 4 + column] = sum
            }
        }
        return Transform3D(values: result)
    }

    /// Maps a point in the plane z = 0, with the perspective divide.
    public func apply(to point: CGPoint) -> CGPoint {
        let x = point.x * self[0, 0] + point.y * self[1, 0] + self[3, 0]
        let y = point.x * self[0, 1] + point.y * self[1, 1] + self[3, 1]
        let w = point.x * self[0, 3] + point.y * self[1, 3] + self[3, 3]
        return w == 0 || w == 1 ? CGPoint(x: x, y: y) : CGPoint(x: x / w, y: y / w)
    }
}

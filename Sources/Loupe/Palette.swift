import LoupeCore
import SwiftUI

/// The diff palette's status colours, for SwiftUI views.
extension ShapeStyle where Self == Color {
    static var diffSuccess: Color { Color(nsColor: DiffColors.successText) }
    static var diffDanger: Color { Color(nsColor: DiffColors.dangerText) }
}

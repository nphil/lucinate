import SwiftUI

struct Theme: Identifiable, Sendable, Equatable {
  let id: String
  let name: String
  let isDark: Bool
  // Surfaces
  let background: Color        // window / root
  let surface: Color           // cards, grouped rows
  let elevated: Color          // raised cards, sheets, menus
  // Text
  let textPrimary: Color
  let textSecondary: Color
  let separator: Color
  // Accents
  let accent: Color            // primary tint
  let accent2: Color           // secondary accent
  // Semantic
  let success: Color           // also throughput RX (download)
  let warning: Color
  let error: Color
  let info: Color              // also throughput TX (upload)
}

extension Color {
  /// Parses a 6-digit RRGGBB hex string (a leading "#" is tolerated).
  init(hex: String) {
    var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("#") {
      cleaned = String(cleaned.dropFirst())
    }

    var value: UInt64 = 0
    guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
      self = .clear
      return
    }

    let red = Double((value >> 16) & 0xFF) / 255.0
    let green = Double((value >> 8) & 0xFF) / 255.0
    let blue = Double(value & 0xFF) / 255.0
    self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
  }
}

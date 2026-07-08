import SwiftUI

private struct ThemeKey: EnvironmentKey {
  static let defaultValue: Theme = Themes.dark.first { $0.id == Themes.defaultDarkID } ?? Themes.dark[0]
}

extension EnvironmentValues {
  var theme: Theme {
    get { self[ThemeKey.self] }
    set { self[ThemeKey.self] = newValue }
  }
}

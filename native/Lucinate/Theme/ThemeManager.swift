import SwiftUI
import Observation

enum ThemeMode: String, CaseIterable, Sendable {
  case system
  case light
  case dark
}

@MainActor @Observable final class ThemeManager {
  var mode: ThemeMode {
    didSet { UserDefaults.standard.set(mode.rawValue, forKey: "themeMode") }
  }

  var lightThemeID: String {
    didSet { UserDefaults.standard.set(lightThemeID, forKey: "lightThemeId") }
  }

  var darkThemeID: String {
    didSet { UserDefaults.standard.set(darkThemeID, forKey: "darkThemeId") }
  }

  init() {
    let defaults = UserDefaults.standard
    self.mode = defaults.string(forKey: "themeMode").flatMap(ThemeMode.init(rawValue:)) ?? .system
    self.lightThemeID = defaults.string(forKey: "lightThemeId") ?? Themes.defaultLightID
    self.darkThemeID = defaults.string(forKey: "darkThemeId") ?? Themes.defaultDarkID
  }

  var lightTheme: Theme {
    Themes.theme(id: lightThemeID)
      ?? Themes.theme(id: Themes.defaultLightID)
      ?? Themes.light[0]
  }

  var darkTheme: Theme {
    Themes.theme(id: darkThemeID)
      ?? Themes.theme(id: Themes.defaultDarkID)
      ?? Themes.dark[0]
  }

  func theme(for colorScheme: ColorScheme) -> Theme {
    colorScheme == .dark ? darkTheme : lightTheme
  }

  var preferredColorScheme: ColorScheme? {
    switch mode {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

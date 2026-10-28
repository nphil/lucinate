import AppIntents

// Actions for the Shortcuts app, Siri, Spotlight and the Action button. iOS suspends Lucinate once
// nothing has needed it for 10 minutes (KeepAlivePolicy), and Shortcuts has no trigger for Personal
// Hotspot turning on. So a shortcut turns the hotspot on with Shortcuts' own Set Personal Hotspot
// action, then runs Use Phone Data, which wakes Lucinate in the background without opening it.
// The wording of the replies is in PhoneDataShortcutReply.swift.

struct UsePhoneDataIntent: AppIntent {
    static let title: LocalizedStringResource = "Use Phone Data"
    static let description = IntentDescription(
        "Wakes Lucinate in the background, without opening it, and keeps it running for 10 minutes. Your router then uses this iPhone's data as soon as Personal Hotspot is on and the iPhone is plugged into it. Put it after Set Personal Hotspot. The result is true when Phone Data is ready.",
        categoryName: "Phone Data",
        searchKeywords: ["hotspot", "data", "router", "travel"])
    /// Never opens the app, which would pull the screen up over whatever the shortcut is doing.
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let phone = PhoneDataController.shared
        let keptAlive = phone.wake()
        let state = phone.shortcutState()
        return .result(
            value: keptAlive && state.isReady,
            dialog: "\(PhoneDataShortcutReply.start(state, keptAlive: keptAlive))")
    }
}

struct PhoneDataStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Phone Data On?"
    static let description = IntentDescription(
        "True while your router is using this iPhone's data, for an If in a shortcut. It also says what is missing when it isn't.",
        categoryName: "Phone Data",
        searchKeywords: ["hotspot", "data", "router", "travel"])
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let state = PhoneDataController.shared.shortcutState()
        return .result(value: state.isOn, dialog: "\(PhoneDataShortcutReply.status(state))")
    }
}

/// Ready in Shortcuts, Siri and Spotlight as soon as Lucinate is installed, with nothing to set up.
struct LucinateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UsePhoneDataIntent(),
            phrases: ["Use phone data with \(.applicationName)", "Share iPhone data with \(.applicationName)"],
            shortTitle: "Use Phone Data",
            systemImageName: "iphone.radiowaves.left.and.right")
        AppShortcut(
            intent: PhoneDataStatusIntent(),
            phrases: ["Is phone data on in \(.applicationName)", "Check phone data in \(.applicationName)"],
            shortTitle: "Is Phone Data On?",
            systemImageName: "antenna.radiowaves.left.and.right")
    }
}

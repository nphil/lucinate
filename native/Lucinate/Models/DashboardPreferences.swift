import Foundation

/// Per-router dashboard display preferences, mirroring
/// `lib/models/dashboard_preferences.dart`.
///
/// Empty interface sets mean "show all" for that category.
struct DashboardPreferences: Codable, Sendable, Equatable {
    /// Wireless interface card ids enabled on the dashboard (empty = show all).
    let enabledWirelessInterfaces: Set<String>
    /// Wired interface card ids enabled on the dashboard (empty = show all).
    let enabledWiredInterfaces: Set<String>
    /// The interface whose throughput is featured when not showing all.
    let primaryThroughputInterface: String?
    let showAllThroughput: Bool

    init(
        enabledWirelessInterfaces: Set<String> = [],
        enabledWiredInterfaces: Set<String> = [],
        primaryThroughputInterface: String? = nil,
        showAllThroughput: Bool = true
    ) {
        self.enabledWirelessInterfaces = enabledWirelessInterfaces
        self.enabledWiredInterfaces = enabledWiredInterfaces
        self.primaryThroughputInterface = primaryThroughputInterface
        self.showAllThroughput = showAllThroughput
    }

    static let defaultPreferences = DashboardPreferences()

    // MARK: - Storage keys

    /// Legacy global storage key (pre per-router migration).
    static let globalStorageKey = "dashboard_preferences"

    /// Per-router storage key: "dashboard_preferences:<routerId>".
    static func storageKey(forRouterID routerID: String) -> String {
        "\(globalStorageKey):\(routerID)"
    }

    func copyWith(
        enabledWirelessInterfaces: Set<String>? = nil,
        enabledWiredInterfaces: Set<String>? = nil,
        primaryThroughputInterface: String?? = nil,
        showAllThroughput: Bool? = nil
    ) -> DashboardPreferences {
        DashboardPreferences(
            enabledWirelessInterfaces: enabledWirelessInterfaces
                ?? self.enabledWirelessInterfaces,
            enabledWiredInterfaces: enabledWiredInterfaces
                ?? self.enabledWiredInterfaces,
            primaryThroughputInterface: primaryThroughputInterface
                ?? self.primaryThroughputInterface,
            showAllThroughput: showAllThroughput ?? self.showAllThroughput
        )
    }

    // MARK: - Codable (tolerant of missing keys, matching the Dart parsing)

    private enum CodingKeys: String, CodingKey {
        case enabledWirelessInterfaces
        case enabledWiredInterfaces
        case primaryThroughputInterface
        case showAllThroughput
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let wireless =
            try container.decodeIfPresent([String].self, forKey: .enabledWirelessInterfaces) ?? []
        let wired =
            try container.decodeIfPresent([String].self, forKey: .enabledWiredInterfaces) ?? []
        enabledWirelessInterfaces = Set(wireless)
        enabledWiredInterfaces = Set(wired)
        primaryThroughputInterface =
            try container.decodeIfPresent(String.self, forKey: .primaryThroughputInterface)
        showAllThroughput =
            try container.decodeIfPresent(Bool.self, forKey: .showAllThroughput) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Sort for deterministic output (Dart writes toList() of a set).
        try container.encode(
            enabledWirelessInterfaces.sorted(), forKey: .enabledWirelessInterfaces)
        try container.encode(
            enabledWiredInterfaces.sorted(), forKey: .enabledWiredInterfaces)
        try container.encodeIfPresent(
            primaryThroughputInterface, forKey: .primaryThroughputInterface)
        try container.encode(showAllThroughput, forKey: .showAllThroughput)
    }
}

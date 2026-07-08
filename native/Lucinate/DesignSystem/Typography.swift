import SwiftUI

/// Semantic font roles used across the app.
extension Font {
    /// Big numeric readouts (throughput, client counts).
    static var statValue: Font {
        .system(.title2, design: .rounded).weight(.semibold)
    }

    /// Caption under a stat value; pair with `theme.textSecondary`.
    static var statLabel: Font {
        .system(.caption)
    }

    /// Card / section titles.
    static var cardTitle: Font {
        .system(.headline)
    }

    /// Monospaced body text (IPs, MACs, logs).
    static var monospacedBody: Font {
        .system(.body, design: .monospaced)
    }
}

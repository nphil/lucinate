import Charts
import SwiftUI

/// Dual-series throughput chart over the calculator's history ring buffer.
/// Download (RX) plots in `theme.success`, upload (TX) in `theme.info`;
/// values are shown in bits/second.
struct ThroughputChart: View {
    var points: [ThroughputCalculator.Point]

    @Environment(\.theme) private var theme

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Sample", point.id),
                    y: .value("Download", point.rxBytesPerSecond * 8),
                    series: .value("Series", "Download Area"),
                    stacking: .unstacked
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Self.fill(theme.success))

                AreaMark(
                    x: .value("Sample", point.id),
                    y: .value("Upload", point.txBytesPerSecond * 8),
                    series: .value("Series", "Upload Area"),
                    stacking: .unstacked
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Self.fill(theme.info))

                LineMark(
                    x: .value("Sample", point.id),
                    y: .value("Download", point.rxBytesPerSecond * 8),
                    series: .value("Series", "Download")
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(theme.success)

                LineMark(
                    x: .value("Sample", point.id),
                    y: .value("Upload", point.txBytesPerSecond * 8),
                    series: .value("Series", "Upload")
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(theme.info)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                    .foregroundStyle(theme.separator.opacity(0.6))
                AxisValueLabel {
                    if let bits = value.as(Double.self) {
                        Text(Self.compactBitRate(bits))
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 180)
        .overlay {
            if points.count < 2 {
                Text("Collecting throughput data…")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .accessibilityLabel("Throughput chart")
    }

    private static func fill(_ color: Color) -> LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [color.opacity(0.35), color.opacity(0.0)]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Compact bit-rate label for the Y axis ("0 bps", "250 Kbps", "12 Mbps").
    static func compactBitRate(_ bits: Double) -> String {
        if bits >= 1_000_000 {
            return String(format: "%.0f Mbps", bits / 1_000_000)
        } else if bits >= 1_000 {
            return String(format: "%.0f Kbps", bits / 1_000)
        }
        return String(format: "%.0f bps", max(0, bits))
    }
}

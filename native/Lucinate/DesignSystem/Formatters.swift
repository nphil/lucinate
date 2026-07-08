import Foundation

/// Pure formatting helpers (no locale surprises, deterministic output).
enum Format {
    /// Byte count -> "512 B" / "1.5 KB" / "3.2 MB" / "1.1 GB" (1024-based).
    static func bytes(_ b: Double) -> String {
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        if b >= gb {
            return String(format: "%.1f GB", b / gb)
        } else if b >= mb {
            return String(format: "%.1f MB", b / mb)
        } else if b >= kb {
            return String(format: "%.1f KB", b / kb)
        }
        return String(format: "%.0f B", max(0, b))
    }

    /// Seconds -> "3d 4h 12m"; leading zero units omitted; minimum "0m".
    static func uptime(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Epoch seconds -> "just now" / "Xm ago" / "Xh ago" / "Xd ago".
    static func relativeEpoch(_ epoch: Int, now: Int) -> String {
        let delta = max(0, now - epoch)
        if delta < 60 {
            return "just now"
        } else if delta < 3_600 {
            return "\(delta / 60)m ago"
        } else if delta < 86_400 {
            return "\(delta / 3_600)h ago"
        }
        return "\(delta / 86_400)d ago"
    }
}

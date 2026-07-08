import Foundation
import Observation

/// Loads and mutates the router's firewall configuration: DNAT port forwards
/// (`redirect` sections) and traffic rules (`rule` sections), via
/// `uci get/set/add/delete firewall` + commit + `/etc/init.d/firewall reload`.
@MainActor
@Observable
final class FirewallController {

    // MARK: - Models

    /// A `config redirect` section (typically target DNAT).
    struct PortForward: Identifiable, Equatable, Sendable {
        /// firewall uci section id (e.g. `cfg0d92bd`).
        let section: String
        let name: String
        /// "tcp", "udp", or "tcp udp".
        let proto: String
        /// External port or range (e.g. "8080" or "8000-8010").
        let srcDPort: String
        /// Internal destination address.
        let destIP: String
        /// Internal port or range.
        let destPort: String
        /// Option `enabled` != "0" (missing means enabled).
        var enabled: Bool

        var id: String { section }
    }

    /// A `config rule` section (read-only in the UI apart from enable/disable).
    struct FirewallRule: Identifiable, Equatable, Sendable {
        /// firewall uci section id.
        let section: String
        let name: String
        let src: String
        let dest: String
        let proto: String
        /// ACCEPT / REJECT / DROP / ...
        let target: String
        /// Option `enabled` != "0" (missing means enabled).
        var enabled: Bool

        var id: String { section }
    }

    // MARK: - State

    private(set) var forwards: [PortForward] = []
    private(set) var rules: [FirewallRule] = []

    /// True only while loading with nothing cached (cached-first UX).
    private(set) var isLoading = false
    private(set) var error: String?
    /// A mutation is in flight.
    private(set) var isBusy = false

    var isEmpty: Bool { forwards.isEmpty && rules.isEmpty }

    // MARK: - Loading

    func load(service: RouterService?) async {
        guard let service else {
            forwards = []
            rules = []
            error = nil
            return
        }

        if isEmpty { isLoading = true }
        defer { isLoading = false }

        do {
            let firewall = try await service.uciGet(config: "firewall")
            parse(firewall)
            error = nil
        } catch {
            if isEmpty {
                self.error = error.localizedDescription
            }
        }
    }

    private func parse(_ firewall: JSONValue) {
        let sections = firewall.objectValue ?? [:]

        var parsedForwards: [PortForward] = []
        var parsedRules: [FirewallRule] = []

        for (name, section) in sections {
            switch section[".type"].stringValue {
            case "redirect":
                parsedForwards.append(
                    PortForward(
                        section: name,
                        name: FirewallController.optionString(section["name"]),
                        proto: FirewallController.optionString(section["proto"]),
                        srcDPort: FirewallController.optionString(section["src_dport"]),
                        destIP: FirewallController.optionString(section["dest_ip"]),
                        destPort: FirewallController.optionString(section["dest_port"]),
                        enabled: FirewallController.isEnabled(section["enabled"])
                    ))
            case "rule":
                parsedRules.append(
                    FirewallRule(
                        section: name,
                        name: FirewallController.optionString(section["name"]),
                        src: FirewallController.optionString(section["src"]),
                        dest: FirewallController.optionString(section["dest"]),
                        proto: FirewallController.optionString(section["proto"]),
                        target: FirewallController.optionString(section["target"]),
                        enabled: FirewallController.isEnabled(section["enabled"])
                    ))
            default:
                break
            }
        }

        parsedForwards.sort {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.section < $1.section
        }
        parsedRules.sort {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.section < $1.section
        }

        forwards = parsedForwards
        rules = parsedRules
    }

    /// UCI options are usually strings, but list-typed options arrive as
    /// arrays (e.g. `list proto 'tcp'` + `list proto 'udp'`). Join them.
    private nonisolated static func optionString(_ value: JSONValue) -> String {
        if let string = value.coercedString { return string }
        if let items = value.arrayValue {
            return items.compactMap { $0.coercedString }.joined(separator: " ")
        }
        return ""
    }

    /// `enabled` semantics: anything except an explicit "0" counts as on.
    private nonisolated static func isEnabled(_ value: JSONValue) -> Bool {
        optionString(value) != "0"
    }

    // MARK: - Enable / disable (redirects and rules)

    /// Flips `enabled` on any firewall section with an optimistic local update
    /// that reverts on failure, then commits, reloads the firewall, and
    /// refreshes the model.
    func setEnabled(_ enabled: Bool, section: String, service: RouterService?) async {
        guard let service else {
            error = "Not connected"
            return
        }

        // Optimistic flip in whichever list holds this section.
        var previousForward: Bool?
        var previousRule: Bool?
        if let index = forwards.firstIndex(where: { $0.section == section }) {
            previousForward = forwards[index].enabled
            forwards[index].enabled = enabled
        } else if let index = rules.firstIndex(where: { $0.section == section }) {
            previousRule = rules[index].enabled
            rules[index].enabled = enabled
        } else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            try await service.uciSet(
                config: "firewall", section: section,
                values: ["enabled": enabled ? "1" : "0"])
            try await commitAndReloadFirewall(service: service)
            error = nil
            await load(service: service)
        } catch {
            if let previousForward,
                let index = forwards.firstIndex(where: { $0.section == section })
            {
                forwards[index].enabled = previousForward
            }
            if let previousRule,
                let index = rules.firstIndex(where: { $0.section == section })
            {
                rules[index].enabled = previousRule
            }
            self.error = error.localizedDescription
        }
    }

    // MARK: - Port forward CRUD (return success; capture the error for toasts)

    func addForward(
        name: String, proto: String, srcDPort: String, destIP: String, destPort: String,
        service: RouterService
    ) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.uciAdd(
                config: "firewall", type: "redirect",
                values: [
                    "name": name,
                    "src": "wan",
                    "src_dport": srcDPort,
                    "dest": "lan",
                    "dest_ip": destIP,
                    "dest_port": destPort,
                    "proto": proto,
                    "target": "DNAT",
                    "enabled": "1",
                ])
            try await commitAndReloadFirewall(service: service)
            error = nil
            await load(service: service)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Rewrites an existing redirect's options (leaves `enabled` untouched).
    func updateForward(
        section: String, name: String, proto: String, srcDPort: String, destIP: String,
        destPort: String, service: RouterService
    ) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.uciSet(
                config: "firewall", section: section,
                values: [
                    "name": name,
                    "src": "wan",
                    "src_dport": srcDPort,
                    "dest": "lan",
                    "dest_ip": destIP,
                    "dest_port": destPort,
                    "proto": proto,
                    "target": "DNAT",
                ])
            try await commitAndReloadFirewall(service: service)
            error = nil
            await load(service: service)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func deleteForward(section: String, service: RouterService) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.uciDelete(config: "firewall", section: section)
            try await commitAndReloadFirewall(service: service)
            forwards.removeAll { $0.section == section }
            error = nil
            await load(service: service)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Plumbing

    private func commitAndReloadFirewall(service: RouterService) async throws {
        try await service.uciCommit(config: "firewall")
        _ = try await service.fileExec(command: "/etc/init.d/firewall", params: ["reload"])
    }
}

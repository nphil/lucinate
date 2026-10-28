import Foundation

/// Router side of Phone Data: the packages it needs, finding the iPhone on the router's USB
/// port and its hotspot on the router's Wi-Fi, and setting up or removing the interfaces, over
/// the cable and over Wi-Fi. What goes into uci is decided by `PhoneDataRouterConfig`; this runs
/// the reads and the writes.
extension RouterService {
    /// What the router must have installed for the cable: the iPhone's USB network driver, the
    /// program that pairs with the iPhone, and WireGuard.
    static let phoneDataPackages = [
        "kmod-usb-net-ipheth", "usbmuxd", "kmod-wireguard", "wireguard-tools",
    ]

    /// What the router must have installed for Wi-Fi: WireGuard. TravelMate, which joins the
    /// hotspot, is the router's own business (`PhoneDataRouterState.travelmateInstalled`).
    static let phoneDataWifiPackages = ["kmod-wireguard", "wireguard-tools"]

    // MARK: - State

    /// Everything the Phone Data screen shows, read together. One failed read fails the whole
    /// call: a half-read state would show a router as not set up when it merely didn't answer.
    /// The exception is TravelMate's status file, which only says whether the router is on the
    /// iPhone's hotspot right now: unreadable counts as "not connected", like everywhere else.
    ///
    /// The installed-package list is by far the heaviest read (apk runs on the router, which
    /// may be a small one that is also carrying the household's internet). A caller that
    /// polls passes what a recent check found as `known` to skip it; nil reads the list now.
    func phoneDataState(known: PhoneDataMissingPackages? = nil) async throws
        -> PhoneDataRouterState
    {
        async let network = uciGet(config: "network")
        async let firewall = uciGet(config: "firewall")
        async let dump = interfaceDump()
        async let missing = missingPhoneDataPackages(known: known)
        async let usbDevice = findIPhoneUSBDevice()
        async let travelmate = uciGetIfPresent(config: "travelmate")
        async let wireless = uciGetIfPresent(config: "wireless")
        async let statusFile = travelmateStatusFile()

        let (networkConfig, firewallConfig, interfaces, missingPackages, device) =
            try await (network, firewall, dump, missing, usbDevice)
        let (travelmateConfig, wirelessConfig, status) =
            try await (travelmate, wireless, statusFile)
        return PhoneDataRouterConfig.state(
            network: networkConfig, firewall: firewallConfig, interfaceDump: interfaces,
            travelmate: travelmateConfig, wireless: wirelessConfig ?? .null,
            travelmateStatusFile: status,
            missingPackages: missingPackages.usb, missingWifiPackages: missingPackages.wifi,
            usbDevice: device)
    }

    private func missingPhoneDataPackages(known: PhoneDataMissingPackages?) async throws
        -> PhoneDataMissingPackages
    {
        if let known { return known }
        let installed: [PackageCatalog.Entry]
        do {
            installed = try await installedPackages()
        } catch let error as UbusError where error.isAccessDenied {
            throw PhoneDataRouterError.packagesNotPermitted
        }
        let names = installed.map { $0.name }
        return PhoneDataMissingPackages(
            usb: PhoneDataRouterConfig.missingPackages(
                required: Self.phoneDataPackages, installed: names),
            wifi: PhoneDataRouterConfig.missingPackages(
                required: Self.phoneDataWifiPackages, installed: names))
    }

    /// `uci get`, or nil when the router has no such config: the package that owns it isn't
    /// installed. Any other failure is thrown.
    private func uciGetIfPresent(config: String) async throws -> JSONValue? {
        do {
            return try await uciGet(config: config)
        } catch let error as UbusError where error.isNotFound {
            return nil
        }
    }

    /// TravelMate's status file. Empty when there is none yet (TravelMate never ran, or was
    /// stopped) or when it can't be read.
    private func travelmateStatusFile() async -> String {
        (try? await fileRead(path: TravelmateStatus.runtimeFilePath)) ?? ""
    }

    // MARK: - Packages

    /// Installs `names` through the router's package manager. A result with `succeeded ==
    /// false` carries apk's own words; the cases that need a plain explanation (opkg router, no
    /// permission, an install that never confirmed) are thrown instead.
    func installPhoneDataPackages(_ names: [String]) async throws -> ExecResult {
        guard !names.isEmpty else { return ExecResult(stdout: "", stderr: "", code: 0) }
        switch await packageManagerSupport() {
        case .available: break
        case .opkgRouter: throw PhoneDataRouterError.opkgRouter
        case .notPermitted: throw PhoneDataRouterError.packagesNotPermitted
        }

        // A failed or cut-off index refresh doesn't stop the install: apk may have what it
        // needs cached already, and a failure of its own says more than the refresh's does.
        let update: ExecResult?
        do {
            update = try await packageIndexUpdate()
        } catch is PackageCommandError {
            update = nil
        }

        let install: ExecResult
        do {
            install = try await installPackages(names)
        } catch let error where Self.outcomeUnknown(error) {
            return try await waitForInstall(of: names)
        }
        if install.succeeded { return install }
        // With no internet both steps fail, and the refresh's reason is the useful one.
        if let update, !update.succeeded { return update }
        return install
    }

    /// A reply that never completed doesn't say whether apk ran: the 60 s CGI cut
    /// (`incompleteReply`) or a connection that dropped. The installed list has to answer.
    private static func outcomeUnknown(_ error: Error) -> Bool {
        if error is PackageCommandError { return true }
        return (error as? UbusError)?.isTransient == true
    }

    /// After a cut-off reply apk keeps running on the router. Waits, for up to five minutes,
    /// for the packages to show up as installed.
    private func waitForInstall(of names: [String]) async throws -> ExecResult {
        let deadline = ContinuousClock.now + .seconds(300)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(5))
            if let installed = try? await installedPackages(),
                PhoneDataRouterConfig.missingPackages(
                    required: names, installed: installed.map { $0.name }
                ).isEmpty
            {
                return ExecResult(stdout: "", stderr: "", code: 0)
            }
        }
        throw PhoneDataRouterError.installNotConfirmed
    }

    // MARK: - The iPhone on USB

    /// The network device the iPhone shows up as ("eth2"), or nil when no iPhone is plugged
    /// in, or the router can't say.
    func detectIPhoneUSBDevice() async -> String? {
        try? await findIPhoneUSBDevice()
    }

    /// Like `detectIPhoneUSBDevice`, but a router that refuses or fails to list its
    /// directories throws, instead of passing for "no iPhone". The `ipheth` driver keeps one
    /// entry per USB interface it is bound to, and each of those holds the network device it
    /// created under `net`. A directory that isn't there means the driver isn't loaded, or the
    /// phone was just unplugged: no iPhone.
    private func findIPhoneUSBDevice() async throws -> String? {
        let driverPath = PhoneDataRouterConfig.iphethDriverPath
        let driver: JSONValue
        do {
            driver = try await fileList(path: driverPath)
        } catch let error as UbusError where error.isNotFound {
            return nil
        }
        for entry in PhoneDataRouterConfig.usbInterfaceNames(inDriverListing: driver) {
            let net: JSONValue
            do {
                net = try await fileList(path: "\(driverPath)/\(entry)/net")
            } catch let error as UbusError where error.isNotFound {
                continue
            }
            if let device = PhoneDataRouterConfig.netdevName(inNetListing: net) { return device }
        }
        return nil
    }

    /// Restarts usbmuxd, which pairs with the iPhone: it starts the pairing over, so the
    /// iPhone asks to trust the router again if it has forgotten it.
    func restartIPhonePairing() async throws {
        let result: JSONValue
        do {
            result = try await fileExec(command: "/etc/init.d/usbmuxd", params: ["restart"])
        } catch let error as UbusError where error.isNotFound {
            throw PhoneDataRouterError.usbSupportMissing
        } catch let error as UbusError where error.isAccessDenied {
            throw PhoneDataRouterError.pairingRestartNotAllowed
        }
        guard (result["code"].intValue ?? 0) == 0 else {
            throw PhoneDataRouterError.pairingRestartFailed
        }
    }

    // MARK: - The iPhone's hotspot

    /// The router's Wi-Fi radios (`radio0`, `radio1`, ...), from its wireless config. The two
    /// usual ones when the config can't be read.
    func phoneDataScanRadios() async -> [String] {
        guard let wireless = try? await uciGet(config: "wireless") else {
            return ["radio0", "radio1"]
        }
        return TravelmateConfig.orderedSections(wireless)
            .filter { $0.section[".type"].stringValue == "wifi-device" }
            .map { $0.name }
    }

    /// The networks one radio sees now. A radio that is busy, or refuses to scan, sees none: one
    /// radio failing doesn't fail the scan.
    func phoneDataScan(radio: String) async -> [WifiScanResult] {
        guard let result = try? await wifiScan(radio: radio) else { return [] }
        return (result["results"].arrayValue ?? []).map {
            WifiScanResult.fromIwinfo($0, device: radio)
        }
    }

    // MARK: - Setup and removal over USB

    /// Sets the router up for Phone Data, or brings an existing setup up to date (new keys, a
    /// new USB device name). Safe to run again.
    func applyPhoneData(keys: PhoneDataRouterKeys, usbDevice: String) async throws {
        async let network = uciGet(config: "network")
        async let firewall = uciGet(config: "firewall")
        let (networkConfig, firewallConfig) = try await (network, firewall)
        let plan = try PhoneDataRouterConfig.setupPlan(
            network: networkConfig, firewall: firewallConfig, usbDevice: usbDevice,
            privateKey: keys.routerPrivateKey, address: keys.routerAddress,
            phonePublicKey: keys.phonePublicKey)
        try await commit(plan)
    }

    /// Takes Phone Data off the router. The packages stay installed.
    func removePhoneData() async throws {
        async let network = uciGet(config: "network")
        async let firewall = uciGet(config: "firewall")
        let (networkConfig, firewallConfig) = try await (network, firewall)
        try await commit(
            PhoneDataRouterConfig.removalPlan(network: networkConfig, firewall: firewallConfig))
    }

    /// Stages every edit of the plan, commits network then firewall, and asks for a reload of
    /// both. A failure before the last commit drops what was still staged: `uci get` would
    /// otherwise keep showing values that were never applied, and the next unrelated commit
    /// would ship them. A firewall commit that fails after the network one went through
    /// leaves the router without the zone membership, which `phoneDataState` reports as
    /// "not configured"; running setup again finishes the job. For the cable's plans, which
    /// touch no other config.
    private func commit(_ plan: PhoneDataConfigPlan) async throws {
        do {
            try await stage(plan.network, config: "network")
            try await stage(plan.firewall, config: "firewall")
            if !plan.network.isEmpty { try await uciCommit(config: "network") }
            if !plan.firewall.isEmpty { try await uciCommit(config: "firewall") }
        } catch {
            if !plan.network.isEmpty { try? await uciRevert(config: "network") }
            if !plan.firewall.isEmpty { try? await uciRevert(config: "firewall") }
            throw error
        }

        // The router's commit already makes procd reload what changed; these only make it
        // immediate. Some logins aren't allowed to run them, and that is not a failure.
        if !plan.network.isEmpty {
            _ = try? await fileExec(command: "/etc/init.d/network", params: ["reload"])
        }
        if !plan.firewall.isEmpty {
            _ = try? await fileExec(command: "/etc/init.d/firewall", params: ["reload"])
        }
    }

    private func stage(_ edits: [PhoneDataUciEdit], config: String) async throws {
        for edit in edits {
            switch edit {
            case .add(let type, let name, let values):
                try await uciAdd(config: config, type: type, name: name, values: values)
            case .set(let section, let values):
                try await uciSet(config: config, section: section, values: values)
            case .delete(let section):
                try await uciDelete(config: config, section: section)
            case .deleteOption(let section, let option):
                try await uciDeleteOption(config: config, section: section, option: option)
            }
        }
    }

    // MARK: - Setup and removal over Wi-Fi

    /// Sets the router up for Phone Data over Wi-Fi, or brings an existing setup up to date (new
    /// keys, another hotspot). Safe to run again. The iPhone's hotspot is saved as a TravelMate
    /// network (the way TravelMate's tab saves one) whose tunnel is `phone_wifi`, and moved ahead
    /// of the other saved networks so TravelMate prefers it; the tunnel, its place in the `wan`
    /// zone and TravelMate's VPN settings come with it (see `PhoneDataRouterConfig.wifiSetupPlan`).
    ///
    /// Everything is staged first and committed together, then TravelMate is restarted once: the
    /// router's Wi-Fi may restart with the commit, so nothing is left for after it but that
    /// restart, which TravelMate's own config trigger would do anyway. A failure before the
    /// commits are in drops what was staged.
    /// - Throws: `PhoneDataRouterError.travelmateMissing` when the router has no TravelMate.
    func applyPhoneDataWifi(
        keys: PhoneDataRouterKeys, hotspot: PhoneDataHotspot, password: String
    ) async throws {
        async let network = uciGet(config: "network")
        async let firewall = uciGet(config: "firewall")
        async let travelmate = uciGetIfPresent(config: "travelmate")
        let (networkConfig, firewallConfig, travelmateConfig) =
            try await (network, firewall, travelmate)
        guard let travelmateConfig else { throw PhoneDataRouterError.travelmateMissing }
        let plan = try PhoneDataRouterConfig.wifiSetupPlan(
            network: networkConfig, firewall: firewallConfig, travelmate: travelmateConfig,
            privateKey: keys.routerPrivateKey, address: keys.routerAddress,
            phonePublicKey: keys.phonePublicKey)

        try await stageAndCommit {
            let station = try await stageTravelmateUplink(
                ssid: hotspot.ssid, password: password, device: hotspot.device,
                encryption: hotspot.encryption,
                uplinkValues: PhoneDataRouterConfig.wifiUplinkValues)
            try await stage(plan.network, config: "network")
            try await stage(plan.firewall, config: "firewall")
            try await stage(plan.travelmate, config: "travelmate")
            // Read after the station is staged, so it is in the list being ordered.
            let wireless = try await uciGet(config: "wireless")
            if let order = PhoneDataRouterConfig.wirelessOrder(
                wireless: wireless, phoneSection: station)
            {
                try await uciOrder(config: "wireless", sections: order)
            }
            // The router's Wi-Fi may restart with the `wireless` commit, so it comes right before
            // the last one, like when TravelMate's tab saves a network.
            return plan.firewall.isEmpty
                ? ["network", "wireless", "travelmate"]
                : ["network", "firewall", "wireless", "travelmate"]
        }
        _ = try? await travelmateRestart()
    }

    /// Takes Wi-Fi sharing off the router: the iPhone's saved network (its wifi-iface and its
    /// TravelMate uplink: left in place the router would keep joining the hotspot, and without
    /// the tunnel that is plain hotspot data), `phone_wifi` and its peer, and `phone_wifi` in the
    /// `wan` zone and in TravelMate's VPN settings. The packages and the cable's setup stay.
    /// Like setup it is staged, committed together, and followed by one TravelMate restart.
    func removePhoneDataWifi() async throws {
        async let network = uciGet(config: "network")
        async let firewall = uciGet(config: "firewall")
        async let travelmate = uciGetIfPresent(config: "travelmate")
        async let wireless = uciGetIfPresent(config: "wireless")
        let (networkConfig, firewallConfig, travelmateConfig, wirelessConfig) =
            try await (network, firewall, travelmate, wireless)

        let travelmateValues = travelmateConfig ?? .null
        let plan = PhoneDataRouterConfig.wifiRemovalPlan(
            network: networkConfig, firewall: firewallConfig, travelmate: travelmateValues)
        let uplinks = PhoneDataRouterConfig.wifiUplinks(in: travelmateValues)
        guard !plan.isEmpty || !uplinks.isEmpty else { return }

        try await stageAndCommit {
            var removedStations: Set<String> = []
            for uplink in uplinks {
                let station = try await stageTravelmateUplinkRemoval(
                    ssid: uplink.ssid, device: uplink.device, uplinkSection: uplink.section,
                    travelmate: travelmateValues, wireless: wirelessConfig ?? .null,
                    taken: removedStations)
                if let station { removedStations.insert(station) }
            }
            try await stage(plan.network, config: "network")
            try await stage(plan.firewall, config: "firewall")
            try await stage(plan.travelmate, config: "travelmate")

            var commits: [String] = []
            if !plan.network.isEmpty { commits.append("network") }
            if !plan.firewall.isEmpty { commits.append("firewall") }
            if !removedStations.isEmpty { commits.append("wireless") }
            if !uplinks.isEmpty || !plan.travelmate.isEmpty { commits.append("travelmate") }
            return commits
        }
        _ = try? await travelmateRestart()
    }

    /// Runs `stageEdits`, which stages edits and returns the configs it staged them in, in the
    /// order to commit them, then commits those. A failure anywhere up to the last commit drops
    /// what is still staged in any config Wi-Fi setup and removal touch: `uci get` would
    /// otherwise keep showing values that were never applied, and the next unrelated commit
    /// would ship them. A commit that fails after an earlier one went through leaves that config
    /// changed; setup and removal are safe to run again.
    private func stageAndCommit(stageEdits: () async throws -> [String]) async throws {
        do {
            let configs = try await stageEdits()
            for config in configs {
                try await uciCommit(config: config)
            }
        } catch {
            for config in ["network", "firewall", "wireless", "travelmate"] {
                try? await uciRevert(config: config)
            }
            throw error
        }
    }
}

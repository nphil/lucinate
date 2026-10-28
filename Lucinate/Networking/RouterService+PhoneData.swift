import Foundation

/// Router side of Phone Data: the packages it needs, finding the iPhone on the router's USB
/// port, and setting up or removing the interfaces. What goes into uci is decided by
/// `PhoneDataRouterConfig`; this runs the reads and the writes.
extension RouterService {
    /// What the router must have installed: the iPhone's USB network driver, the program that
    /// pairs with the iPhone, and WireGuard.
    static let phoneDataPackages = [
        "kmod-usb-net-ipheth", "usbmuxd", "kmod-wireguard", "wireguard-tools",
    ]

    // MARK: - State

    /// Everything the Phone Data screen shows, read together. One failed read fails the whole
    /// call: a half-read state would show a router as not set up when it merely didn't answer.
    ///
    /// The installed-package list is by far the heaviest read (apk runs on the router, which
    /// may be a small one that is also carrying the household's internet). A caller that
    /// polls passes what a recent check found as `knownMissingPackages` to skip it; nil
    /// reads the list now.
    func phoneDataState(knownMissingPackages: [String]? = nil) async throws
        -> PhoneDataRouterState
    {
        async let network = uciGet(config: "network")
        async let firewall = uciGet(config: "firewall")
        async let dump = interfaceDump()
        async let missing = missingPhoneDataPackages(known: knownMissingPackages)
        async let usbDevice = findIPhoneUSBDevice()

        let (networkConfig, firewallConfig, interfaces, missingPackages, device) =
            try await (network, firewall, dump, missing, usbDevice)
        return PhoneDataRouterConfig.state(
            network: networkConfig, firewall: firewallConfig, interfaceDump: interfaces,
            missingPackages: missingPackages, usbDevice: device)
    }

    private func missingPhoneDataPackages(known: [String]?) async throws -> [String] {
        if let known { return known }
        let installed: [PackageCatalog.Entry]
        do {
            installed = try await installedPackages()
        } catch let error as UbusError where error.isAccessDenied {
            throw PhoneDataRouterError.packagesNotPermitted
        }
        return PhoneDataRouterConfig.missingPackages(
            required: Self.phoneDataPackages, installed: installed.map { $0.name })
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

    // MARK: - Setup and removal

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
    /// "not configured"; running setup again finishes the job.
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
}

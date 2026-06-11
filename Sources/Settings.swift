import Foundation
import ServiceManagement

// User preferences, persisted in UserDefaults and applied live.

final class Settings: ObservableObject {
    static let sectionKeys: [StatKind: String] = [
        .network: "enabledNetwork", .cpu: "enabledCPU", .memory: "enabledMemory",
        .disk: "enabledDisk", .internet: "enabledInternet",
    ]

    @Published var enabledSections: Set<StatKind> {
        didSet {
            for (kind, key) in Self.sectionKeys {
                UserDefaults.standard.set(enabledSections.contains(kind), forKey: key)
            }
        }
    }
    /// Process list (ps) refresh, seconds.
    @Published var psInterval: Double {
        didSet { UserDefaults.standard.set(psInterval, forKey: "psInterval") }
    }
    /// Background per-process network snapshot cadence, seconds.
    @Published var snapshotCadence: Double {
        didSet { UserDefaults.standard.set(snapshotCadence, forKey: "snapshotCadence") }
    }
    /// Connectivity probe interval, seconds.
    @Published var probeInterval: Double {
        didSet { UserDefaults.standard.set(probeInterval, forKey: "probeInterval") }
    }
    /// Mirrors SMAppService state; setting it registers/unregisters.
    @Published var launchAtLogin: Bool
    @Published var launchAtLoginError: String?

    init() {
        let defaults = UserDefaults.standard
        var sections: Set<StatKind> = []
        for (kind, key) in Self.sectionKeys {
            if defaults.object(forKey: key) == nil || defaults.bool(forKey: key) {
                sections.insert(kind)
            }
        }
        enabledSections = sections
        let storedPs = defaults.double(forKey: "psInterval")
        psInterval = storedPs > 0 ? storedPs : 3
        let storedSnapshot = defaults.double(forKey: "snapshotCadence")
        snapshotCadence = storedSnapshot > 0 ? storedSnapshot : 6
        let storedProbe = defaults.double(forKey: "probeInterval")
        probeInterval = storedProbe > 0 ? storedProbe : 30
        launchAtLogin = Self.loginItemEnabled
    }

    func toggleSection(_ kind: StatKind) {
        if enabledSections.contains(kind) {
            enabledSections.remove(kind)
        } else {
            enabledSections.insert(kind)
        }
    }

    // MARK: Launch at login (SMAppService, macOS 13+)

    static var loginItemSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    static var loginItemEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func applyLaunchAtLogin(_ enable: Bool) {
        guard #available(macOS 13.0, *) else {
            launchAtLoginError = "Requires macOS 13 or newer"
            launchAtLogin = false
            return
        }
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = Self.loginItemEnabled
    }
}

import AppKit
import Yams

struct RimeInstallation: Identifiable {
    let name: String
    let dataDirectory: URL
    let syncDirectory: URL?
    let detectionError: String?
    let canExportWithSquirrel: Bool

    var id: String { dataDirectory.path }

    static var squirrelApp: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standard = [
            home.appendingPathComponent("Library/Input Methods/Squirrel.app"),
            URL(fileURLWithPath: "/Library/Input Methods/Squirrel.app")
        ]
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: SquirrelMaintenance.bundleID)
            ?? standard.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func discover() -> [RimeInstallation] {
        let fs = FileManager.default
        let home = fs.homeDirectoryForCurrentUser
        let inputMethods = [home.appendingPathComponent("Library/Input Methods"), URL(fileURLWithPath: "/Library/Input Methods")]
        func installed(_ app: String) -> Bool {
            inputMethods.contains { fs.fileExists(atPath: $0.appendingPathComponent(app).path) }
        }

        var result: [RimeInstallation] = []
        let squirrelData = home.appendingPathComponent("Library/Rime", isDirectory: true)
        var isDirectory: ObjCBool = false
        let hasUserData = fs.fileExists(atPath: squirrelData.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let squirrelInstalled = squirrelApp != nil
        if squirrelInstalled || hasUserData {
            result.append(inspect(name: squirrelInstalled ? "Squirrel" : "Rime", data: squirrelData, squirrel: squirrelInstalled))
        }
        if installed("Fcitx5.app") {
            let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                ?? home.appendingPathComponent(".local/share")
            let data = base.appendingPathComponent("fcitx5/rime", isDirectory: true)
            if fs.fileExists(atPath: data.appendingPathComponent("installation.yaml").path) {
                result.append(inspect(name: "Fcitx5", data: data, squirrel: false))
            }
        }
        return result
    }

    static func inspect(name: String, data: URL, squirrel: Bool) -> Self {
        struct Settings: Decodable { let sync_dir: String? }
        let config = data.appendingPathComponent("installation.yaml")
        do {
            var directory = data.appendingPathComponent("sync", isDirectory: true)
            if FileManager.default.fileExists(atPath: config.path) {
                let yaml = try String(contentsOf: config, encoding: .utf8)
                if let value = try YAMLDecoder().decode(Settings.self, from: yaml).sync_dir, !value.isEmpty {
                    let path = (value as NSString).expandingTildeInPath
                    directory = URL(fileURLWithPath: path, isDirectory: true, relativeTo: data).standardizedFileURL
                }
            }
            return Self(name: name, dataDirectory: data, syncDirectory: directory, detectionError: nil, canExportWithSquirrel: squirrel)
        } catch {
            return Self(name: name, dataDirectory: data, syncDirectory: nil, detectionError: L10n.syncFolderUnreadable(config.path), canExportWithSquirrel: squirrel)
        }
    }
}

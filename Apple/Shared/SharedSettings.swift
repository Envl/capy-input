import Foundation

enum SharedSettings {
    static let group: String = {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "CapyAppGroup") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured?.isEmpty == false ? configured! : "group.com.capyinput.keyboard"
    }()
    static let defaults: UserDefaults = UserDefaults(suiteName: group) ?? .standard
}

import Foundation
import os

enum InterfaceLanguage: String, CaseIterable {
    case system
    case simplified = "zh-Hans"
    case traditional = "zh-Hant"
    case english = "en"

    static let preferenceKey = "appInterfaceLanguage"
    private static let keyboardKey = "keyboardInterfaceLanguage"
    private static let resources = OSAllocatedUnfairLock(initialState: (bundle: Bundle.main, locale: Locale.autoupdatingCurrent))

    var title: String {
        switch self {
        case .system: L10n.followSystem
        case .simplified: "简体中文"
        case .traditional: "繁體中文"
        case .english: "English"
        }
    }

    static var saved: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    static var currentBundle: Bundle { resources.withLock { $0.bundle } }
    static var currentLocale: Locale { resources.withLock { $0.locale } }

    func apply() {
        Self.use(self)
        #if os(iOS)
        // Share the resolved override with the keyboard, which runs in another app's process environment.
        let language = self == .system ? Self.systemAppOverride : rawValue
        let defaults = SharedSettings.defaults
        if defaults.string(forKey: Self.keyboardKey) != language {
            defaults.set(language, forKey: Self.keyboardKey)
        }
        #endif
    }

    private static func use(_ choice: Self) {
        guard choice != .system,
              let url = Bundle.main.url(forResource: choice.rawValue, withExtension: "lproj"),
              let localized = Bundle(url: url) else {
            resources.withLock { $0 = (.main, .autoupdatingCurrent) }
            return
        }
        var components = Locale.Components(locale: .current)
        let region = components.languageComponents.region
        components.languageComponents = Locale.Language.Components(identifier: choice.rawValue)
        components.languageComponents.region = region
        let locale = Locale(components: components)
        resources.withLock { $0 = (localized, locale) }
    }

    #if os(iOS)
    private static var systemAppOverride: String? {
        let app = Bundle.main
        guard let id = app.bundleIdentifier, let language = app.preferredLocalizations.first else { return nil }
        let preferences = UserDefaults.standard
        let global = preferences.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        let systemLanguage = global.flatMap { Bundle.preferredLocalizations(from: app.localizations, forPreferences: $0).first }
        let explicit = preferences.persistentDomain(forName: id)?["AppleLanguages"] != nil
            || preferences.volatileDomain(forName: UserDefaults.argumentDomain)["AppleLanguages"] != nil
        return explicit || (systemLanguage != nil && systemLanguage != language) ? language : nil
    }

    static func refreshKeyboard() -> String {
        let choice = SharedSettings.defaults.string(forKey: keyboardKey).flatMap(Self.init(rawValue:)) ?? .system
        use(choice)
        return choice == .system ? (Bundle.main.preferredLocalizations.first ?? "en") : choice.rawValue
    }
    #endif
}

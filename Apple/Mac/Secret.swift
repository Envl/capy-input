import Foundation
import Security

enum Secret {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: Bundle.main.bundleIdentifier ?? "CapyCompanion",
        kSecAttrAccount as String: "sync"
    ] }

    static func load() -> String {
        read(query) ?? ""
    }

    private static func read(_ source: [String: Any]) -> String? {
        var lookup = source
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ value: String) throws {
        guard store(value, matching: query) == errSecSuccess else { throw AppError(L10n.cannotSaveTheSyncKeyInKeychain) }
    }

    private static func store(_ value: String, matching query: [String: Any]) -> OSStatus {
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecItemNotFound { return status }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
}

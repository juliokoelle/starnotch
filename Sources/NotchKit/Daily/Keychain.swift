import Foundation
import NotchCore
import Security

/// Secrets of the daily tools (the Oura token, WHOOP's client secret and tokens) as generic
/// passwords in the login Keychain, under the app's identifier. Nothing else reads them.
enum Keychain {
    enum Item: String {
        case ouraToken = "oura.token"
        case whoopSecret = "whoop.client-secret"
        case whoopToken = "whoop.token"
    }

    private static var service: String { "\(Brand.identifier).daily" }

    private static func query(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: item.rawValue]
    }

    static func string(_ item: Item) -> String? {
        var query = query(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the value; an empty one deletes the item.
    @discardableResult
    static func set(_ value: String?, for item: Item) -> Bool {
        let query = query(item)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func codable<T: Decodable>(_ type: T.Type, _ item: Item) -> T? {
        string(item).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

    static func setCodable<T: Encodable>(_ value: T?, for item: Item) {
        set(value.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }, for: item)
    }
}

import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.cozyproductivity.app.googleoauth"

    static func saveData(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(insertQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func loadData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func saveCodable<T: Codable>(_ value: T, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return saveData(data, account: account)
    }

    static func loadCodable<T: Codable>(_ type: T.Type, account: String) -> T? {
        guard let data = loadData(account: account) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

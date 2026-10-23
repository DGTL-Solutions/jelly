import Foundation
import Security

/// Saved accounts, the active one and the device ID, in the keychain. The Top Shelf extension shares the app's
/// keychain access group, so it can show "Weiterschauen" for the active profile without its own sign-in.
struct AccountStore: Codable, Equatable {
    var accounts: [Session] = []
    var activeKey: String?
    var deviceID: String

    var active: Session? { accounts.first { $0.key == activeKey } ?? accounts.first }
}

extension Session {
    /// One account per user and server.
    var key: String { "\(serverKey)/\(userID)" }
    /// The server the account belongs to; profiles on the same server share it.
    var serverKey: String { serverID ?? server.absoluteString }
}

enum SecureStore {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "de.jelly.tv", kSecAttrAccount as String: account]
    }

    static func save(_ store: AccountStore) throws {
        let data = try JSONEncoder().encode(store)
        let status = SecItemUpdate(query("accounts") as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query("accounts")
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw JellyError.keychain }
        } else if status != errSecSuccess { throw JellyError.keychain }
    }

    /// Loads the account list, migrating the single session stored by earlier versions.
    static func load(fallbackDeviceID: String) -> AccountStore {
        if let data = read("accounts"), let store = try? JSONDecoder().decode(AccountStore.self, from: data) { return store }
        var store = AccountStore(deviceID: fallbackDeviceID)
        if let data = read("session"), let session = try? JSONDecoder().decode(Session.self, from: data) {
            store.accounts = [session]
            store.activeKey = session.key
            if (try? save(store)) != nil { SecItemDelete(query("session") as CFDictionary) }
        }
        return store
    }

    /// Further secrets next to the account list, e.g. the Jellyseerr session of a profile. `nil` deletes.
    static func setData(_ data: Data?, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let data else { return }
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func data(for account: String) -> Data? { read(account) }

    private static func read(_ account: String) -> Data? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

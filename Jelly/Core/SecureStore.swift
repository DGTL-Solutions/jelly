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
    /// On Apple TV Jelly runs as the person who is active (Control Center › users): settings and the profile in use are
    /// kept per person by tvOS. The sign-ins themselves live in the keychain all users share, so nobody signs in twice.
    /// `shared: false` is each person's own keychain – and where everything was before Jelly 2.0.
    private static func query(_ account: String, shared: Bool = true) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "de.jelly.tv",
                                    kSecAttrAccount as String: account]
        #if os(tvOS)
        if shared && sharedKeychainWorks { query[kSecUseUserIndependentKeychain as String] = true }
        #elseif os(macOS)
        // The Mac's modern keychain, the one iPhone and iPad have: no password prompts, no access lists.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    #if os(macOS)
    /// The modern keychain needs an app signed for a team. A build from source without one keeps its secrets in files
    /// inside the app's own sandbox container instead of asking the login keychain (which would prompt at every build).
    private static let fileFolder: URL? = {
        var probe = query("probe")
        probe[kSecReturnData as String] = true
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(probe as CFDictionary, &result)
        if status == errSecSuccess || status == errSecItemNotFound { return nil }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jelly-Secrets", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private static func file(_ account: String) -> URL? {
        fileFolder?.appendingPathComponent(Data(account.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_"))
    }
    #endif

    #if os(tvOS)
    /// Without the "runs as current user" entitlement (builds from source, the simulator) the shared keychain refuses
    /// to work; then there is only the one keychain, as before.
    private static let sharedKeychainWorks: Bool = {
        var probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "de.jelly.tv",
                                    kSecAttrAccount as String: "probe", kSecUseUserIndependentKeychain as String: true,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(probe as CFDictionary, &result)
        probe.removeAll()
        return status == errSecSuccess || status == errSecItemNotFound
    }()
    #endif

    static func save(_ store: AccountStore) throws {
        let data = try JSONEncoder().encode(store)
        #if os(macOS)
        if let file = file("accounts") { try data.write(to: file, options: .atomic); return }
        #endif
        let status = SecItemUpdate(query("accounts") as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query("accounts")
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw JellyError.keychain }
        } else if status != errSecSuccess { throw JellyError.keychain }
        #if os(tvOS)
        // Which profile is in use is each Apple TV user's own.
        write(store.activeKey.map { Data($0.utf8) }, for: "active", shared: false)
        #endif
    }

    /// Loads the account list, migrating the single session stored by earlier versions.
    static func load(fallbackDeviceID: String) -> AccountStore {
        if let data = read("accounts"), var store = try? JSONDecoder().decode(AccountStore.self, from: data) {
            #if os(tvOS)
            if let own = read("active", shared: false).flatMap({ String(data: $0, encoding: .utf8) }) {
                store.activeKey = own
            } else if sharedKeychainWorks, read("accounts", shared: false) == nil {
                // An Apple TV user who opens Jelly for the first time: no profile yet, "Wer schaut gerade?" decides.
                store.activeKey = store.accounts.count == 1 ? store.accounts.first?.key : nil
            }
            #endif
            return store
        }
        #if os(tvOS)
        // Sign-ins from before 2.0 sit in this user's own keychain: they move to the shared one.
        if let data = read("accounts", shared: false), let store = try? JSONDecoder().decode(AccountStore.self, from: data) {
            try? save(store)
            return store
        }
        #endif
        var store = AccountStore(deviceID: fallbackDeviceID)
        if let data = read("session", shared: false), let session = try? JSONDecoder().decode(Session.self, from: data) {
            store.accounts = [session]
            store.activeKey = session.key
            if (try? save(store)) != nil { SecItemDelete(query("session", shared: false) as CFDictionary) }
        }
        return store
    }

    /// Further secrets next to the account list, e.g. the Jellyseerr session of a profile. `nil` deletes.
    static func setData(_ data: Data?, for account: String) {
        write(data, for: account, shared: true)
    }

    private static func write(_ data: Data?, for account: String, shared: Bool) {
        #if os(macOS)
        if let file = file(account) {
            if let data { try? data.write(to: file, options: .atomic) } else { try? FileManager.default.removeItem(at: file) }
            return
        }
        #endif
        SecItemDelete(query(account, shared: shared) as CFDictionary)
        guard let data else {
            #if os(tvOS)
            if shared { SecItemDelete(query(account, shared: false) as CFDictionary) }
            #endif
            return
        }
        var attributes = query(account, shared: shared)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Reads the shared keychain first, then (Apple TV) what an earlier version left in the user's own.
    static func data(for account: String) -> Data? {
        if let data = read(account) { return data }
        #if os(tvOS)
        return read(account, shared: false)
        #else
        return nil
        #endif
    }

    private static func read(_ account: String, shared: Bool = true) -> Data? {
        #if os(macOS)
        if let file = file(account) { return try? Data(contentsOf: file) }
        #endif
        var attributes = query(account, shared: shared)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

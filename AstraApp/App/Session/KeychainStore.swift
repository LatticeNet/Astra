import Foundation
import LocalAuthentication
import Security

/// Credential storage (section 7.2). The PAT is readable after first unlock,
/// so background refresh can use it; the optional kept session is guarded by
/// user presence and read only in the foreground.
enum KeychainStore {
    static let service = "org.roobli.astra"

    private enum Account {
        static let pat = "pat"
        static let session = "session"
        // v2 accounts, migrated or removed on first read.
        static let legacyToken = "lattice.token"
        static let legacyOthers = ["lattice.sessionCookie", "lattice.csrfToken", "bark.deviceKey"]
    }

    enum Failure: Error, LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let status):
                (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
            }
        }
    }

    // MARK: PAT

    /// The API token, if one is stored. Moves a v2 token to the v3 account
    /// once and removes the v2 session items, which were not user-presence guarded.
    static func loadPAT() -> String? {
        if let data = read(account: Account.pat), let token = String(data: data, encoding: .utf8), !token.isEmpty {
            return token
        }
        guard let data = read(account: Account.legacyToken), let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            return nil
        }
        try? savePAT(token)
        delete(account: Account.legacyToken)
        Account.legacyOthers.forEach(delete(account:))
        return token
    }

    static func savePAT(_ token: String) throws {
        let query = baseQuery(account: Account.pat)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    static var hasPAT: Bool { loadPAT() != nil }

    // MARK: Kept session

    /// Stores the session behind user presence ("Keep the session on this iPhone").
    static func saveSession(_ session: LatticeLoginSession) throws {
        let query = baseQuery(account: Account.session)
        SecItemDelete(query as CFDictionary)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else {
            throw error?.takeRetainedValue() ?? Failure.status(errSecParam)
        }
        var item = query
        item[kSecValueData as String] = try JSONEncoder().encode(session)
        item[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    /// Reads the kept session after Face ID or the passcode. Foreground only;
    /// background refresh never calls this.
    static func loadSession(reason: String) async -> LatticeLoginSession? {
        let data: Data? = await Task.detached {
            let context = LAContext()
            context.localizedReason = reason
            var query = baseQuery(account: Account.session)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return status == errSecSuccess ? result as? Data : nil
        }.value
        return data.flatMap { try? JSONDecoder().decode(LatticeLoginSession.self, from: $0) }
    }

    static var hasKeptSession: Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(account: Account.session)
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func deleteSession() {
        delete(account: Account.session)
    }

    /// Sign out: both items, and anything v2 left behind.
    static func deleteAll() {
        delete(account: Account.pat)
        delete(account: Account.session)
        delete(account: Account.legacyToken)
        Account.legacyOthers.forEach(delete(account:))
    }

    // MARK: Plumbing

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

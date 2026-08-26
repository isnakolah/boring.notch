import CryptoKit
import Foundation
import Security

/// Boring owns Tutor-history key material. Host and Gateway never receive it.
/// A missing/corrupt existing key is an error, not permission to replace
/// ciphertext with an unreadable new lineage.
enum TutorHistoryKey {
    static let service = "theboringteam.boringnotch.tutor-history"
    static let account = "capture-master-v1"

    enum Failure: Error, LocalizedError {
        case keychain(OSStatus)
        case invalidStoredKey

        var errorDescription: String? {
            switch self {
            case .keychain(let status): "Tutor history Keychain error \(status)"
            case .invalidStoredKey: "Tutor history Keychain key is invalid"
            }
        }
    }

    static func loadOrCreate() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else { throw Failure.invalidStoredKey }
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw Failure.keychain(status) }

        var material = Data(count: 32)
        let randomStatus = material.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw Failure.keychain(randomStatus) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: material,
            // Never migrates through backup/iCloud. This history is device-local.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return SymmetricKey(data: material) }
        // Another Engine instance may have created it between lookup and add.
        if addStatus == errSecDuplicateItem { return try loadOrCreate() }
        throw Failure.keychain(addStatus)
    }
}

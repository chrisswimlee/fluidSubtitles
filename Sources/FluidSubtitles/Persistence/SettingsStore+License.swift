import Combine
import CryptoKit
import Foundation
import Security

extension SettingsStore {
    #if DEBUG
    nonisolated(unsafe) static var licenseVerifyingKeyOverride: Curve25519.Signing.PublicKey?
    #endif

    static var licenseVerifyingKey: Curve25519.Signing.PublicKey {
        #if DEBUG
        if self.isRunningTests, let override = self.licenseVerifyingKeyOverride {
            return override
        }
        #endif
        return CommercialLicense.productionPublicKey
    }

    var commercialLicenseToken: String? {
        let stored = self.readCommercialLicenseToken()?.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored?.isEmpty == false ? stored : nil
    }

    var commercialLicenseRecord: CommercialLicense.Record? {
        guard let token = self.commercialLicenseToken else { return nil }
        if case let .success(record) = CommercialLicense.verify(
            token,
            publicKey: Self.licenseVerifyingKey
        ) {
            return record
        }
        return nil
    }

    var isCommerciallyLicensed: Bool {
        self.commercialLicenseRecord != nil
    }

    var commercialLicenseFailure: CommercialLicense.Failure? {
        guard let token = self.commercialLicenseToken else { return nil }
        if case let .failure(failure) = CommercialLicense.verify(
            token,
            publicKey: Self.licenseVerifyingKey
        ) {
            return failure
        }
        return nil
    }

    @discardableResult
    func activateCommercialLicense(
        _ token: String,
        now: Date = Date()
    ) -> Result<CommercialLicense.Record, CommercialLicense.Failure> {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        switch CommercialLicense.verify(trimmed, publicKey: Self.licenseVerifyingKey, now: now) {
        case let .success(record):
            do {
                try self.writeCommercialLicenseToken(trimmed)
                self.objectWillChange.send()
                return .success(record)
            } catch {
                return .failure(.notSaved)
            }
        case let .failure(failure):
            return .failure(failure)
        }
    }

    func removeCommercialLicense() {
        self.objectWillChange.send()
        try? self.writeCommercialLicenseToken(nil)
    }

    private func readCommercialLicenseToken() -> String? {
        if Self.isRunningTests {
            return self.defaults.string(forKey: LicenseDefaults.token)
        }
        if let keychain = try? CommercialLicenseKeychain.read() {
            return keychain
        }
        return self.defaults.string(forKey: LicenseDefaults.token)
    }

    private func writeCommercialLicenseToken(_ token: String?) throws {
        if Self.isRunningTests {
            if let token {
                self.defaults.set(token, forKey: LicenseDefaults.token)
            } else {
                self.defaults.removeObject(forKey: LicenseDefaults.token)
            }
            return
        }
        try CommercialLicenseKeychain.write(token)
        if let token {
            self.defaults.set(token, forKey: LicenseDefaults.token)
        } else {
            self.defaults.removeObject(forKey: LicenseDefaults.token)
        }
    }

    private enum LicenseDefaults {
        static let token = "CommercialLicenseToken"
    }
}

private enum CommercialLicenseKeychain {
    static func read() throws -> String? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainServiceError.unhandled(status)
        }
        guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainServiceError.invalidData
        }
        return token
    }

    static func write(_ token: String?) throws {
        if let token {
            let data = Data(token.utf8)
            let status: OSStatus
            if try self.read() != nil {
                status = SecItemUpdate(
                    self.query as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
            } else {
                var add = self.query
                add[kSecValueData as String] = data
                status = SecItemAdd(add as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                throw KeychainServiceError.unhandled(status)
            }
        } else {
            let status = SecItemDelete(self.query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainServiceError.unhandled(status)
            }
        }
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: FluidProduct.licenseKeychainService,
            kSecAttrAccount as String: FluidProduct.licenseKeychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

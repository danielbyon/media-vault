//
//  VaultCredentialClient.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import CommonCrypto
import Dependencies
import DependenciesMacros
import Foundation
import Security

/// The user-facing credential forms supported by the vault boundary.
public enum VaultCredentialKind: String, Codable, Equatable, Sendable {
    /// A calculator-compatible numeric credential.
    case pin

    /// A password that is passed to the platform derivation routine without normalization.
    case password
}

/// The non-secret configuration needed by the application to choose an unlock path.
public struct VaultCredentialConfiguration: Codable, Equatable, Sendable {
    /// The form of the configured credential.
    public let kind: VaultCredentialKind

    /// Whether a numeric credential can be entered through the calculator's hidden path.
    public let usesHiddenEntry: Bool

    /// Creates a non-secret credential configuration.
    public init(kind: VaultCredentialKind, usesHiddenEntry: Bool) {
        self.kind = kind
        self.usesHiddenEntry = usesHiddenEntry
    }
}

/// The result of checking a candidate against the configured credential.
public enum VaultCredentialVerificationResult: Equatable, Sendable {
    /// The candidate matched the configured verifier.
    case succeeded

    /// The candidate did not match the configured verifier.
    case incorrect

    /// The credential record could not be read or verified.
    case unavailable
}

/// Failures reported while creating or loading the vault credential boundary.
public enum VaultCredentialError: Error, Equatable, Sendable {
    /// The device credential record could not be read or written.
    case unavailable

    /// A credential has already been configured and cannot be replaced by this ticket.
    case alreadyConfigured

    /// The supplied credential or persisted record is outside the supported contract.
    case invalidCredential
}

/// The application-owned credential boundary.
///
/// Feature reducers see only configuration, setup, and verification operations. Keychain access,
/// record encoding, salts, work factors, and verifier bytes remain private to the live adapter.
@DependencyClient
public struct VaultCredentialClient: Sendable {
    /// Loads non-secret credential configuration, if a record exists.
    public var loadConfiguration: @Sendable () async throws -> VaultCredentialConfiguration? = {
        nil
    }

    /// Creates the device-local credential record.
    public var configure: @Sendable (
        VaultCredentialKind,
        String,
        Bool,
    ) async throws -> VaultCredentialConfiguration = { _, _, _ in
        throw VaultCredentialError.unavailable
    }

    /// Checks a candidate without exposing verifier material to the caller.
    public var verify: @Sendable (String) async -> VaultCredentialVerificationResult = { _ in
        .unavailable
    }
}

extension VaultCredentialClient: DependencyKey {
    /// The live credential implementation backed by a non-synchronizable Keychain item.
    public static var liveValue: Self {
        VaultCredentialLiveAdapter(storage: KeychainCredentialStorage()).client
    }

    /// The inert credential implementation used by tests unless overridden.
    public static var testValue: Self {
        Self()
    }
}

extension DependencyValues {
    /// The vault's app-owned credential dependency.
    public var vaultCredential: VaultCredentialClient {
        get { self[VaultCredentialClient.self] }
        set { self[VaultCredentialClient.self] = newValue }
    }
}

/// The narrow persistence seam used by the live adapter and its deterministic tests.
protocol VaultCredentialStorage: Sendable {
    func load() async throws -> Data?
    func add(_ data: Data) async throws
    func update(_ data: Data) async throws
}

/// Coordinates credential record construction and verification without exposing its representation.
struct VaultCredentialLiveAdapter: Sendable {
    private let storage: any VaultCredentialStorage
    private let randomBytes: @Sendable (Int) throws -> Data
    private let now: @Sendable () -> Date

    init(
        storage: any VaultCredentialStorage,
        randomBytes: @escaping @Sendable (Int) throws -> Data = secureRandomBytes,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.storage = storage
        self.randomBytes = randomBytes
        self.now = now
    }

    var client: VaultCredentialClient {
        let storageProvider = storage
        let randomBytesProvider = randomBytes
        let nowProvider = now
        let verificationCoordinator = VaultCredentialVerificationCoordinator(
            storage: storageProvider,
            now: nowProvider,
        )
        return VaultCredentialClient(
            loadConfiguration: {
                try await Self.loadConfiguration(from: storageProvider)
            },
            configure: { kind, credential, usesHiddenEntry in
                try await Self.configure(
                    kind: kind,
                    credential: credential,
                    usesHiddenEntry: usesHiddenEntry,
                    storage: storageProvider,
                    randomBytes: randomBytesProvider,
                )
            },
            verify: { candidate in
                await verificationCoordinator.verify(candidate: candidate)
            },
        )
    }

    private static func loadConfiguration(
        from storage: any VaultCredentialStorage,
    ) async throws -> VaultCredentialConfiguration? {
        guard let data = try await storage.load() else {
            return nil
        }

        do {
            return try CredentialRecord.decode(data).configuration
        } catch let error as VaultCredentialError {
            throw error
        } catch {
            throw VaultCredentialError.unavailable
        }
    }

    private static func configure(
        kind: VaultCredentialKind,
        credential: String,
        usesHiddenEntry: Bool,
        storage: any VaultCredentialStorage,
        randomBytes: @Sendable (Int) throws -> Data,
    ) async throws -> VaultCredentialConfiguration {
        guard VaultCredentialValidation.isValid(
            kind: kind,
            credential: credential,
            usesHiddenEntry: usesHiddenEntry,
        ) else {
            throw VaultCredentialError.invalidCredential
        }

        let salt = try randomBytes(CredentialDerivation.saltLength)
        guard salt.count == CredentialDerivation.saltLength else {
            throw VaultCredentialError.unavailable
        }

        let verifier = try await CredentialDerivation.deriveAsync(
            credential,
            salt: salt,
            workFactor: CredentialDerivation.workFactor,
        )
        let record = CredentialRecord(
            kind: kind,
            usesHiddenEntry: kind == .pin && usesHiddenEntry,
            salt: salt,
            workFactor: CredentialDerivation.workFactor,
            verifier: verifier,
        )

        let encodedRecord = try record.encoded()
        do {
            try await storage.add(encodedRecord)
        } catch let error as VaultCredentialError {
            throw error
        } catch {
            throw VaultCredentialError.unavailable
        }

        return record.configuration
    }
}

/// Serializes verification and persists a short retry cooldown in the credential record.
private actor VaultCredentialVerificationCoordinator {
    private static let retryDelay: TimeInterval = 1

    private let storage: any VaultCredentialStorage
    private let now: @Sendable () -> Date

    init(storage: any VaultCredentialStorage, now: @escaping @Sendable () -> Date) {
        self.storage = storage
        self.now = now
    }

    func verify(candidate: String) async -> VaultCredentialVerificationResult {
        guard !candidate.isEmpty else {
            return .incorrect
        }

        do {
            guard let data = try await storage.load() else {
                return .unavailable
            }

            let record = try CredentialRecord.decode(data)
            let currentDate = now()
            if let retryAfter = record.retryAfter, currentDate < retryAfter {
                return .unavailable
            }

            let verifier = try await CredentialDerivation.deriveAsync(
                candidate,
                salt: record.salt,
                workFactor: record.workFactor,
            )
            guard CredentialDerivation.constantTimeEqual(verifier, record.verifier) else {
                let throttledRecord = record.withRetryAfter(
                    currentDate.addingTimeInterval(Self.retryDelay),
                )
                do {
                    try await storage.update(throttledRecord.encoded())
                } catch {
                    return .unavailable
                }
                return .incorrect
            }
            guard record.retryAfter != nil else {
                return .succeeded
            }

            do {
                try await storage.update(record.withRetryAfter(nil).encoded())
            } catch {
                return .unavailable
            }
            return .succeeded
        } catch {
            return .unavailable
        }
    }
}

private actor KeychainCredentialStorage: VaultCredentialStorage {
    func load() async throws -> Data? {
        try await Task.detached(priority: .userInitiated) {
            try KeychainCredentialOperations.load()
        }.value
    }

    func add(_ data: Data) async throws {
        try await Task.detached(priority: .userInitiated) {
            try KeychainCredentialOperations.add(data)
        }.value
    }

    func update(_ data: Data) async throws {
        try await Task.detached(priority: .userInitiated) {
            try KeychainCredentialOperations.update(data)
        }.value
    }
}

/// Performs synchronous Security framework calls away from cooperative actor executors.
private enum KeychainCredentialOperations {
    private static let service = "vault.credential"
    private static let account = "primary"

    static func load() throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(returnData: true) as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw VaultCredentialError.unavailable
            }

            return data
        case errSecItemNotFound:
            return nil
        default:
            throw VaultCredentialError.unavailable
        }
    }

    static func add(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw VaultCredentialError.alreadyConfigured
        default:
            throw VaultCredentialError.unavailable
        }
    }

    static func update(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary,
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw VaultCredentialError.unavailable
        default:
            throw VaultCredentialError.unavailable
        }
    }

    private static func query(returnData: Bool) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: returnData,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}

private struct CredentialRecord: Codable, Equatable, Sendable {
    private static let currentVersion = 1
    private static let currentAlgorithm = "PBKDF2-HMAC-SHA256"

    let formatVersion: Int
    let algorithm: String
    let kind: VaultCredentialKind
    let usesHiddenEntry: Bool
    let salt: Data
    let workFactor: UInt32
    let verifier: Data
    let retryAfter: Date?

    init(
        kind: VaultCredentialKind,
        usesHiddenEntry: Bool,
        salt: Data,
        workFactor: UInt32,
        verifier: Data,
        retryAfter: Date? = nil,
    ) {
        formatVersion = Self.currentVersion
        algorithm = Self.currentAlgorithm
        self.kind = kind
        self.usesHiddenEntry = usesHiddenEntry
        self.salt = salt
        self.workFactor = workFactor
        self.verifier = verifier
        self.retryAfter = retryAfter
    }

    var configuration: VaultCredentialConfiguration {
        VaultCredentialConfiguration(
            kind: kind,
            usesHiddenEntry: kind == .pin && usesHiddenEntry,
        )
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    func withRetryAfter(_ retryAfter: Date?) -> Self {
        Self(
            kind: kind,
            usesHiddenEntry: usesHiddenEntry,
            salt: salt,
            workFactor: workFactor,
            verifier: verifier,
            retryAfter: retryAfter,
        )
    }

    static func decode(_ data: Data) throws -> Self {
        let record = try JSONDecoder().decode(Self.self, from: data)
        guard record.formatVersion == currentVersion,
              record.algorithm == currentAlgorithm,
              record.salt.count == CredentialDerivation.saltLength,
              record.workFactor >= CredentialDerivation.minimumWorkFactor,
              record.workFactor <= CredentialDerivation.maximumWorkFactor,
              record.verifier.count == CredentialDerivation.outputLength
        else {
            throw VaultCredentialError.unavailable
        }
        guard !(record.kind == .password && record.usesHiddenEntry) else {
            throw VaultCredentialError.unavailable
        }

        return record
    }
}

/// Applies one credential contract at both the feature and storage boundaries.
enum VaultCredentialValidation {
    static func isValid(
        kind: VaultCredentialKind,
        credential: String,
        usesHiddenEntry _: Bool,
    ) -> Bool {
        switch kind {
        case .pin:
            let bytes = Array(credential.utf8)
            return (4 ... 12).contains(bytes.count)
                && bytes.allSatisfy { (0x30 ... 0x39).contains($0) }
        case .password:
            // The product contract intentionally accepts every non-empty exact String. Do not
            // impose a length, whitespace, normalization, or other composition policy here.
            return !credential.isEmpty
        }
    }
}

private enum CredentialDerivation {
    static let saltLength = 16
    static let outputLength = 32
    static let minimumWorkFactor: UInt32 = 10_000
    static let maximumWorkFactor: UInt32 = 5_000_000
    static let workFactor: UInt32 = 600_000

    static func derive(
        _ credential: String,
        salt: Data,
        workFactor: UInt32,
    ) throws -> Data {
        guard workFactor >= minimumWorkFactor,
              salt.count == saltLength,
              !credential.isEmpty
        else {
            throw VaultCredentialError.invalidCredential
        }

        let password = Data(credential.utf8)
        var output = Data(repeating: 0, count: outputLength)
        let derivedLength = output.count
        let status = password.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.bindMemory(to: CChar.self).baseAddress,
                        password.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(workFactor),
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                        derivedLength,
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw VaultCredentialError.unavailable
        }

        return output
    }

    static func deriveAsync(
        _ credential: String,
        salt: Data,
        workFactor: UInt32,
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try derive(credential, salt: salt, workFactor: workFactor)
        }.value
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

private func secureRandomBytes(count: Int) throws -> Data {
    guard count > 0 else {
        throw VaultCredentialError.unavailable
    }

    var bytes = Data(repeating: 0, count: count)
    let status = bytes.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return errSecParam
        }

        return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
    }
    guard status == errSecSuccess else {
        throw VaultCredentialError.unavailable
    }

    return bytes
}

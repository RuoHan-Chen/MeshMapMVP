import Foundation
import CryptoKit
import Security
import Network
import SolanaSwift
import SwiftUI

// MARK: - App-level offline payment key (separate from mesh encryption keys)

enum PaymentKeyManager {
    private static let keychainService = "meshchat.payment.signing"
    private static let keychainAccount = "private"

    private static func loadPrivateKey() -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { return nil }
        return key
    }

    private static func savePrivateKey(_ key: Curve25519.Signing.PrivateKey) throws {
        let data = key.rawRepresentation
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw NSError(domain: "PaymentKeyManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to save key"])
        }
    }

    private static func loadOrCreateKeypair() throws -> (publicKey: Data, privateKey: Curve25519.Signing.PrivateKey) {
        if let priv = loadPrivateKey() {
            return (priv.publicKey.rawRepresentation, priv)
        }
        let priv = Curve25519.Signing.PrivateKey()
        try savePrivateKey(priv)
        return (priv.publicKey.rawRepresentation, priv)
    }

    static func paymentPublicKeyBase64() -> String {
        // This can be called from UI synchronously; for MVP we fail closed if keychain read fails.
        do {
            let pair = try loadOrCreateKeypair()
            return pair.publicKey.base64EncodedString()
        } catch {
            // TODO: handle keychain errors in UI
            return ""
        }
    }

    static func signPaymentPayload(data: Data) throws -> Data {
        let pair = try loadOrCreateKeypair()
        // CryptoKit returns signature as raw bytes for Ed25519/Curve25519 signing keys.
        return try pair.privateKey.signature(for: data)
    }

    static func verifyPaymentPayload(data: Data, signature: Data, publicKey: Data) -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return pub.isValidSignature(signature, for: data)
    }
}

// MARK: - Solana wallet (devnet only, MVP scaffolding)

private enum SolanaKeychain {
    static let service = "meshchat.solana.wallet"
    static let account = "solana-account"
}

private final class SolanaKeychainStore {
    static func saveData(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SolanaKeychain.service,
            kSecAttrAccount as String: SolanaKeychain.account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw NSError(domain: "SolanaKeychainStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "Keychain save failed"])
        }
    }

    static func loadData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SolanaKeychain.service,
            kSecAttrAccount as String: SolanaKeychain.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return data
    }
}

struct KeychainAccountStorage: SolanaAccountStorage {
    func save(_ account: KeyPair) throws {
        let encoded = try JSONEncoder().encode(account)
        try SolanaKeychainStore.saveData(encoded)
    }

    var account: KeyPair? {
        get {
            do {
                guard let data = try SolanaKeychainStore.loadData() else { return nil }
                return try JSONDecoder().decode(KeyPair.self, from: data)
            } catch {
                return nil
            }
        }
    }
}

final class SolanaWalletService: ObservableObject {
    private let accountStorage = KeychainAccountStorage()
    private let networkName: String = "devnet"
    private let endpoint = APIEndPoint(address: "https://api.devnet.solana.com", network: .devnet)

    @Published private(set) var walletAddress: String?
    @Published private(set) var lastKnownBalanceLamports: Int64?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var lastAirdropAttemptAt: Date?

    @Published var isRefreshing = false
    @Published var lastError: String?

    init() {
        loadCachedWalletState()
        // Address is derived from storage; no network call on init.
        refreshAddressFromStorage()
    }

    private func refreshAddressFromStorage() {
        if let keyPair = accountStorage.account {
            walletAddress = keyPair.publicKey.base58EncodedString
        }
    }

    private func loadCachedWalletState() {
        do {
            if let cache = try DatabaseManager.shared.fetchWalletStateCache(network: networkName) {
                walletAddress = cache.walletAddress
                lastKnownBalanceLamports = cache.lastKnownBalanceLamports
                lastRefreshedAt = Date(timeIntervalSince1970: TimeInterval(cache.lastRefreshedAt))
                if let t = cache.lastAirdropAttemptAt {
                    lastAirdropAttemptAt = Date(timeIntervalSince1970: TimeInterval(t))
                }
            }
        } catch {
            // ignore; UI will show empty state
        }
    }

    func createWalletIfNeeded() async throws {
        if walletAddress != nil {
            return
        }
        if let _ = accountStorage.account {
            refreshAddressFromStorage()
            return
        }
        let keyPair = try await KeyPair(network: .devnet)
        try accountStorage.save(keyPair)
        refreshAddressFromStorage()
    }

    func fetchBalance() async throws -> Int64 {
        try await createWalletIfNeeded()
        guard let addr = walletAddress else { throw NSError(domain: "SolanaWalletService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing wallet address"]) }
        let apiClient = JSONRPCAPIClient(endpoint: endpoint)

        let balance: UInt64 = try await apiClient.getBalance(account: addr, commitment: "recent")
        let lamports = Int64(balance)

        let now = Int64(Date().timeIntervalSince1970)
        lastKnownBalanceLamports = lamports
        lastRefreshedAt = Date()

        let cache = WalletStateCache(
            network: networkName,
            walletAddress: addr,
            lastKnownBalanceLamports: lamports,
            lastRefreshedAt: now,
            lastAirdropAttemptAt: nil
        )
        try DatabaseManager.shared.upsertWalletStateCache(cache)
        return lamports
    }

    /// Direct online devnet transfer.
    /// IMPORTANT: This does NOT affect offline mesh payment pending records.
    // TODO: SPL token support, program/escrow settlement, staking/yield, and broader network handling.
    func sendSOL(to address: String, amountLamports: Int64) async throws -> String {
        try await createWalletIfNeeded()
        guard let fromKeyPair = accountStorage.account else { throw NSError(domain: "SolanaWalletService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing local Solana keypair"]) }

        let apiClient = JSONRPCAPIClient(endpoint: endpoint)
        let blockchainClient = BlockchainClient(apiClient: apiClient)

        let prepared = try await blockchainClient.prepareSendingNativeSOL(
            from: fromKeyPair,
            to: address,
            amount: UInt64(amountLamports)
        )
        return try await blockchainClient.sendTransaction(preparedTransaction: prepared)
    }
}

// MARK: - Connectivity monitor (used only for disabling “Refresh” / “Send” buttons)

final class InternetAvailability: ObservableObject {
    @Published private(set) var isAvailable: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "meshchat.internet")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isAvailable = (path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}


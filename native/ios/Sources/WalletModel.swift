import Foundation
import Combine

struct PoolBalances: Decodable {
    let height: Int32?
    let transparent: String
    let sapling: String
    let orchard: String
    let ironwood: String
    let total: String
}

struct WalletAddresses: Decodable {
    let ua: String?
    let transparent: String?
    let sapling: String?
    let orchard: String?
}

struct WalletTransaction: Decodable, Identifiable {
    let id: Int32
    let txid: String
    let height: Int32
    let time: String
    let value: String
    var incoming: Bool { (Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) ?? 0) >= 0 }
    var title: String { incoming ? "Received ZEC" : "Sent ZEC" }
}

struct WalletOverview: Decodable {
    let balance: PoolBalances
    let address: WalletAddresses
    let transactions: [WalletTransaction]
}

struct RecoveryBackup {
    let accountID: Int32
    let phrase: String
}

enum WalletSyncState: Equatable {
    case noAccount, checking, syncing, cancelling, synced, behind, offline, failed
    var label: String {
        switch self {
        case .noAccount: return "No account"
        case .checking: return "Checking"
        case .syncing: return "Syncing"
        case .cancelling: return "Stopping"
        case .synced: return "Synced"
        case .behind: return "Out of sync"
        case .offline: return "Offline"
        case .failed: return "Sync failed"
        }
    }
}

@MainActor
final class WalletModel: ObservableObject {
    @Published private(set) var wallet: Wallet?
    @Published private(set) var accounts: [AccountSummary] = []
    @Published private(set) var selectedAccountID: Int32?
    @Published private(set) var overview: WalletOverview?
    @Published private(set) var busy = false
    @Published private(set) var syncingAccountID: Int32?
    @Published private(set) var cancelRequested = false
    @Published private(set) var paramsAvailable = false
    @Published private(set) var chainTip: UInt32?
    @Published private(set) var heights: [Int32: UInt32] = [:]
    @Published private(set) var syncStartHeight: UInt32?
    @Published private(set) var scanHeight: UInt32?
    @Published private(set) var connectionFailed = false
    @Published private(set) var syncFailures: [Int32: String] = [:]
    @Published private(set) var tipCheckedAt: Date?
    @Published var recovery: RecoveryBackup?
    @Published var message: String?
    private var overviews: [Int32: WalletOverview] = [:]
    private var polling = false
    private var tipAttemptAt: Date?
    private var selectionPreference = "selectedAccount-0"

    init(wallet: Wallet? = nil) {
        self.wallet = wallet
        self.paramsAvailable = wallet?.saplingParamsAvailable() ?? false
    }

    var selectedAccount: AccountSummary? { accounts.first { $0.id == selectedAccountID } }
    var syncing: Bool { syncingAccountID != nil }
    var currentHeight: UInt32? {
        guard let id = selectedAccountID else { return nil }
        if id == syncingAccountID, let scanHeight { return scanHeight }
        return heights[id]
    }
    var syncState: WalletSyncState {
        guard let id = selectedAccountID else { return .noAccount }
        if syncingAccountID == id { return cancelRequested ? .cancelling : .syncing }
        if syncFailures[id] != nil { return .failed }
        if connectionFailed { return .offline }
        guard let tip = chainTip, let height = heights[id], let checked = tipCheckedAt,
              Date().timeIntervalSince(checked) < 45 else { return .checking }
        return height == tip ? .synced : .behind
    }
    var heightCaption: String {
        guard let tip = chainTip, let height = currentHeight else { return "Waiting for chain tip" }
        return height <= tip ? "tip-\(tip - height)" : "ahead \(height - tip)"
    }

    func open(password: String, network: UInt8, endpoint: String) async {
        await perform {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Zkool", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var protectedRoot = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedRoot.setResourceValues(values)
            let opened = try await Wallet.open(config: WalletConfig(
                dataDirectory: root.path, databaseName: "wallet-\(network).db",
                network: network, serverUrl: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                serverType: 0, databasePassword: password, allowUnencryptedDatabase: false
            ))
            self.wallet = opened
            self.selectionPreference = "selectedAccount-\(network)"
            self.paramsAvailable = opened.saplingParamsAvailable()
            try await self.loadAccounts(opened)
            try await self.loadOverview(opened)
        }
    }

    func selectAccount(_ id: Int32) async {
        guard accounts.contains(where: { $0.id == id }) else { return }
        selectedAccountID = id
        UserDefaults.standard.set(Int(id), forKey: selectionPreference)
        overview = overviews[id]
        // Switching remains available during scanning. Fetch details when scanning ends.
        if let wallet, !busy { await perform { try await self.loadOverview(wallet) } }
    }

    func refresh() async {
        guard let wallet else { return }
        await perform {
            try await self.loadAccounts(wallet)
            try await self.loadOverview(wallet)
        }
        await pollSyncStatus(forceTip: true)
    }

    func addAccount(name: String, key: String?, birth: UInt32?) async -> Bool {
        guard let wallet, !busy else { return false }
        var created = false
        await perform {
            let account = try await wallet.createAccount(name: name, key: key, birth: birth)
            // Keep the new phrase available even if refreshing the dashboard fails.
            if let phrase = account.mnemonic { self.recovery = RecoveryBackup(accountID: account.accountId, phrase: phrase) }
            self.selectedAccountID = account.accountId
            UserDefaults.standard.set(Int(account.accountId), forKey: self.selectionPreference)
            created = true
            try await self.loadAccounts(wallet)
            try await self.loadOverview(wallet)
        }
        return created
    }

    func showRecovery() async -> Bool {
        guard let wallet, let id = selectedAccountID, !busy else { return false }
        await perform {
            guard let phrase = try await wallet.recoveryPhrase(accountId: id) else {
                throw APIError(message: "This is a viewing-key account. It has no recovery phrase.")
            }
            self.recovery = RecoveryBackup(accountID: id, phrase: phrase)
        }
        return recovery != nil
    }

    func synchronizeSelected() async {
        guard let wallet, let id = selectedAccountID, !busy else { return }
        busy = true
        syncingAccountID = id
        cancelRequested = false
        scanHeight = heights[id]
        syncStartHeight = heights[id]
        syncFailures[id] = nil
        message = nil
        do {
            _ = try await wallet.synchronizeAccount(accountId: id)
            if cancelRequested { message = "Sync stopped. You can resume at any time." }
        } catch {
            if cancelRequested { message = "Sync stopped. You can resume at any time." }
            else {
                syncFailures[id] = error.localizedDescription
                message = error.localizedDescription
            }
        }
        // Use committed heights after completion; the requested tip is not proof of success.
        syncingAccountID = nil
        scanHeight = nil
        syncStartHeight = nil
        cancelRequested = false
        do {
            try await loadAccounts(wallet)
            try await loadOverview(wallet)
        } catch { message = error.localizedDescription }
        busy = false
        await pollSyncStatus(forceTip: true)
    }

    func cancelSync() async {
        guard let wallet, syncing else { return }
        cancelRequested = true
        do { try await wallet.cancelSync() }
        catch { message = error.localizedDescription; cancelRequested = false }
    }

    func pollSyncStatus(forceTip: Bool = false) async {
        guard let wallet, !polling else { return }
        polling = true
        defer { polling = false }
        if let id = syncingAccountID { scanHeight = wallet.syncProgressHeight(accountId: id) ?? scanHeight }
        let ids = Set([selectedAccountID, syncingAccountID].compactMap { $0 })
        for id in ids {
            do { heights[id] = try await wallet.accountSyncHeight(accountId: id) }
            catch { /* Retain the last known height while a chunk commits. */ }
        }
        if forceTip || tipAttemptAt == nil || Date().timeIntervalSince(tipAttemptAt!) >= 15 {
            tipAttemptAt = Date()
            do {
                let tip = try await wallet.chainTip()
                guard !Task.isCancelled else { return }
                chainTip = tip
                tipCheckedAt = Date()
                connectionFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                connectionFailed = true
            }
        }
    }

    func downloadParams() async {
        guard let wallet else { return }
        await perform {
            try await wallet.downloadSaplingParams()
            self.paramsAvailable = wallet.saplingParamsAvailable()
        }
    }

    private func loadAccounts(_ wallet: Wallet) async throws {
        accounts = try await wallet.accounts()
        for account in accounts { heights[account.id] = UInt32(max(0, account.height)) }
        if !accounts.contains(where: { $0.id == selectedAccountID }) {
            let saved = Int32(exactly: UserDefaults.standard.integer(forKey: selectionPreference))
            selectedAccountID = accounts.first { $0.id == saved }?.id ?? accounts.first?.id
        }
    }

    private func loadOverview(_ wallet: Wallet) async throws {
        guard let id = selectedAccountID else { overview = nil; return }
        let request: [String: Any] = [
            "query": """
            query Dashboard($id: Int!) {
              balance: balanceByAccount(idAccount: $id) { height transparent sapling orchard ironwood total }
              address: addressByAccount(idAccount: $id) { ua transparent sapling orchard }
              transactions: transactionsByAccount(idAccount: $id) { id txid height time value }
            }
            """,
            "variables": ["id": id]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: request)
        let result = try await wallet.execute(requestJson: String(decoding: bytes, as: UTF8.self))
        let response = try JSONDecoder().decode(DashboardResponse.self, from: Data(result.utf8))
        if let errors = response.errors, !errors.isEmpty {
            throw APIError(message: errors.map(\.message).joined(separator: "\n"))
        }
        guard let dashboard = response.data else { throw APIError(message: "Wallet data is unavailable") }
        overviews[id] = dashboard
        if selectedAccountID == id { overview = dashboard }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do { try await operation() }
        catch { message = error.localizedDescription }
    }
}

private struct DashboardResponse: Decodable {
    let data: WalletOverview?
    let errors: [GraphQLError]?
}
private struct GraphQLError: Decodable { let message: String }
private struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

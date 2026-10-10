import Foundation

// Compile with the generated ZkoolNative.swift and the host Rust dynamic library.
@main
struct SwiftSmoke {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wallet = try await Wallet.open(config: WalletConfig(
            dataDirectory: directory.path, databaseName: "wallet.db", network: 2,
            serverUrl: "http://127.0.0.1:1", serverType: 0,
            databasePassword: "swift-smoke-only", allowUnencryptedDatabase: false
        ))
        let accounts = try await wallet.accounts()
        precondition(accounts.isEmpty)
        let result = try await wallet.execute(requestJson: #"{"query":"{ apiVersion }"}"#)
        let response = try JSONSerialization.jsonObject(with: Data(result.utf8)) as! [String: Any]
        let data = response["data"] as! [String: Any]
        precondition(data["apiVersion"] as? String == "1.0")
        do {
            _ = try await wallet.execute(requestJson: "invalid JSON")
            fatalError("Expected a typed FFI error")
        } catch is WalletError {
            // Rust errors cross the FFI as generated Swift errors.
        }
        print("Swift → UniFFI → Rust encrypted wallet smoke test passed")
    }
}

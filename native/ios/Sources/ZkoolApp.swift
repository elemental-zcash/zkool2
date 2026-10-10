import SwiftUI

@main
struct ZkoolApp: App {
    @StateObject private var model = WalletModel()

    init() { WalletFont.register() }

    var body: some Scene {
        WindowGroup { WalletView().environmentObject(model) }
    }
}

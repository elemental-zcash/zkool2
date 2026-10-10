import SwiftUI

private enum WalletTab: String, CaseIterable {
    case home = "Home", activity = "Activity", accounts = "Accounts", settings = "Settings"
    var symbol: String {
        switch self {
        case .home: return "house"
        case .activity: return "arrow.left.arrow.right"
        case .accounts: return "person.2"
        case .settings: return "slider.horizontal.3"
        }
    }
}
private enum WalletSheet: String, Identifiable {
    case account, receive, recovery, send
    var id: String { rawValue }
}

struct WalletView: View {
    @EnvironmentObject private var model: WalletModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = WalletTab.home
    @State private var sheet: WalletSheet?
    @State private var importMode = false
    @State private var password = ""
    @State private var network: UInt8 = 0
    @State private var endpoint = "https://zec.rocks"

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.07, green: 0.12, blue: 0.11), WalletTheme.background],
                               startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.wallet == nil { welcome }
                        else {
                            accountHeader
                            if let activeID = model.syncingAccountID, activeID != model.selectedAccountID {
                                HStack(spacing: 12) {
                                    ProgressView().tint(WalletTheme.green)
                                    Text("Syncing \(model.accounts.first { $0.id == activeID }?.name ?? "another account")")
                                        .font(.footnote)
                                    Spacer()
                                    Button("Stop") { Task { await model.cancelSync() } }.disabled(model.cancelRequested)
                                }.walletCard()
                            }
                            if let message = model.message { messageBanner(message) }
                            switch tab {
                            case .home: home
                            case .activity: activity
                            case .accounts: accountManager
                            case .settings: settings
                            }
                        }
                    }.padding(20).frame(maxWidth: 580).frame(maxWidth: .infinity)
                }.refreshable { await model.synchronizeSelected() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.wallet != nil { tabBar }
            }
            .walletNavigationChrome()
            .sheet(item: $sheet) { destination in
                switch destination {
                case .account: AccountEditor(importing: importMode)
                case .receive: ReceiveView()
                case .send: SendingView()
                case .recovery: RecoveryPhraseView(requireBackup: false)
                }
            }
        }
        .tint(WalletTheme.green).preferredColorScheme(.dark)
        .task(id: "\(model.wallet != nil)-\(scenePhase)") {
            guard model.wallet != nil, scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.pollSyncStatus()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Ƶ").font(.system(size: 56, weight: .bold)).foregroundStyle(WalletTheme.green)
            VStack(alignment: .leading, spacing: 10) {
                Text("Your money.\nYour privacy.").font(.system(size: 38, weight: .bold, design: .rounded))
                Text("A calmer home for your Zcash.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("Open your wallet").font(.title3.bold())
                Picker("Network", selection: $network) {
                    Text("Mainnet").tag(UInt8(0))
                    Text("Testnet").tag(UInt8(1))
                    Text("Regtest").tag(UInt8(2))
                    Text("ZSA regtest").tag(UInt8(3))
                }
                TextField("Lightwalletd URL", text: $endpoint).walletInput(url: true)
                    .accessibilityLabel("Lightwalletd URL")
                SecureField("Database password", text: $password).walletInput()
                Button {
                    Task {
                        await model.open(password: password, network: network, endpoint: endpoint)
                        if model.wallet != nil { password = "" }
                    }
                } label: {
                    HStack { if model.busy { ProgressView().tint(WalletTheme.background) }; Text("Open encrypted wallet"); Image(systemName: "arrow.right") }
                }.buttonStyle(WalletActionStyle(primary: true))
                    .disabled(model.busy || password.isEmpty || endpoint.isEmpty)
                Text("New here? Open with a new password, then create a wallet or import an account. Use the same password on future launches.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.walletCard()
            if let message = model.message { messageBanner(message) }
        }.padding(.top, 30)
    }

    private var accountHeader: some View {
        HStack {
            Menu {
                ForEach(model.accounts, id: \.id) { account in
                    Button {
                        tab = .home
                        Task { await model.selectAccount(account.id) }
                    } label: {
                        if model.selectedAccountID == account.id { Label(account.name, systemImage: "checkmark") }
                        else { Text(account.name) }
                    }
                }
                Divider()
                Button { tab = .accounts } label: { Label("Account Manager", systemImage: "person.2") }
                Button { openAccountEditor(importing: false) } label: { Label("Create wallet", systemImage: "plus") }
                Button { openAccountEditor(importing: true) } label: { Label("Import account", systemImage: "square.and.arrow.down") }
            } label: {
                HStack(spacing: 10) {
                    Text(model.selectedAccount?.name ?? "Your wallets").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }.font(.system(size: 17, weight: .semibold))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain)
                .foregroundStyle(Color.white).padding(.horizontal, 18).padding(.vertical, 13)
                .background(WalletTheme.surface)
                .accessibilityLabel("Switch account. \(model.selectedAccount?.name ?? "No account selected")")
            Spacer(minLength: 12)
            Text("ZKOOL").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(3)
                .foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private var syncStrip: some View { WalletSyncIndicator() }

    private var home: some View {
        VStack(spacing: 20) {
            if model.selectedAccount == nil { emptyWallet }
            else {
                syncStrip
                if let overview = model.overview {
                    balanceCard(overview.balance)
                    transactionsCard(Array(overview.transactions.prefix(5)), compact: true)
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading your balances…").foregroundStyle(.secondary)
                        Button("Try again") { Task { await model.refresh() } }.disabled(model.busy)
                    }.frame(maxWidth: .infinity).walletCard()
                }
            }
        }
    }

    private func balanceCard(_ balances: PoolBalances) -> some View {
        VStack(spacing: -16) {
            poolBand("TRANSPARENT", amount: balances.transparent, color: WalletTheme.coral)
            poolBand("SAPLING", amount: balances.sapling, color: WalletTheme.yellow)
            poolBand("ORCHARD", amount: balances.orchard, color: WalletTheme.orange)
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Text("IRONWOOD")
                    Spacer()
                    Text(WalletMoney.format(balances.ironwood, digits: 3)).monospacedDigit()
                }.font(WalletFont.numbers(12, bold: true)).foregroundStyle(WalletTheme.green)
                totalBalance(balances.total)
                HStack {
                    Text("$ ––")
                    Spacer()
                    Text("USD")
                }.font(WalletFont.numbers(19, bold: true)).foregroundStyle(.white)
                HStack(spacing: 12) {
                    Button { sheet = .receive } label: { Label("Receive", systemImage: "arrow.down.left") }
                        .buttonStyle(WalletActionStyle(primary: true))
                    Button { sheet = .send } label: { Label("Send", systemImage: "arrow.up.right") }
                        .buttonStyle(WalletActionStyle()).disabled(model.busy)
                }
            }.padding(22).background(WalletTheme.surface).clipShape(RoundedRectangle(cornerRadius: 24))
        }
    }

    private func poolBand(_ title: String, amount: String, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(WalletMoney.format(amount, digits: 3)).monospacedDigit()
        }.font(WalletFont.numbers(12, bold: true))
            .foregroundStyle(WalletTheme.background).padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 32)
            .background(color).clipShape(PoolRibbon())
            .accessibilityElement(children: .combine)
    }

    private func totalBalance(_ value: String) -> some View {
        let parts = WalletMoney.format(value).components(separatedBy: ".")
        let whole = parts.first ?? "—"
        let fraction = parts.count > 1 ? parts[1] : ""
        return VStack(alignment: .leading, spacing: 8) {
            Text("TOTAL BALANCE").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(whole + "." + String(fraction.prefix(3))).font(WalletFont.numbers(43, bold: true))
                Text(String(fraction.dropFirst(3))).font(WalletFont.numbers(18, bold: true))
                Text("ZEC").font(.system(size: 14, weight: .bold)).padding(.leading, 5)
            }.monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Total balance \(WalletMoney.format(value)) ZEC")
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your activity").font(.largeTitle.bold())
            syncStrip
            transactionsCard(model.overview?.transactions ?? [], compact: false)
        }
    }

    private func transactionsCard(_ transactions: [WalletTransaction], compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(compact ? "Latest transactions" : "Transactions").font(WalletFont.numbers(18, bold: true))
                Spacer()
                if compact { Button("See all") { tab = .activity }.font(.caption.weight(.semibold)).buttonStyle(.plain).foregroundStyle(WalletTheme.green) }
            }
            if transactions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right").font(.title2).foregroundStyle(WalletTheme.green)
                    Text("A fresh start").font(.headline)
                    Text("Your transactions will appear here after syncing.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(transactions) { transaction in
                    HStack(spacing: 12) {
                        Text("Ƶ").font(.system(size: 21, weight: .bold)).foregroundStyle(WalletTheme.background)
                            .frame(width: 38, height: 38).background(WalletTheme.gold).clipShape(Circle()).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(transaction.title).font(.system(size: 15, weight: .medium))
                            Text(String(transaction.txid.prefix(12)) + "…")
                                .font(WalletFont.numbers(10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text((transaction.incoming ? "+" : "") + WalletMoney.format(transaction.value, digits: 3))
                                .font(WalletFont.numbers(16)).lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(transaction.incoming ? WalletTheme.green : Color.white)
                            Text("ZEC").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.accessibilityElement(children: .combine)
                }
            }
        }.frame(maxWidth: .infinity).walletCard()
    }

    private var emptyWallet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "sparkles").font(.system(size: 36)).foregroundStyle(WalletTheme.green)
            Text("Make yourself\nat home.").font(.system(size: 32, weight: .bold, design: .rounded))
            Text("Create a fresh wallet, or bring an existing account with its recovery phrase or viewing key.")
                .foregroundStyle(.secondary)
            Button { openAccountEditor(importing: false) } label: { Label("Create wallet", systemImage: "plus") }
                .buttonStyle(WalletActionStyle(primary: true)).disabled(model.busy)
            Button { openAccountEditor(importing: true) } label: { Label("Import account", systemImage: "square.and.arrow.down") }
                .buttonStyle(WalletActionStyle()).disabled(model.busy)
        }.frame(maxWidth: .infinity, alignment: .leading).walletCard()
    }

    private var accountManager: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Account Manager").font(.largeTitle.bold())
            Text("All your accounts, one place.").foregroundStyle(.secondary)
            if model.accounts.isEmpty { emptyWallet }
            else {
                VStack(spacing: 20) {
                    ForEach(model.accounts, id: \.id) { account in
                        Button {
                            tab = .home
                            Task { await model.selectAccount(account.id) }
                        } label: {
                            HStack(spacing: 14) {
                                Text(String(account.name.prefix(1)).uppercased()).font(.headline)
                                    .frame(width: 44, height: 44).background(WalletTheme.green.opacity(0.12))
                                    .foregroundStyle(WalletTheme.green).clipShape(RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(account.name).font(.headline)
                                    Text("\(WalletMoney.format(account.balance, digits: 3)) ZEC").font(WalletFont.numbers(12)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if account.id == model.selectedAccountID { Image(systemName: "checkmark.circle.fill").foregroundStyle(WalletTheme.green) }
                            }
                        }.buttonStyle(.plain)
                    }
                }.walletCard()
                Button { openAccountEditor(importing: false) } label: { Label("Create wallet", systemImage: "plus") }
                    .buttonStyle(WalletActionStyle(primary: true)).disabled(model.busy)
                Button { openAccountEditor(importing: true) } label: { Label("Import account", systemImage: "square.and.arrow.down") }
                    .buttonStyle(WalletActionStyle()).disabled(model.busy)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Wallet settings").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 16) {
                Label("Recovery phrase", systemImage: "key.horizontal").font(.headline)
                Text("Keep a private backup for the selected account. Viewing-key accounts do not have a seed phrase.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("View recovery phrase") {
                    Task { if await model.showRecovery() { sheet = .recovery } }
                }.buttonStyle(WalletActionStyle()).disabled(model.busy || model.selectedAccount == nil)
            }.walletCard()
            VStack(alignment: .leading, spacing: 16) {
                Label("Sapling parameters", systemImage: "shield").font(.headline)
                Text(model.paramsAvailable ? "Ready on this device." : "Required for Sapling spending. About 50 MB.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !model.paramsAvailable {
                    Button("Download parameters") { Task { await model.downloadParams() } }
                        .buttonStyle(WalletActionStyle()).disabled(model.busy)
                }
            }.walletCard()
            Text("Encrypted on this device. Wallet data is excluded from device backups.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(WalletTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 6) {
                        Image(systemName: item.symbol).font(.system(size: 20, weight: .regular))
                        Text(item.rawValue).font(.system(size: 10, weight: .medium))
                    }.frame(maxWidth: .infinity).padding(.vertical, 15)
                        .foregroundStyle(tab == item ? WalletTheme.green : Color.white.opacity(0.5))
                }.buttonStyle(.plain).accessibilityAddTraits(tab == item ? [.isSelected] : [])
            }
        }.padding(.horizontal, 14).background(WalletTheme.background)
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(WalletTheme.yellow)
            Text(message).font(.footnote).textSelection(.enabled)
            Spacer(minLength: 0)
            Button { model.message = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }.padding(16).background(WalletTheme.surface).clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func openAccountEditor(importing: Bool) {
        importMode = importing
        sheet = .account
    }
}

private struct AccountEditor: View {
    @EnvironmentObject private var model: WalletModel
    @Environment(\.dismiss) private var dismiss
    @State var importing: Bool
    @State private var name = ""
    @State private var key = ""
    @State private var birth = ""

    var body: some View {
        NavigationStack {
            if model.recovery != nil {
                RecoveryPhraseView(requireBackup: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(importing ? "Welcome back." : "A fresh beginning.")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(importing ? "Restore an account with its recovery phrase or viewing key." : "We’ll create a new 24-word recovery phrase. Save it before using your wallet.")
                            .foregroundStyle(.secondary)
                        Picker("Account type", selection: $importing) {
                            Text("Create wallet").tag(false)
                            Text("Import account").tag(true)
                        }.pickerStyle(.segmented).disabled(model.busy)
                        TextField("Account name", text: $name).walletInput()
                        if importing {
                            SecureField("Recovery phrase or viewing key", text: $key).walletInput()
                            TextField("Birthday block height", text: $birth).walletInput(number: true)
                            Text("Use the account’s original birthday height to discover its full history.").font(.footnote).foregroundStyle(.secondary)
                        }
                        if let message = model.message { Text(message).font(.footnote).foregroundStyle(WalletTheme.yellow) }
                        Button {
                            Task {
                                let added = await model.addAccount(
                                    name: name, key: importing ? key : nil,
                                    birth: importing ? UInt32(birth) : nil
                                )
                                if added {
                                    key = ""
                                    if model.recovery == nil { dismiss() }
                                }
                            }
                        } label: {
                            HStack { if model.busy { ProgressView().tint(WalletTheme.background) }; Text(importing ? "Import account" : "Create wallet") }
                        }.buttonStyle(WalletActionStyle(primary: true))
                            .disabled(model.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (importing && (key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || UInt32(birth) == nil)))
                    }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }.background(WalletTheme.background)
                    .navigationTitle(importing ? "Import account" : "Create wallet")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { key = ""; dismiss() }.disabled(model.busy) } }
            }
        }.tint(WalletTheme.green).preferredColorScheme(.dark)
            .interactiveDismissDisabled(model.busy || model.recovery != nil)
            .onDisappear { key = "" }
    }
}

private struct RecoveryPhraseView: View {
    @EnvironmentObject private var model: WalletModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let requireBackup: Bool
    @State private var saved = false
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "key.horizontal").font(.largeTitle).foregroundStyle(WalletTheme.green)
                Text("Your recovery phrase").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Write these words down in order and keep them somewhere private. They provide full access to your funds.")
                    .foregroundStyle(.secondary)
                if scenePhase == .active, let backup = model.recovery {
                    let words = backup.phrase.split(separator: " ")
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(words.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(String(index + 1)).font(.caption2).foregroundStyle(.secondary)
                                Text(String(words[index])).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .lineLimit(1).minimumScaleFactor(0.6)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(WalletTheme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }.privacySensitive()
                } else {
                    Label("Recovery phrase hidden while the app is inactive", systemImage: "lock.fill")
                        .frame(maxWidth: .infinity).padding(24).walletCard()
                }
                if requireBackup {
                    Toggle("I saved my recovery phrase", isOn: $saved).tint(WalletTheme.green)
                }
                Button(requireBackup ? "Continue to wallet" : "Done") {
                    model.recovery = nil
                    dismiss()
                }.buttonStyle(WalletActionStyle(primary: true)).disabled(requireBackup && !saved)
            }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }.background(WalletTheme.background).preferredColorScheme(.dark)
            .interactiveDismissDisabled(requireBackup)
            .onDisappear { model.recovery = nil }
    }
}

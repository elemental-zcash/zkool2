import SwiftUI

// Every edit happens before planning. Confirmation signs the stored Rust proposal.
struct SendingView: View {
    @EnvironmentObject private var model: WalletModel
    @Environment(\.dismiss) private var dismiss
    @State private var amount = "0"
    @State private var address = ""
    @State private var memo = ""
    @State private var subject = ""
    @State private var advanced = false
    @State private var pools: UInt8 = 15
    @State private var deductFee = false
    @State private var includeAddress = false
    @State private var confirmations: UInt32 = 0
    @State private var fraction = 0.0
    @State private var spendable: [String] = []
    @State private var working = false
    @State private var error: String?
    @State private var proposal: PreparedPayment?
    @State private var receipt: PaymentReceipt?
    @State private var scanning = false
    init(initialAdvanced: Bool = false) { _advanced = State(initialValue: initialAdvanced) }
    private let poolNames = ["Transparent", "Sapling", "Orchard", "Ironwood"]
    private let poolColors = [WalletTheme.coral, WalletTheme.yellow, WalletTheme.orange, WalletTheme.green]
    private var available: Decimal {
        spendable.enumerated().reduce(Decimal.zero) { sum, item in
            pools & (1 << item.offset) == 0 ? sum : sum + (Decimal(string: item.element) ?? 0)
        }
    }
    private var finalMemo: String { PaymentDraft.memo(subject: subject, text: memo,
        returnAddress: includeAddress ? model.overview?.address.ua : nil) }
    private var portion: Binding<Double> {
        Binding(get: { fraction }, set: { value in
            fraction = value
            let selected = available * (Decimal(string: String(value)) ?? 0)
            amount = WalletMoney.format(NSDecimalNumber(decimal: selected).stringValue)
                .replacingOccurrences(of: ",", with: "")
        })
    }
    private var valid: Bool { PaymentDraft.validAmount(amount) && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && pools != 0 && finalMemo.utf8.count <= 512 && (!includeAddress || model.overview?.address.ua != nil) }

    var body: some View {
        NavigationStack {
            ZStack {
                WalletTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(receipt == nil ? "Send ZEC" : "Payment sent").font(.title2.bold())
                                Text(model.selectedAccount?.name ?? "Wallet").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { dismiss() } label: { Image(systemName: "xmark").padding(12) }
                                .buttonStyle(.plain).disabled(working).accessibilityLabel("Close sending")
                        }
                        WalletSyncIndicator().disabled(working)
                        if let receipt { success(receipt) }
                        else if let proposal { review(proposal) }
                        else { editor }
                        if let error {
                            Text(error).font(.footnote).foregroundStyle(WalletTheme.coral)
                                .textSelection(.enabled).accessibilityLabel("Payment error: \(error)")
                        }
                    }.padding(24).frame(maxWidth: 580).frame(maxWidth: .infinity)
                }
            }.walletNavigationChrome()
        }.preferredColorScheme(.dark).tint(WalletTheme.green)
            .interactiveDismissDisabled(working)
            .task(id: "\(model.selectedAccountID ?? 0)-\(confirmations)-\(model.busy)") { await loadSpendable() }
            .sheet(isPresented: $scanning) {
                #if os(iOS)
                WalletQRScanner { value in
                    address = value
                    scanning = false
                }
                #else
                Text("QR scanning requires an iOS camera.").padding()
                #endif
            }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(WalletMoney.format(amount)).font(WalletFont.numbers(30, bold: true))
                    Text("ZEC").font(WalletFont.numbers(18, bold: true))
                }.lineLimit(1).minimumScaleFactor(0.45).accessibilityLabel("Amount \(amount) ZEC")
                Text("$ ––").font(WalletFont.numbers(19, bold: true))
            }
            HStack(spacing: 8) {
                TextField("Enter address", text: $address).textFieldStyle(.plain)
                    .font(WalletFont.numbers(15)).paymentInputBehavior()
                    .accessibilityLabel("Recipient address")
                #if os(iOS)
                Button { scanning = true } label: { Image(systemName: "qrcode.viewfinder").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(WalletTheme.gold).accessibilityLabel("Scan recipient QR code")
                #endif
            }.padding(14).overlay(Rectangle().stroke(Color.white.opacity(0.8), lineWidth: 1))
            if advanced { advancedSettings } else { keypad }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Memo").font(.caption)
                    Spacer()
                    Text("\(finalMemo.utf8.count)/512 bytes").font(WalletFont.numbers(10))
                        .foregroundStyle(finalMemo.utf8.count > 512 ? WalletTheme.coral : .secondary)
                }
                TextField("Optional private memo", text: $memo, axis: .vertical)
                    .lineLimit(2...5).font(WalletFont.numbers(14)).textFieldStyle(.plain)
                    .padding(14).overlay(Rectangle().stroke(Color.white.opacity(0.8), lineWidth: 1))
            }
            Button { Task { await prepare() } } label: {
                HStack { if working { ProgressView().tint(WalletTheme.background) }; Text(working ? "Preparing payment…" : "Review payment"); Image(systemName: "arrow.up.right") }
            }.buttonStyle(WalletActionStyle(primary: true)).disabled(!valid || working || model.busy)
            Button { advanced.toggle() } label: {
                Text(advanced ? "Basic settings" : "Advanced settings")
            }.buttonStyle(WalletActionStyle()).disabled(working)
        }.disabled(working)
    }

    private var keypad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
            ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "⌫"], id: \.self) { key in
                Button { amount = PaymentDraft.appending(key, to: amount) } label: {
                    Text(key).font(WalletFont.numbers(28)).frame(maxWidth: .infinity).frame(height: 56)
                }.buttonStyle(.plain).contentShape(Rectangle())
                    .accessibilityLabel(key == "⌫" ? "Delete last digit" : key)
            }
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Source pools").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(0..<4) { index in
                    let selected = pools & (1 << index) != 0
                    Button { pools ^= 1 << index; fraction = 0 } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack { Text(poolNames[index]); Spacer(); if selected { Image(systemName: "checkmark") } }
                                .font(.system(size: 11, weight: .semibold))
                            Text(spendable.count == 4 ? WalletMoney.format(spendable[index], digits: 3) : "––")
                                .font(WalletFont.numbers(17, bold: true))
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .foregroundStyle(poolColors[index])
                            .background(selected ? poolColors[index].opacity(0.08) : Color.clear)
                            .overlay(Rectangle().stroke(poolColors[index].opacity(selected ? 1 : 0.3), lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel("\(poolNames[index]), \(selected ? "selected" : "excluded")")
                }
            }
            Text("Spendable before fee · \(spendable.isEmpty ? "––" : WalletMoney.format(NSDecimalNumber(decimal: available).stringValue)) ZEC")
                .font(WalletFont.numbers(12)).foregroundStyle(.secondary)
            TextField("Amount in ZEC", text: $amount).textFieldStyle(.plain).font(WalletFont.numbers(20))
                .paymentInputBehavior(decimal: true).padding(14)
                .overlay(Rectangle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                .accessibilityLabel("Payment amount in ZEC")
            Slider(value: portion, in: 0...1) { Text("Portion of spendable balance") }
                .disabled(spendable.isEmpty || available == 0)
            Text("The final fee is calculated in review. Sending the full balance requires deducting the fee.")
                .font(.caption).foregroundStyle(.secondary)
            check("Deduct fee from amount", selected: $deductFee)
            check("Include my address in memo", selected: $includeAddress)
            TextField("Subject", text: $subject).font(WalletFont.numbers(14)).textFieldStyle(.plain)
                .padding(14).overlay(Rectangle().stroke(Color.white.opacity(0.8), lineWidth: 1))
            Stepper(value: $confirmations, in: 0...100) {
                Text("Minimum confirmations: \(confirmations)").font(.caption)
            }
        }
    }

    private func check(_ label: String, selected: Binding<Bool>) -> some View {
        Button { selected.wrappedValue.toggle() } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark").opacity(selected.wrappedValue ? 1 : 0)
                    .foregroundStyle(selected.wrappedValue ? WalletTheme.green : .white)
                    .frame(width: 24, height: 24).overlay(Rectangle().stroke(.white, lineWidth: 1))
                Text(label).font(.system(size: 14))
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).accessibilityValue(selected.wrappedValue ? "On" : "Off")
    }

    private func review(_ proposal: PreparedPayment) -> some View {
        let review = proposal.review()
        return VStack(alignment: .leading, spacing: 20) {
            Text("Review payment").font(.title2.bold())
            Text("To").font(.caption).foregroundStyle(.secondary)
            Text(address).font(WalletFont.numbers(12)).textSelection(.enabled)
            HStack { Text("Requested amount"); Spacer(); Text("\(WalletMoney.format(amount)) ZEC").font(WalletFont.numbers(13)) }
            HStack { Text("Network fee"); Spacer(); Text("\(WalletMoney.format(review.fee)) ZEC").font(WalletFont.numbers(13)) }
            Text(deductFee ? "The fee is deducted from the requested amount." : "The fee is added to your wallet debit.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Transaction outputs, including change").font(.headline)
            ForEach(Array(review.outputs.enumerated()), id: \.offset) { _, output in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(output.pool < 4 ? poolNames[Int(output.pool)] : "Pool") · \(WalletMoney.format(output.amount)) ZEC")
                        .font(WalletFont.numbers(12, bold: true))
                    Text(output.address).font(WalletFont.numbers(10)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if !finalMemo.isEmpty {
                Text("Memo").font(.caption).foregroundStyle(.secondary)
                Text(finalMemo).font(WalletFont.numbers(12)).textSelection(.enabled)
            }
            Button { Task { await submit(proposal) } } label: {
                HStack { if working { ProgressView().tint(WalletTheme.background) }; Text(working ? "Signing and sending…" : "Confirm & send") }
            }.buttonStyle(WalletActionStyle(primary: true)).disabled(working || model.busy)
            Button("Edit payment") { self.proposal = nil; error = nil }
                .buttonStyle(WalletActionStyle()).disabled(working)
        }
    }

    private func success(_ receipt: PaymentReceipt) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "checkmark").font(.largeTitle).foregroundStyle(WalletTheme.green)
            Text("Payment broadcast").font(.title2.bold())
            Text("Waiting for network confirmation.").foregroundStyle(.secondary)
            Text(receipt.txid).font(WalletFont.numbers(12)).textSelection(.enabled)
            if let warning = receipt.warning { Text(warning).foregroundStyle(WalletTheme.yellow).font(.footnote) }
            Button("Done") { dismiss() }.buttonStyle(WalletActionStyle(primary: true))
        }
    }

    private func loadSpendable() async {
        guard !model.busy, let wallet = model.wallet, let id = model.selectedAccountID else { return }
        let required = confirmations
        do {
            let values = try await wallet.spendablePools(accountId: id,
                height: model.chainTip ?? model.heights[id] ?? 0, confirmations: required)
            guard !Task.isCancelled, id == model.selectedAccountID, required == confirmations else { return }
            spendable = values
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func prepare() async {
        guard valid, !working, !model.busy, let wallet = model.wallet, let id = model.selectedAccountID else { return }
        working = true; error = nil
        defer { working = false }
        do {
            proposal = try await wallet.preparePayment(request: PaymentRequest(accountId: id,
                address: address, amount: amount, memo: finalMemo.isEmpty ? nil : finalMemo,
                sourcePools: pools, deductFee: deductFee, confirmations: confirmations))
        } catch { self.error = error.localizedDescription }
    }
    private func submit(_ proposal: PreparedPayment) async {
        guard !working, !model.busy, let wallet = model.wallet else { return }
        working = true; error = nil
        do {
            receipt = try await wallet.submitPayment(payment: proposal)
            self.proposal = nil
            await model.refresh()
        } catch {
            self.proposal = nil // consumed proposals are never retried
            self.error = error.localizedDescription
        }
        working = false
    }
}

// Exact decimal input; a keypad tap never turns currency into Double.
enum PaymentDraft {
    static func appending(_ key: String, to value: String) -> String {
        if key == "⌫" { return value.count > 1 ? String(value.dropLast()) : "0" }
        if key == "." { return value.contains(".") ? value : value + "." }
        guard key.count == 1, key.first?.isNumber == true else { return value }
        if let dot = value.firstIndex(of: "."), value.distance(from: dot, to: value.endIndex) > 8 { return value }
        return value == "0" ? key : value + key
    }
    static func validAmount(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2, !parts[0].isEmpty, parts[0].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              parts.count == 1 || (parts[1].count <= 8 && parts[1].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })),
              let number = Decimal(string: value), number > 0, number <= 21_000_000 else { return false }
        return true
    }
    static func memo(subject: String, text: String, returnAddress: String?) -> String {
        [subject.isEmpty ? nil : "Subject: \(subject)", text.isEmpty ? nil : text,
         returnAddress.map { "Reply to: \($0)" }].compactMap { $0 }.joined(separator: "\n")
    }
}

private extension View {
    func paymentInputBehavior(decimal: Bool = false) -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(decimal ? .decimalPad : .default)
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

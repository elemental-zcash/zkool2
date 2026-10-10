import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct ReceivingAddress: Identifiable {
    let id: String
    let name: String
    let value: String
    static func options(_ addresses: WalletAddresses?) -> [Self] {
        guard let addresses else { return [] }
        return [("main", "Main address", addresses.ua), ("orchard", "Orchard address", addresses.orchard),
                ("sapling", "Sapling address", addresses.sapling), ("transparent", "Transparent address", addresses.transparent)]
            .compactMap { id, name, value in
                guard let value, !value.isEmpty else { return nil }
                return Self(id: id, name: name, value: value)
            }
    }
    var abbreviated: String {
        func grouped(_ string: String) -> String {
            stride(from: 0, to: string.count, by: 4).map { index in
                let start = string.index(string.startIndex, offsetBy: index)
                let end = string.index(start, offsetBy: min(4, string.count - index))
                return String(string[start..<end])
            }.joined(separator: " ")
        }
        return value.count > 20 ? grouped(String(value.prefix(8))) + " … " + grouped(String(value.suffix(8))) : grouped(value)
    }
}

struct ReceiveView: View {
    @EnvironmentObject private var model: WalletModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection = "main"
    @State private var expanded = false
    @State private var copiedAddress: String?
    init(initiallyExpanded: Bool = false) { _expanded = State(initialValue: initiallyExpanded) }
    private var options: [ReceivingAddress] { ReceivingAddress.options(model.overview?.address) }
    private var selected: ReceivingAddress? { options.first { $0.id == selection } ?? options.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text(model.selectedAccount?.name ?? "Receive Zcash").font(.headline)
                        Spacer()
                        Button { dismiss() } label: { Image(systemName: "xmark").padding(10) }
                            .buttonStyle(.plain).accessibilityLabel("Close receiving")
                    }
                    WalletSyncIndicator()
                    balance
                    if let selected {
                        if let qr = try? WalletReceiveQR(address: selected.value) {
                            WalletReceiveQRView(qr: qr).frame(maxWidth: 440).frame(maxWidth: .infinity)
                            addressDetails(selected)
                            selector
                            HStack(spacing: 12) {
                                Button { copy(selected.value) } label: {
                                    Label(copiedAddress == selected.value ? "Copied" : "Copy address",
                                          systemImage: copiedAddress == selected.value ? "checkmark" : "doc.on.doc")
                                }.buttonStyle(WalletActionStyle(primary: true))
                                Menu {
                                    ShareLink(item: selected.value) { Label("Share address", systemImage: "square.and.arrow.up") }
                                    ShareLink(item: ReceivingSVG(svg: qr.svg),
                                              preview: SharePreview("Zcash receiving QR", image: Image(systemName: "qrcode"))) {
                                        Label("Share QR as SVG", systemImage: "qrcode")
                                    }
                                } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain)
                                    .walletActionSurface().tint(.white)
                            }
                        } else {
                            Text("This address could not be encoded as a QR code.").foregroundStyle(WalletTheme.coral)
                            addressDetails(selected)
                            selector
                            ShareLink(item: selected.value) { Text("Share address") }.buttonStyle(WalletActionStyle(primary: true))
                        }
                    } else {
                        Text("No receiving address is available for this account.").foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }.background(WalletTheme.background).walletNavigationChrome()
        }.tint(WalletTheme.green).preferredColorScheme(.dark)
    }

    private var balance: some View {
        let parts = WalletMoney.format(model.overview?.balance.total ?? "0").components(separatedBy: ".")
        let whole = parts.first ?? "—"
        let fraction = parts.count > 1 ? parts[1] : ""
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(whole + "." + String(fraction.prefix(3))).font(WalletFont.numbers(42, bold: true))
            Text(String(fraction.dropFirst(3))).font(WalletFont.numbers(17, bold: true))
            Text("ZEC").font(WalletFont.numbers(17, bold: true)).padding(.leading, 5)
        }.lineLimit(1).minimumScaleFactor(0.5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Account balance \(WalletMoney.format(model.overview?.balance.total ?? "0")) ZEC")
    }

    private func addressDetails(_ address: ReceivingAddress) -> some View {
        VStack(spacing: 16) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    Text(address.abbreviated).font(WalletFont.numbers(17, bold: true)).lineLimit(1).minimumScaleFactor(0.6)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.plain).foregroundStyle(.white)
                .accessibilityLabel(expanded ? "Collapse full address" : "Show full address")
            if expanded {
                Text(address.value).font(WalletFont.numbers(13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16).background(WalletTheme.surface)
                    .accessibilityLabel("Full receiving address: \(address.value)")
            }
        }
    }

    private var selector: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.id
                    expanded = false
                    copiedAddress = nil
                } label: {
                    if selected?.id == option.id { Label(option.name, systemImage: "checkmark") }
                    else { Text(option.name) }
                }
            }
        } label: {
            HStack { Text(selected?.name ?? "Address"); Image(systemName: "chevron.down") }
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain)
            .walletActionSurface().tint(.white)
            .accessibilityLabel("Receiving address type: \(selected?.name ?? "None")")
    }

    private func copy(_ address: String) {
        #if os(iOS)
        UIPasteboard.general.string = address
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        #endif
        copiedAddress = address
    }
}

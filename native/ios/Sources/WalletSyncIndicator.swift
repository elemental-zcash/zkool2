import SwiftUI

struct WalletSyncIndicator: View {
    @EnvironmentObject private var model: WalletModel
    private var active: Bool { model.syncing && model.syncingAccountID == model.selectedAccountID }
    private var color: Color {
        model.syncState == .synced ? WalletTheme.green :
            (model.syncState == .failed ? WalletTheme.coral : WalletTheme.yellow)
    }
    private var progress: Double? {
        guard active, let start = model.syncStartHeight, let tip = model.chainTip,
              let current = model.currentHeight, tip > start else { return nil }
        return min(1, max(0, Double(Int64(current) - Int64(start)) / Double(tip - start)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.currentHeight.map(String.init) ?? "––").font(WalletFont.numbers(20, bold: true))
                Text(model.heightCaption).font(WalletFont.numbers(10)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Button {
                    Task {
                        if active { await model.cancelSync() }
                        else { await model.synchronizeSelected() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(model.syncState.label.lowercased()).font(WalletFont.numbers(13, bold: true))
                        Image(systemName: active ? "xmark" : (model.syncState == .synced ? "checkmark" : "arrow.clockwise"))
                    }.padding(.vertical, 10)
                }.buttonStyle(.plain)
                    .disabled(model.selectedAccountID == nil || model.cancelRequested || (model.busy && !active))
                    .accessibilityLabel("\(model.syncState.label). \(active ? "Cancel sync" : "Start sync")")
            }.foregroundStyle(color)
            if active {
                if let progress {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.8))
                            Rectangle().fill(WalletTheme.green).frame(width: geometry.size.width * progress)
                        }
                    }.frame(height: 3).accessibilityLabel("Block scan progress")
                        .accessibilityValue("\(Int(progress * 100)) percent")
                    HStack {
                        Text(model.cancelRequested ? "Saving progress before stopping…" :
                             (progress >= 1 ? "Finishing and saving…" : "Scanning blocks"))
                        Spacer()
                        Text("\(Int(progress * 100))%").font(WalletFont.numbers(11))
                    }.font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(WalletTheme.green)
                    Text(model.cancelRequested ? "Stopping…" : "Connecting and preparing scan…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 4)
    }
}

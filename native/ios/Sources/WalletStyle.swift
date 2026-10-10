import SwiftUI
import CoreText

// Palette and stacked balance treatment follow the supplied wallet reference.
enum WalletTheme {
    static let background = Color(red: 0.045, green: 0.07, blue: 0.075)
    static let surface = Color(red: 0.095, green: 0.13, blue: 0.14)
    static let green = Color(red: 0.22, green: 1, blue: 0.62)
    static let coral = Color(red: 1, green: 0.40, blue: 0.42)
    static let yellow = Color(red: 1, green: 0.91, blue: 0.44)
    static let orange = Color(red: 1, green: 0.57, blue: 0.18)
    static let gold = Color(red: 1, green: 0.75, blue: 0.14)
}

enum WalletMoney {
    static func format(_ value: String, digits: Int = 8) -> String {
        guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.roundingMode = .down
        return formatter.string(from: NSDecimalNumber(decimal: decimal)) ?? "—"
    }
}

struct WalletActionStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.walletActionSurface(primary: primary, pressed: configuration.isPressed)
    }
}

private struct WalletActionSurface: ViewModifier {
    var primary: Bool
    var pressed: Bool
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content.font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 15).padding(.horizontal, 12)
            .foregroundStyle(primary ? WalletTheme.background : Color.white)
            .background(primary ? WalletTheme.green : Color.white.opacity(0.08))
            .clipShape(Rectangle())
            .opacity(enabled ? (pressed ? 0.75 : 1) : 0.35)
    }
}

extension View {
    // Menus and buttons share the same surface; Menu does not honor ButtonStyle on macOS.
    func walletActionSurface(primary: Bool = false, pressed: Bool = false) -> some View {
        modifier(WalletActionSurface(primary: primary, pressed: pressed))
    }

    func walletCard() -> some View {
        self.padding(20).background(WalletTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.white.opacity(0.04)))
    }

    func walletInput(url: Bool = false, number: Bool = false) -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
            .keyboardType(url ? .URL : (number ? .numberPad : .default))
            .padding(16).background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        #else
        self.autocorrectionDisabled().padding(16).background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        #endif
    }

    func walletNavigationChrome() -> some View {
        #if os(iOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

// Bundle the licensed font so number typography is identical on every device.
enum WalletFont {
    static func numbers(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "IBMPlexMono-Bold" : "IBMPlexMono-Regular", size: size, relativeTo: .body)
    }
    static func register(at directory: URL? = nil) {
        for name in ["IBMPlexMono-Regular", "IBMPlexMono-Bold"] {
            let url = directory?.appendingPathComponent(name + ".ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf")
            if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }
}

// Pool ribbons overlap. Their lower edges stay flat, without scalloped corners.
struct PoolRibbon: Shape {
    var radius: CGFloat = 24
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

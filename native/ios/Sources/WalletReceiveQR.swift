import SwiftUI
import QRCodeGenerator
import CoreTransferable
import UniformTypeIdentifiers

// The library encodes the full address. Display paths and SVG use that same matrix.
struct WalletReceiveQR {
    let code: QRCode
    static let border = 4
    static let backgroundHex = "#0b1213"
    var dimension: CGFloat { CGFloat(code.size + Self.border * 2) }
    var center: CGFloat { dimension / 2 }
    var maskRadius: CGFloat { CGFloat(code.size) * 0.10 }
    var logoRadius: CGFloat { CGFloat(code.size) * 0.08 }
    var markSide: CGFloat { CGFloat(code.size) * 0.12 }

    init(address: String) throws { code = try QRCode.encode(text: address, ecl: .high) }

    var modules: Path {
        var path = Path()
        for y in 0..<code.size {
            for x in 0..<code.size where code.getModule(x: x, y: y) {
                path.addRect(CGRect(x: x + Self.border, y: y + Self.border, width: 1, height: 1))
            }
        }
        return path
    }
    var mask: CGRect { CGRect(x: center - maskRadius, y: center - maskRadius, width: maskRadius * 2, height: maskRadius * 2) }
    var logo: CGRect { CGRect(x: center - logoRadius, y: center - logoRadius, width: logoRadius * 2, height: logoRadius * 2) }
    var mark: Path {
        ZcashMark.path.applying(CGAffineTransform(a: markSide / 100, b: 0, c: 0, d: markSide / 100,
            tx: center - markSide / 2, ty: center - markSide / 2))
    }
    var svg: String {
        let base = code.toSVGString(border: Self.border, foreground: "#ffffff", background: Self.backgroundHex)
            .replacingOccurrences(of: "stroke=\"none\">", with: "width=\"1024\" height=\"1024\" stroke=\"none\">")
        let badge = """
          <circle cx="\(center)" cy="\(center)" r="\(maskRadius)" fill="\(Self.backgroundHex)"/>
          <circle cx="\(center)" cy="\(center)" r="\(logoRadius)" fill="#ffffff"/>
          <g transform="translate(\(center - markSide / 2) \(center - markSide / 2)) scale(\(markSide / 100))" fill="\(Self.backgroundHex)">
            <path d="\(ZcashMark.svgPath)"/>
          </g>
        </svg>
        """
        return base.replacingOccurrences(of: "</svg>", with: badge)
    }

    // Used to verify that the branded vector still decodes to the original address.
    func image(side: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.045, green: 0.07, blue: 0.075, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: CGFloat(side) / dimension, y: -CGFloat(side) / dimension)
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.addPath(modules.cgPath); context.fillPath()
        context.setShouldAntialias(true)
        context.setFillColor(CGColor(red: 0.045, green: 0.07, blue: 0.075, alpha: 1)); context.fillEllipse(in: mask)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillEllipse(in: logo)
        context.setFillColor(CGColor(red: 0.045, green: 0.07, blue: 0.075, alpha: 1)); context.addPath(mark.cgPath); context.fillPath()
        return context.makeImage()
    }
}

private enum ZcashMark {
    static let svgPath = "M22 26H78V38L43 66H78V78H22V66L57 38H22Z M44 14H56V26H44Z M44 78H56V90H44Z"
    static var path: Path {
        var path = Path()
        path.move(to: CGPoint(x: 22, y: 26))
        for point in [CGPoint(x: 78, y: 26), CGPoint(x: 78, y: 38), CGPoint(x: 43, y: 66),
                      CGPoint(x: 78, y: 66), CGPoint(x: 78, y: 78), CGPoint(x: 22, y: 78),
                      CGPoint(x: 22, y: 66), CGPoint(x: 57, y: 38), CGPoint(x: 22, y: 38)] { path.addLine(to: point) }
        path.closeSubpath()
        path.addRect(CGRect(x: 44, y: 14, width: 12, height: 12))
        path.addRect(CGRect(x: 44, y: 78, width: 12, height: 12))
        return path
    }
}

struct WalletReceiveQRView: View {
    let qr: WalletReceiveQR
    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / qr.dimension
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            ZStack(alignment: .topLeading) {
                WalletTheme.background
                qr.modules.applying(transform).fill(.white, style: FillStyle(antialiased: false))
                Circle().fill(WalletTheme.background).frame(width: qr.mask.width * scale, height: qr.mask.height * scale)
                    .position(x: qr.center * scale, y: qr.center * scale)
                Circle().fill(.white).frame(width: qr.logo.width * scale, height: qr.logo.height * scale)
                    .position(x: qr.center * scale, y: qr.center * scale)
                qr.mark.applying(transform).fill(WalletTheme.background)
            }
        }.aspectRatio(1, contentMode: .fit)
            .accessibilityElement(children: .ignore).accessibilityLabel("Receiving address QR code")
    }
}

struct ReceivingSVG: Transferable {
    let svg: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .svg) { Data($0.svg.utf8) }
            .suggestedFileName("Zkool-receiving-address.svg")
    }
}

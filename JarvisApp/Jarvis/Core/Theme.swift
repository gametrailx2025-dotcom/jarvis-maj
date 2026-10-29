import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum Theme {
    static let bg = Color(red: 0.016, green: 0.027, blue: 0.047)
    static let panel = Color(red: 0.03, green: 0.08, blue: 0.13).opacity(0.72)
    static let text = Color(red: 0.85, green: 0.965, blue: 1.0)
    static let muted = Color(red: 0.43, green: 0.56, blue: 0.64)
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.28)
    static let red = Color(red: 1.0, green: 0.30, blue: 0.42)
    static let green = Color(red: 0.24, green: 1.0, blue: 0.69)
    static let defaultAccent = "#00E5FF"

    /// Couleur principale de JARVIS, choisie dans les Réglages (et partagée via le compte).
    static var accentHex: String {
        UserDefaults.standard.string(forKey: SettingsKey.accentHex) ?? defaultAccent
    }

    static var cyan: Color { Color(hex: accentHex) ?? Color(red: 0.0, green: 0.898, blue: 1.0) }

    /// Version éclaircie de la couleur principale.
    static var cyanSoft: Color {
        guard let c = Color.rgb(fromHex: accentHex) else {
            return Color(red: 0.435, green: 0.953, blue: 1.0)
        }
        return Color(red: c.0 + (1 - c.0) * 0.5, green: c.1 + (1 - c.1) * 0.5, blue: c.2 + (1 - c.2) * 0.5)
    }

    static let presets: [(String, String)] = [
        ("Cyan", "#00E5FF"), ("Bleu", "#2F7BFF"), ("Violet", "#B45CFF"), ("Rouge", "#FF3B5C"), ("Orange", "#FF6A00"),
        ("Or", "#FFB000"), ("Vert", "#2BFF9E"), ("Rose", "#FF4FD8"), ("Blanc", "#E8F4FF"),
    ]

    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Clés des réglages (UserDefaults). Les secrets vont dans le trousseau (Keychain).
enum SettingsKey {
    static let pcURL = "pcURL"
    static let userName = "userName"
    static let city = "city"
    static let aiProvider = "aiProvider"
    static let aiModel = "aiModel"
    static let ollamaURL = "ollamaURL"
    static let voiceEnabled = "voiceEnabled"
    static let useLocation = "useLocation"
    static let accentHex = "accentHex"
    static let wakeWord = "wakeWord"
    static let supabaseURL = "supabaseURL"
    static let supabaseKey = "supabaseKey"
}

extension Color {
    static func rgb(fromHex hex: String) -> (Double, Double, Double)? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    init?(hex: String) {
        guard let c = Color.rgb(fromHex: hex) else { return nil }
        self.init(red: c.0, green: c.1, blue: c.2)
    }

    /// Couleur → « #RRGGBB » (pour l'enregistrer et la partager).
    var hexString: String? {
        #if os(iOS)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #else
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        #endif
        func clamp(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}

/// Carte moderne : verre dépoli, coins arrondis, liseré dégradé, titre discret avec pastille de couleur.
struct Panel<Content: View>: View {
    let title: String
    var tag: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.cyan)
                    .frame(width: 7, height: 7)
                    .shadow(color: Theme.cyan.opacity(0.8), radius: 4)
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.text.opacity(0.92))
                Spacer()
                if let tag {
                    Text(tag)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.cyanSoft)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.cyan.opacity(0.12)))
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.cyan.opacity(0.08), Color.black.opacity(0.25)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Theme.cyan.opacity(0.45), Color.white.opacity(0.06),
                                                      Theme.cyan.opacity(0.12)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 18, y: 8)
    }
}

/// Fond moderne : dégradé profond + halos de couleur flous qui dérivent lentement (« aurore »), grain discret.
struct BackgroundView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { tl in
            let t = CGFloat(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000))
            ZStack {
                LinearGradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.06), Theme.bg,
                                        Color(red: 0.01, green: 0.015, blue: 0.03)],
                               startPoint: .top, endPoint: .bottom)
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    ZStack {
                        blob(Theme.cyan.opacity(0.22), size: w * 0.7)
                            .position(x: w * (0.25 + 0.06 * sin(t * 0.07)), y: h * (0.2 + 0.05 * cos(t * 0.05)))
                        blob(Theme.cyanSoft.opacity(0.10), size: w * 0.6)
                            .position(x: w * (0.8 + 0.05 * cos(t * 0.06)), y: h * (0.75 + 0.05 * sin(t * 0.08)))
                        blob(Color(red: 0.35, green: 0.2, blue: 0.9).opacity(0.10), size: w * 0.5)
                            .position(x: w * (0.65 + 0.07 * sin(t * 0.04)), y: h * (0.15 + 0.04 * sin(t * 0.09)))
                    }
                }
                // Grille très légère, qui s'estompe vers les bords
                Canvas { ctx, size in
                    var p = Path()
                    let step: CGFloat = 56
                    var x: CGFloat = 0
                    while x <= size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                    var y: CGFloat = 0
                    while y <= size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                    ctx.stroke(p, with: .color(Color.white.opacity(0.025)), lineWidth: 0.5)
                }
                .mask(RadialGradient(colors: [.white, .clear], center: .center, startRadius: 50, endRadius: 700))
            }
        }
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color, .clear], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .blur(radius: 40)
    }
}

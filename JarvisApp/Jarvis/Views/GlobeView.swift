import SwiftUI
import WebKit

/// Onglet Globe : la vue 3D de la planète (avions, bateaux, satellites, séismes, météo, caméras publiques…)
/// tirée du projet open source God's Eye View, affichée dans JARVIS.
struct GlobeCategory: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var globe: GlobeServer

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("GLOBE", systemImage: "globe.europe.africa.fill")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(Theme.cyan)
                Spacer()
                statusChip
                if globe.status == .ready {
                    Button { Task { await globe.restart() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Redémarrer le globe")
                }
            }
            .padding(.horizontal, 16)

            switch globe.status {
            case .ready:
                WebPage(url: GlobeServer.url)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cyan.opacity(0.35), lineWidth: 1))
                    .padding([.horizontal, .bottom], 12)
            case .starting, .idle, .installing:
                VStack(spacing: 14) {
                    CoreView(mode: .thinking, size: 110)
                    Text(globe.status == .installing ? "Installation du globe (une seule fois, 2 à 5 min)…"
                                                     : "Initialisation du globe…")
                        .foregroundStyle(Theme.cyanSoft)
                    Text(globe.log.last ?? "Le premier démarrage peut prendre jusqu'à une minute.")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                        .lineLimit(1).frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let why), .failed(let why):
                VStack(spacing: 12) {
                    Image(systemName: "globe.badge.chevron.backward").font(.system(size: 44)).foregroundStyle(Theme.cyan)
                    Text(why).multilineTextAlignment(.center).foregroundStyle(Theme.cyanSoft).frame(maxWidth: 520)
                    Button("Réessayer") { Task { await globe.start() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await globe.start() }
    }

    private var statusChip: some View {
        let (text, color): (String, Color) = {
            switch globe.status {
            case .ready: return ("EN DIRECT", Theme.green)
            case .starting, .idle: return ("DÉMARRAGE", Theme.cyan)
            case .installing: return ("INSTALLATION", Theme.cyan)
            case .unavailable: return ("NON INSTALLÉ", Theme.muted)
            case .failed: return ("ERREUR", .orange)
            }
        }()
        return Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(2)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().stroke(color.opacity(0.6), lineWidth: 1))
    }
}

/// Page web intégrée (WKWebView), compatible Mac et iPhone.
struct WebPage {
    let url: URL

    fileprivate func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // garde les réglages du globe entre deux ouvertures
        let view = WKWebView(frame: .zero, configuration: config)
        if url.isFileURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: url))
        }
        return view
    }
}

#if os(macOS)
extension WebPage: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
extension WebPage: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

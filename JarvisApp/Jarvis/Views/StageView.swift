import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Ce que JARVIS affiche en grand (mode « Iron Man ») : un site, une image, un fichier ou le globe.
enum StageContent: Equatable {
    case web(URL)
    case image(URL, String)
    case file(URL)
    case globe

    var title: String {
        switch self {
        case .web(let url): return url.host ?? url.absoluteString
        case .image(_, let title): return title
        case .file(let url): return url.lastPathComponent
        case .globe: return "Globe"
        }
    }

    var symbol: String {
        switch self {
        case .web: return "safari"
        case .image: return "photo"
        case .file: return "doc.text"
        case .globe: return "globe.europe.africa.fill"
        }
    }

    /// Adresse ouvrable à l'extérieur (navigateur, Aperçu…).
    var externalURL: URL? {
        switch self {
        case .web(let url), .image(let url, _), .file(let url): return url
        case .globe: return GlobeServer.url
        }
    }
}

/// Coin où JARVIS se place pendant qu'il affiche quelque chose.
enum StageCorner: String, CaseIterable {
    case topTrailing, topLeading, bottomLeading, bottomTrailing

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    var label: String {
        switch self {
        case .topLeading: return "en haut à gauche"
        case .topTrailing: return "en haut à droite"
        case .bottomLeading: return "en bas à gauche"
        case .bottomTrailing: return "en bas à droite"
        }
    }

    var next: StageCorner {
        let all = StageCorner.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Écran « Iron Man » : le contenu prend toute la place, JARVIS se met dans un coin, on peut continuer à lui parler.
struct StageView: View {
    @EnvironmentObject var model: AppModel
    let content: StageContent

    var body: some View {
        ZStack(alignment: model.stageCorner.alignment) {
            VStack(spacing: 10) {
                toolbar
                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.35)))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [Theme.cyan.opacity(0.6), Theme.cyan.opacity(0.1)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    )
                    .shadow(color: Theme.cyan.opacity(0.25), radius: 24)
                if let pending = model.pendingLabel { ConfirmBar(text: pending) }
                InputBar()
            }
            .padding(16)

            // JARVIS en petit, dans le coin choisi
            VStack(spacing: 2) {
                CoreView(mode: model.coreMode, size: 120)
                if let last = model.messages.last, !last.fromUser {
                    Text(last.text)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, model.stageCorner == .topLeading || model.stageCorner == .topTrailing ? 60 : 0)
            .padding(.bottom, model.stageCorner == .bottomLeading || model.stageCorner == .bottomTrailing ? 90 : 0)
            .onTapGesture { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { model.stageCorner = model.stageCorner.next } }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: content.symbol).foregroundStyle(Theme.cyan)
            Text(content.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
            if let url = content.externalURL {
                Button {
                    #if os(macOS)
                    NSWorkspace.shared.open(url)
                    #else
                    UIApplication.shared.open(url)
                    #endif
                } label: { Label("Ouvrir à part", systemImage: "arrow.up.right.square") }
                    .buttonStyle(HUDButtonStyle(filled: false))
            }
            Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { model.stageCorner = model.stageCorner.next } } label: {
                Label("Déplacer JARVIS", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            }
            .buttonStyle(HUDButtonStyle(filled: false))
            Button { model.closeStage() } label: { Label("Fermer", systemImage: "xmark") }
                .buttonStyle(HUDButtonStyle(filled: true))
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var contentView: some View {
        switch content {
        case .web(let url):
            WebPage(url: url).id(url)
        case .file(let url):
            WebPage(url: url).id(url)
        case .image(let url, _):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit().padding(12)
                case .failure:
                    Text("Image indisponible.").foregroundStyle(Theme.muted)
                default:
                    ProgressView().tint(Theme.cyan)
                }
            }
        case .globe:
            GlobeCategory(globe: model.globe)
        }
    }
}

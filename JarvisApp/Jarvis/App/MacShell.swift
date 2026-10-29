#if os(macOS)
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// MARK: - Application : reste ouverte en arrière-plan

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Fermer la fenêtre ne quitte pas JARVIS : il continue d'écouter « Jarvis » en arrière-plan.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clic sur l'icône du Dock : on rouvre la fenêtre principale.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            OverlayController.shared.hide()
            MacShell.mainWindows.first?.makeKeyAndOrderFront(nil)
        }
        return true   // sans fenêtre, SwiftUI en recrée une
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Typist.startTracking() }
    }
}

@MainActor
enum MacShell {
    private static var activity: NSObjectProtocol?

    /// Démarrage du Mac : JARVIS se lance seul, sans fenêtre, juste le mini-JARVIS sur le côté de l'écran.
    static var launchedAtLogin: Bool { ProcessInfo.processInfo.systemUptime < 240 }

    static func configureAtStart(model: AppModel) {
        // Empêche macOS de mettre JARVIS en sommeil (App Nap) : il doit entendre « Jarvis » à tout moment.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "Écoute du mot « Jarvis »")
        }
        LoginItem.registerOnFirstLaunch()
        MenuBarItem.shared.install(model: model)
        GlobalHotKey.shared.register { [weak model] in
            guard let model else { return }
            OverlayController.shared.toggle(model: model)
        }
        if launchedAtLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                hideMainWindows()
                OverlayController.shared.show(model: model)
            }
        }
    }

    static var mainWindows: [NSWindow] {
        NSApp.windows.filter { !($0 is OverlayPanel) && $0.canBecomeMain }
    }

    static func hideMainWindows() {
        mainWindows.forEach { $0.orderOut(nil) }
    }

    static func showMainWindow() {
        OverlayController.shared.hide()
        NSApp.activate(ignoringOtherApps: true)
        if let w = mainWindows.first {
            w.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.open(Bundle.main.bundleURL)   // recrée la fenêtre si elle a été fermée
        }
    }

    /// L'utilisateur est-il dans une autre application (fenêtre JARVIS invisible ou en arrière-plan) ?
    static var userIsElsewhere: Bool {
        !NSApp.isActive || !mainWindows.contains { $0.isVisible }
    }
}

// MARK: - Lancement au démarrage du Mac

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("JARVIS — ouverture au démarrage : %@", error.localizedDescription)
        }
    }

    static func registerOnFirstLaunch() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - Mini-JARVIS flottant (fenêtre double)

/// Petite fenêtre toujours au premier plan, sans voler le focus de l'application en cours.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }       // pour pouvoir taper dans son champ de texte
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    static let shared = OverlayController()
    private var panel: OverlayPanel?
    private let size = NSSize(width: 300, height: 400)

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(model: AppModel) {
        // Pas de compte = pas de JARVIS : on affiche l'écran de connexion à la place.
        if !model.accounts.isSignedIn {
            MacShell.showMainWindow()
            return
        }
        if panel == nil {
            let p = OverlayPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.contentView = NSHostingView(rootView: MiniJarvisView().environmentObject(model))
            panel = p
        }
        guard let panel else { return }
        place(panel, corner: model.stageCorner)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle(model: AppModel) {
        if isVisible { hide() } else { show(model: model); panel?.makeKey() }
    }

    private func place(_ panel: NSPanel, corner: StageCorner) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let m: CGFloat = 18
        let x: CGFloat
        let y: CGFloat
        switch corner {
        case .topLeading: x = screen.minX + m; y = screen.maxY - size.height - m
        case .topTrailing: x = screen.maxX - size.width - m; y = screen.maxY - size.height - m
        case .bottomLeading: x = screen.minX + m; y = screen.minY + m
        case .bottomTrailing: x = screen.maxX - size.width - m; y = screen.minY + m
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

/// Contenu du mini-JARVIS : l'hologramme, sa dernière réponse, un champ pour écrire.
struct MiniJarvisView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("JARVIS")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(Theme.cyan)
                Spacer()
                Button { MacShell.showMainWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Ouvrir la fenêtre JARVIS")
                Button { OverlayController.shared.hide() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Masquer (dites « Jarvis » pour le rappeler)")
            }
            CoreView(mode: model.coreMode, size: 170)
                .frame(height: 175)
            if let last = model.messages.last {
                Text(last.text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(last.fromUser ? Theme.cyanSoft : Theme.text)
                    .lineLimit(5)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                TextField("Écrivez à JARVIS…", text: $text)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.cyan))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.cyan.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .preferredColorScheme(.dark)
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        text = ""
        Task { await model.send(t) }
    }
}

// MARK: - Plusieurs écrans : une fenêtre de catégories par écran supplémentaire

@MainActor
final class MultiScreen {
    static let shared = MultiScreen()
    private var windows: [NSWindow] = []

    func apply(model: AppModel) {
        windows.forEach { $0.close() }
        windows.removeAll()
        let screens = NSScreen.screens
        for (i, tabs) in model.screenGroups.enumerated() {
            let frame: NSRect
            if i + 1 < screens.count {
                frame = screens[i + 1].visibleFrame
            } else {
                // Pas assez d'écrans branchés : fenêtres en cascade sur l'écran principal
                let base = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                frame = NSRect(x: base.minX + 60 + CGFloat(i) * 50, y: base.minY + 60, width: base.width * 0.6, height: base.height * 0.7)
            }
            let w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "JARVIS — écran \(i + 2)"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ScreenCategoriesView(tabs: tabs, index: i + 2).environmentObject(model))
            w.setFrame(frame, display: true)
            w.orderFront(nil)
            windows.append(w)
        }
    }
}

// MARK: - Icône JARVIS dans la barre des menus

@MainActor
final class MenuBarItem: NSObject {
    static let shared = MenuBarItem()
    private var item: NSStatusItem?
    private weak var model: AppModel?

    func install(model: AppModel) {
        self.model = model
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = it.button {
            button.image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "JARVIS")
            button.toolTip = "JARVIS — ⌥ Espace pour le mini-JARVIS"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Mini-JARVIS (⌥ Espace)", action: #selector(mini), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Ouvrir JARVIS", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter JARVIS", action: #selector(quit), keyEquivalent: "q").target = self
        it.menu = menu
        item = it
    }

    @objc private func mini() { if let model { OverlayController.shared.toggle(model: model) } }
    @objc private func open() { MacShell.showMainWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Raccourci global ⌥ Espace (fonctionne depuis n'importe quelle application)

@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    fileprivate var action: (() -> Void)?

    func register(_ action: @escaping () -> Void) {
        self.action = action
        guard ref == nil else { return }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), jarvisHotKeyHandler, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x4A525653), id: 1)   // « JRVS »
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

/// Appelé par macOS quand ⌥ Espace est pressé (fonction C, hors de tout acteur).
private func jarvisHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                 _ data: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.action?() } }
    return noErr
}

// MARK: - Écrire à la place de l'utilisateur (dans l'application au premier plan)

@MainActor
enum Typist {
    /// Dernière application utilisée avant JARVIS : c'est là que le texte sera tapé.
    private(set) static var lastExternalApp: NSRunningApplication?
    private static var observer: NSObjectProtocol?

    static func startTracking() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier { lastExternalApp = app }
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = front
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Demande l'autorisation « Accessibilité » (nécessaire pour taper au clavier à votre place).
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Tape le texte dans la dernière application utilisée. Renvoie faux si l'autorisation manque.
    static func type(_ text: String) async -> Bool {
        guard isTrusted else {
            requestTrust()
            return false
        }
        if let app = lastExternalApp, !app.isTerminated {
            app.activate(options: [])
            try? await Task.sleep(nanoseconds: 450_000_000)
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var units = Array(line.utf16)
            var start = 0
            while start < units.count {
                let end = min(start + 16, units.count)
                var chunk = Array(units[start..<end])
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                   let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                    up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
                start = end
                try? await Task.sleep(nanoseconds: 12_000_000)
            }
            units.removeAll()
            if index < lines.count - 1 {
                // Maj + Entrée : nouvelle ligne sans envoyer le message dans les messageries
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
                   let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) {
                    down.flags = .maskShift
                    up.flags = .maskShift
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        return true
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif

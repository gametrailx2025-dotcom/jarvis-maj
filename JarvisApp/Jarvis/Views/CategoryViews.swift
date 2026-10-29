import SwiftUI

// MARK: - Barre des catégories

struct CategoryBar: View {
    @EnvironmentObject var model: AppModel
    @Namespace private var tabNS
    private let tabs: [AppTab]?
    private let selection: Binding<AppTab>?

    /// Sans paramètre : la barre de la fenêtre principale. Avec : celle d'un écran supplémentaire.
    init(tabs: [AppTab]? = nil, selection: Binding<AppTab>? = nil) {
        self.tabs = tabs
        self.selection = selection
    }

    private var current: AppTab { selection?.wrappedValue ?? model.tab }

    private func select(_ tab: AppTab) {
        if let selection { selection.wrappedValue = tab } else { model.tab = tab }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs ?? model.mainTabs) { tab in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { select(tab) }
                    } label: {
                        Label(tab.label, systemImage: tab.symbol)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(current == tab ? Color.black.opacity(0.85) : Theme.text.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background {
                                if current == tab {
                                    Capsule()
                                        .fill(LinearGradient(colors: [Theme.cyanSoft, Theme.cyan],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .shadow(color: Theme.cyan.opacity(0.5), radius: 8)
                                        .matchedGeometryEffect(id: "tab", in: tabNS)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(5)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

/// Carte d'action (une commande envoyée à JARVIS).
struct ActionCard: View {
    let title: String
    var subtitle: String = ""
    var warn: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .padding(12)
            .background((warn ? Theme.amber : Theme.cyan).opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke((warn ? Theme.amber : Theme.cyan).opacity(0.35)))
        }
        .buttonStyle(.plain)
    }
}

private let cardColumns = [GridItem(.adaptive(minimum: 170), spacing: 10)]

/// Message quand une catégorie a besoin du PC.
struct NeedsPC: View {
    @EnvironmentObject var model: AppModel
    let what: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(what) se fait sur votre PC.").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Installez JARVIS sur le PC puis reliez-le dans les Réglages (tutoriel, étape N).")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            Button("Ouvrir les Réglages") { model.showSettings = true }.buttonStyle(HUDButtonStyle(filled: false))
        }
    }
}

// MARK: - Système

struct SystemCategory: View {
    @EnvironmentObject var model: AppModel
    @State private var showPC = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.isConnected {
                    Picker("Appareil", selection: $showPC) {
                        Text(model.local.deviceName.capitalized).tag(false)
                        Text("Mon PC").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if showPC && model.isConnected {
                    pcView
                } else {
                    localView
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder private var localView: some View {
        if let s = model.local.stats {
            Panel(title: "Ressources · \(model.local.deviceName)", tag: uptime(s.uptime)) {
                HStack {
                    RingGauge(value: s.cpu, label: "Processeur", text: "\(Int(s.cpu.rounded()))%")
                    RingGauge(value: s.ramPercent, label: "Mémoire", text: "\(Int(s.ramPercent.rounded()))%", warn: 85, crit: 95)
                    RingGauge(value: s.diskPercent, label: "Stockage", text: "\(Int(s.diskPercent.rounded()))%", warn: 85, crit: 95)
                }
                Text(String(format: "Mémoire %.1f / %.1f Go · Stockage %.0f / %.0f Go", s.ramUsedGB, s.ramTotalGB,
                            s.diskUsedGB, s.diskTotalGB))
                    .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                Text("HISTORIQUE PROCESSEUR").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Theme.muted)
                Sparkline(values: s.history)
            }
            HealthPanel(score: s.health.score, grade: s.health.grade, advice: s.health.advice,
                        extra: "Chaleur : \(s.thermalLabel)")
            Panel(title: "Réseau") {
                NetGrid(up: s.upKBs, down: s.downKBs, sentGB: s.sentGB, recvGB: s.recvGB)
                Button("Diagnostic réseau") { Task { await model.send("Mon réseau") } }
                    .buttonStyle(HUDButtonStyle(filled: false))
            }
            #if os(macOS)
            MacProcessesPanel()
            #endif
        } else {
            Text("Mesure en cours…").foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private var pcView: some View {
        SystemPanel()
        if let h = model.stats?.health {
            HealthPanel(score: h.score, grade: h.grade, advice: h.advice, extra: nil)
        }
        if let n = model.stats?.net {
            Panel(title: "Réseau du PC") {
                NetGrid(up: n.up_kbs ?? 0, down: n.down_kbs ?? 0, sentGB: (n.sent_mb ?? 0) / 1024,
                        recvGB: (n.recv_mb ?? 0) / 1024)
            }
        }
    }

    private func uptime(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60
        return "allumé depuis \(h) h \(String(format: "%02d", m))"
    }
}

struct HealthPanel: View {
    let score: Int
    let grade: String
    let advice: String
    let extra: String?

    var body: some View {
        Panel(title: "Santé") {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Theme.cyan.opacity(0.1), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: CGFloat(score) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: color, radius: 6)
                    VStack(spacing: 0) {
                        Text("\(score)").font(Theme.display(34)).foregroundStyle(.white)
                        Text(grade).font(Theme.display(15)).foregroundStyle(color)
                    }
                }
                .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 6) {
                    Text(advice).font(.system(size: 15)).foregroundStyle(Theme.text)
                    if let extra { Text(extra).font(.system(size: 13)).foregroundStyle(Theme.muted) }
                }
            }
        }
    }

    private var color: Color { score >= 75 ? Theme.cyan : score >= 50 ? Theme.amber : Theme.red }
}

struct NetGrid: View {
    let up: Double
    let down: Double
    let sentGB: Double
    let recvGB: Double

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            cell("Envoi", rate(up))
            cell("Réception", rate(down))
            cell("Total envoyé", String(format: "%.2f Go", sentGB))
            cell("Total reçu", String(format: "%.2f Go", recvGB))
        }
    }

    private func rate(_ kbs: Double) -> String {
        kbs >= 1024 ? String(format: "%.1f Mo/s", kbs / 1024) : String(format: "%.0f Ko/s", kbs)
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(value).font(Theme.mono(15, weight: .semibold)).foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.cyan.opacity(0.07))
    }
}

// MARK: - Boost

struct BoostCategory: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.isConnected {
                    Panel(title: "Profil d'alimentation du PC") {
                        LazyVGrid(columns: cardColumns, spacing: 10) {
                            ActionCard(title: "⚡ Performance", subtitle: "Puissance maximale") { send("Mets mon PC en mode performance") }
                            ActionCard(title: "⚖️ Équilibré", subtitle: "Le réglage du quotidien") { send("Mets mon PC en mode équilibré") }
                            ActionCard(title: "🍃 Économie", subtitle: "Moins de bruit et de chaleur") { send("Mets mon PC en mode économie") }
                        }
                    }
                    Panel(title: "Modes") {
                        LazyVGrid(columns: cardColumns, spacing: 10) {
                            ActionCard(title: "🎮 Mode gaming", subtitle: "Performance + Discord + Steam") { Task { await model.runRoutine("mode gaming") } }
                            ActionCard(title: "💼 Mode travail", subtitle: "Ouvre tes outils") { Task { await model.runRoutine("mode travail") } }
                            ActionCard(title: "🔍 Analyse express", subtitle: "Conseils pour accélérer") { send("Optimise mon PC") }
                        }
                    }
                    Panel(title: "Libérer des ressources") {
                        if let top = model.stats?.top, !top.isEmpty {
                            ForEach(top.prefix(8)) { p in
                                HStack {
                                    Text(p.name).lineLimit(1).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(String(format: "%.1f %%", p.cpu)).font(Theme.mono(12)).foregroundStyle(Theme.cyanSoft)
                                    Text("\(Int(p.mem_mb)) Mo").font(Theme.mono(12)).foregroundStyle(Theme.cyanSoft)
                                        .frame(width: 70, alignment: .trailing)
                                    Button("Fermer") { send("ferme " + p.name.replacingOccurrences(of: ".exe", with: "")) }
                                        .buttonStyle(HUDButtonStyle(filled: false, tint: Theme.amber))
                                }
                            }
                            Text("La fermeture demande toujours confirmation.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        } else {
                            Text("En attente des mesures…").foregroundStyle(Theme.muted)
                        }
                    }
                } else {
                    #if os(macOS)
                    Panel(title: "Énergie du Mac") {
                        LazyVGrid(columns: cardColumns, spacing: 10) {
                            ActionCard(title: "⚡ Performance", subtitle: "Désactive l'économie d'énergie") { send("Mode performance") }
                            ActionCard(title: "🍃 Économie", subtitle: "Mode économie d'énergie") { send("Mode économie") }
                        }
                        Text("macOS demande votre mot de passe pour changer ce réglage.")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Panel(title: "Modes") {
                        LazyVGrid(columns: cardColumns, spacing: 10) {
                            ActionCard(title: "🎮 Mode gaming", subtitle: "Discord + Steam, son à 70 %") { send("Mode gaming") }
                            ActionCard(title: "💼 Mode travail", subtitle: "Mail, Calendrier, Notes") { send("Mode travail") }
                            ActionCard(title: "🎧 Concentration", subtitle: "Ferme les messageries") { send("Mode concentration") }
                            ActionCard(title: "🔍 Analyse express", subtitle: "Conseils pour accélérer") { send("Optimise mon Mac") }
                        }
                    }
                    MacProcessesPanel(title: "Libérer des ressources")
                    #else
                    Panel(title: "Boost") { NeedsPC(what: "Le boost (profils, modes, fermeture d'applis)") }
                    #endif
                }
                #if os(macOS)
                Panel(title: "Ce Mac") {
                    LazyVGrid(columns: cardColumns, spacing: 10) {
                        ActionCard(title: "📊 Moniteur d'activité", subtitle: "Voir ce qui consomme sur ce Mac") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                        }
                        ActionCard(title: "🔋 Batterie et énergie", subtitle: "Réglages d'énergie de macOS") {
                            openURL(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                        }
                    }
                }
                #endif
            }
            .padding(16)
        }
    }

    private func send(_ text: String) { Task { await model.send(text) } }
}

// MARK: - Nettoyage

struct CleanCategory: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @State private var fileTool: FileToolSheet.Kind?
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.isConnected {
                    Panel(title: "Nettoyage et entretien du PC") {
                        LazyVGrid(columns: cardColumns, spacing: 10) {
                            ActionCard(title: "🔍 Analyser", subtitle: "Bilan complet, ne supprime rien") { send("Optimise mon PC") }
                            ActionCard(title: "🧹 Fichiers temporaires", subtitle: "Ceux de plus de 24 h") { send("Nettoie les fichiers temporaires") }
                            ActionCard(title: "🗑️ Corbeille", subtitle: "Vider définitivement") { send("Vide la corbeille") }
                            ActionCard(title: "🌐 Cache DNS", subtitle: "Soucis de connexion") { send("Vide le cache DNS") }
                            ActionCard(title: "⬇️ Mises à jour", subtitle: "Windows Update") { send("Mises à jour") }
                            ActionCard(title: "🔄 Redémarrer", subtitle: "Dans une minute, annulable", warn: true) { send("Redémarre le PC") }
                        }
                        Text("Chaque action qui supprime ou redémarre demande confirmation.")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                } else {
                    #if os(macOS)
                    if model.screens > 1 { PCToolsPanel() }   // l'accueil est vidé : la gestion du Mac est ici
                    Panel(title: "Nettoyage et entretien du Mac") {
                        LazyVGrid(columns: cardColumns, spacing: 10) {
                            ActionCard(title: "🔍 Analyser", subtitle: "Bilan complet, ne supprime rien") { send("Optimise mon Mac") }
                            ActionCard(title: "🧹 Fichiers temporaires", subtitle: "Caches de plus de 24 h") { send("Nettoie les fichiers temporaires") }
                            ActionCard(title: "🗑️ Corbeille", subtitle: "Vider définitivement") { send("Vide la corbeille") }
                            ActionCard(title: "🌐 Cache DNS", subtitle: "Soucis de connexion") { send("Vide le cache DNS") }
                            ActionCard(title: "📶 Réseau", subtitle: "Tester la connexion") { send("Mon réseau") }
                            ActionCard(title: "🔄 Redémarrer", subtitle: "Avec confirmation", warn: true) { send("Redémarre le Mac") }
                        }
                        Text("NETTOYAGE AVANCÉ").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Theme.muted)
                        LazyVGrid(columns: cardColumns, spacing: 10) {
                            ActionCard(title: "🐘 Gros fichiers", subtitle: "Ce qui prend le plus de place") { fileTool = .big }
                            ActionCard(title: "👯 Doublons", subtitle: "Fichiers en double") { fileTool = .dupes }
                            ActionCard(title: "📁 Dossiers inutilisés", subtitle: "Dossiers vides") { fileTool = .empty }
                            ActionCard(title: "🗂️ Dossiers d'applis", subtitle: "Taille par application") { fileTool = .apps }
                        }
                        Text("Chaque action qui supprime ou redémarre demande confirmation.")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    #else
                    Panel(title: "Nettoyage") { NeedsPC(what: "Le nettoyage du PC") }
                    #endif
                }
                #if os(macOS)
                Panel(title: "Ce Mac") {
                    LazyVGrid(columns: cardColumns, spacing: 10) {
                        ActionCard(title: "💾 Stockage", subtitle: "Gestion du stockage de macOS") {
                            openURL(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                        }
                        ActionCard(title: "⬇️ Mises à jour", subtitle: "Mise à jour de macOS") {
                            openURL(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
                        }
                    }
                }
                #endif
            }
            .padding(16)
        }
        #if os(macOS)
        .sheet(item: $fileTool) { kind in FileToolSheet(kind: kind) }
        #endif
    }

    private func send(_ text: String) { Task { await model.send(text) } }
}

// MARK: - Maison

struct HomeCategory: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Panel(title: "Maison connectée") {
                    if let h = model.home, h.configured {
                        LazyVGrid(columns: cardColumns, spacing: 10) {
                            ActionCard(title: "💡 Tout allumer") { send("Allume toutes les lumières") }
                            ActionCard(title: "🌙 Tout éteindre") { send("Éteins toutes les lumières") }
                            ActionCard(title: "🏠 État de la maison") { send("Quelles lumières sont allumées ?") }
                        }
                        if let e = h.error { Text(e).foregroundStyle(Theme.amber) }
                        LazyVGrid(columns: cardColumns, spacing: 10) {
                            ForEach(h.devices) { d in
                                Button { Task { await model.toggleDevice(d.id) } } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(icon(d.domain)) \(d.name)").font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(Theme.text).lineLimit(1)
                                        Text(d.domain == "scene" ? "Activer" : d.isOn ? "Allumé" : "Éteint")
                                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(d.isOn ? Theme.cyan.opacity(0.16) : Color.black.opacity(0.25))
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .stroke(d.isOn ? Theme.cyan : Theme.cyan.opacity(0.2)))
                                    .shadow(color: d.isOn ? Theme.cyan.opacity(0.5) : .clear, radius: 8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else if model.home != nil {
                        Text(model.isConnected ? "Maison non configurée sur le PC : suivez l'étape « Maison » du tutoriel (Home Assistant)."
                             : "Maison non configurée : ⚙︎ Réglages › Maison connectée (adresse et jeton Home Assistant).")
                            .foregroundStyle(Theme.muted)
                        Button("Ouvrir les Réglages") { model.showSettings = true }.buttonStyle(HUDButtonStyle(filled: false))
                    } else {
                        Text("Chargement…").foregroundStyle(Theme.muted)
                    }
                    Text("À la voix : « Jarvis, allume la lumière du salon », « mets la chambre en bleu à 30 % », "
                         + "« ouvre les volets », « mets le chauffage à 21 ».")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            .padding(16)
        }
        .task { await model.refreshHome() }
    }

    private func icon(_ domain: String) -> String {
        ["light": "💡", "switch": "🔌", "cover": "🪟", "scene": "🎬"][domain] ?? "•"
    }

    private func send(_ text: String) {
        Task {
            await model.send(text)
            await model.refreshHome()
        }
    }
}

// MARK: - Organisation

struct OrganisationCategory: View {
    @EnvironmentObject var model: AppModel
    @State private var newItem = ""

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                Panel(title: "Liste de courses") {
                    if true {
                        HStack {
                            TextField("Ajouter un article…", text: $newItem)
                                .textFieldStyle(.plain).foregroundStyle(Theme.text).padding(8)
                                .background(Color.black.opacity(0.35))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.cyan.opacity(0.25)))
                                .onSubmit(addItem)
                            Button("+", action: addItem).buttonStyle(HUDButtonStyle(filled: false))
                        }
                        if model.shopping.isEmpty { Text("Liste vide.").foregroundStyle(Theme.muted) }
                        ForEach(model.shopping) { it in
                            HStack {
                                Button { Task { await model.removeShopping(it.id) } } label: {
                                    Image(systemName: "square").foregroundStyle(Theme.cyan)
                                }
                                .buttonStyle(.plain)
                                Text(it.item).foregroundStyle(Theme.text)
                            }
                        }
                    }
                }
                Panel(title: "Minuteurs et rappels") {
                    if true {
                        HStack {
                            ForEach([5, 10, 30], id: \.self) { m in
                                Button("⏱ \(m) min") { Task { await model.send("Mets un minuteur de \(m) minutes"); await model.refreshOrganisation() } }
                                    .buttonStyle(HUDButtonStyle(filled: false))
                            }
                        }
                        if model.timers.isEmpty { Text("Aucun minuteur en cours.").foregroundStyle(Theme.muted) }
                        ForEach(model.timers) { t in
                            Text("\(t.kind)\(t.label.isEmpty ? "" : " · " + t.label) — \(Int(t.remaining) / 60) min \(String(format: "%02d", Int(t.remaining) % 60))")
                                .foregroundStyle(Theme.text)
                        }
                    }
                    Text("À la voix : « rappelle-moi dans 20 minutes de… », « réveille-moi à 7 h ».")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                TodayPanel()
                MailPanel()
            }
            .padding(16)
        }
        .task {
            await model.refreshOrganisation()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await model.refreshOrganisation()
            }
        }
    }

    private func addItem() {
        let v = newItem
        newItem = ""
        Task { await model.addShopping(v) }
    }
}

// MARK: - Routines

struct RoutinesCategory: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                RoutinesPanel()
                Text("Dites le nom d'une routine (« bonne nuit », « mode travail »…) ou touchez « Lancer ». "
                     + "Relié au PC : ce sont les routines du PC (config/routines.yaml).")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .padding(16)
        }
    }
}

#if os(macOS)
/// Applications les plus gourmandes de ce Mac, avec fermeture (confirmation demandée).
struct MacProcessesPanel: View {
    @EnvironmentObject var model: AppModel
    let title: String
    @State private var procs: [ProcInfo] = []

    init(title: String = "Applications les plus gourmandes") { self.title = title }

    var body: some View {
        Panel(title: title) {
            if procs.isEmpty { Text("Mesure en cours…").foregroundStyle(Theme.muted) }
            ForEach(procs) { p in
                HStack {
                    Text(p.name + ((p.count ?? 1) > 1 ? " ×\(p.count ?? 1)" : "")).lineLimit(1).foregroundStyle(Theme.text)
                    Spacer()
                    Text(String(format: "%.1f %%", p.cpu)).font(Theme.mono(12)).foregroundStyle(Theme.cyanSoft)
                    Text("\(Int(p.mem_mb)) Mo").font(Theme.mono(12)).foregroundStyle(Theme.cyanSoft)
                        .frame(width: 70, alignment: .trailing)
                    Button("Fermer") { Task { await model.send("ferme " + p.name) } }
                        .buttonStyle(HUDButtonStyle(filled: false, tint: Theme.amber))
                }
            }
            Text("La fermeture demande toujours confirmation.").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .task {
            while !Task.isCancelled {
                procs = await LocalCommands.topProcesses(limit: 8)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }
}
#endif

// MARK: - Contenu d'une catégorie (fenêtre principale ou écran supplémentaire)

struct CategoryContent: View {
    @EnvironmentObject var model: AppModel
    let tab: AppTab

    var body: some View {
        switch tab {
        case .accueil: OrganisationCategory()
        case .globe: GlobeCategory(globe: model.globe)
        case .systeme: SystemCategory()
        case .boost: BoostCategory()
        case .nettoyage: CleanCategory()
        case .maison: HomeCategory()
        case .organisation: OrganisationCategory()
        case .routines: RoutinesCategory()
        }
    }
}

/// Fenêtre d'un écran supplémentaire : ses catégories, avec leur propre barre d'onglets.
struct ScreenCategoriesView: View {
    @EnvironmentObject var model: AppModel
    let tabs: [AppTab]
    let index: Int
    @State private var selected: AppTab

    init(tabs: [AppTab], index: Int) {
        self.tabs = tabs
        self.index = index
        _selected = State(initialValue: tabs.first ?? .systeme)
    }

    var body: some View {
        ZStack {
            BackgroundView()
            VStack(spacing: 0) {
                HStack {
                    Text("J.A.R.V.I.S").font(.system(size: 16, weight: .bold, design: .rounded)).tracking(5)
                        .foregroundStyle(Theme.cyan)
                    Text("· écran \(index)").foregroundStyle(Theme.muted)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.top, 14)
                if tabs.count > 1 { CategoryBar(tabs: tabs, selection: $selected) }
                CategoryContent(tab: selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.cyan)
    }
}

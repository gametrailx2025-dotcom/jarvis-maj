import Combine
import CoreLocation
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum ConnectionStatus: Equatable {
    case notConfigured, connecting, connected, failed(String)

    var label: String {
        switch self {
        case .notConfigured: return "PC non configuré"
        case .connecting: return "Connexion…"
        case .connected: return "PC connecté"
        case .failed: return "PC injoignable"
        }
    }
}

enum CoreMode { case idle, listening, thinking, speaking }

/// État central de l'app : conversation, connexion au cerveau JARVIS du PC, voix, météo.
@MainActor
final class AppModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var remoteState = RemoteState()
    @Published var stats: SystemStats?
    @Published var connection: ConnectionStatus = .notConfigured
    @Published var weather: WeatherInfo?
    @Published var weatherError: String?
    @Published var agenda: AgendaInfo?
    @Published var mail: MailInfo?
    /// Change quand la couleur de JARVIS change : force le redessin de toute l'interface.
    @Published var accentHex: String = UserDefaults.standard.string(forKey: SettingsKey.accentHex) ?? Theme.defaultAccent
    @Published var routines: [RoutineInfo] = []
    @Published var isThinking = false
    @Published var showSettings = false

    let speech = SpeechRecognizer()
    let speaker = Speaker()
    let ai = AIService()
    let location = LocationService()
    let cloud = SupabaseService()
    let accounts = AccountStore()
    /// Tâches, rendez-vous, courses et routines enregistrés sur cet appareil (quand le PC n'est pas relié).
    let hub = LocalHub()
    let local = LocalSystemMonitor()
    /// Module Globe (vue 3D God's Eye View) — Mac.
    let globe = GlobeServer()
    @Published var showSetup = false
    @Published var tab: AppTab = .accueil
    /// Nombre d'écrans : JARVIS reste sur l'écran principal, les catégories partent sur les autres (Mac).
    @Published var screens: Int = max(1, min(4, UserDefaults.standard.integer(forKey: "screensCount")))

    static let movableTabs: [AppTab] = AppTab.allCases.filter { $0 != .accueil }

    /// Onglets de chaque écran supplémentaire.
    var screenGroups: [[AppTab]] {
        #if os(macOS)
        guard screens > 1 else { return [] }
        let extra = screens - 1
        let size = Int((Double(Self.movableTabs.count) / Double(extra)).rounded(.up))
        return (0..<extra).map { i in Array(Self.movableTabs.dropFirst(i * size).prefix(size)) }.filter { !$0.isEmpty }
        #else
        return []
        #endif
    }

    var mainTabs: [AppTab] { screenGroups.isEmpty ? AppTab.allCases : [.accueil] }

    func setScreens(_ n: Int) {
        screens = max(1, min(4, n))
        UserDefaults.standard.set(screens, forKey: "screensCount")
        if !mainTabs.contains(tab) { tab = .accueil }
        #if os(macOS)
        MultiScreen.shared.apply(model: self)
        #endif
    }
    @Published var home: HomeInfo?
    @Published var shopping: [ShoppingItem] = []
    @Published var timers: [TimerInfo] = []
    /// Minuteurs et rappels gérés par l'app (sans PC).
    @Published var localTimers: [LocalTimer] = []
    /// Action locale en attente de confirmation (Mac : fermer une appli, veille…).
    @Published var localPending: LocalPending?
    /// Contenu affiché en grand (site, image, fichier, globe) — JARVIS passe alors dans un coin.
    @Published var stage: StageContent?
    @Published var stageCorner: StageCorner = StageCorner(rawValue: UserDefaults.standard.string(forKey: "stageCorner") ?? "")
        ?? .topTrailing {
        didSet { UserDefaults.standard.set(stageCorner.rawValue, forKey: "stageCorner") }
    }
    /// Derniers fichiers trouvés ou listés (pour « ouvre le 2 », « résume le 1 »).
    @Published var lastFiles: [URL] = []
    private var summaryRequested = false
    private var wasSpeaking = false

    private var pollTask: Task<Void, Never>?
    private var lastSeq = 0
    private var lastDashboard = Date.distantPast
    private var started = false
    private var bag = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard

    init() {
        speech.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        speaker.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        location.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        cloud.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        accounts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        local.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        ai.cloud = cloud
        // Suspend l'écoute pendant que JARVIS parle (sinon il s'entendrait lui-même).
        speaker.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let speaking = self.speaker.isSpeaking
                if speaking != self.wasSpeaking {
                    self.wasSpeaking = speaking
                    self.speech.setPaused(speaking)
                }
            }
        }.store(in: &bag)
        speech.onFinal = { [weak self] text in
            Task { await self?.send(text) }
        }
        speech.onWake = { [weak self] in
            guard let self else { return }
            guard self.accounts.isSignedIn else { return }
            #if os(macOS)
            // Dans une autre appli : le mini-JARVIS apparaît dans un coin de l'écran
            if MacShell.userIsElsewhere { OverlayController.shared.show(model: self) }
            #endif
            self.speaker.say("Oui, \(self.userName) ?")
        }
        // Lui couper la parole : « Jarvis », « stop », « tais-toi »… pendant qu'il parle
        speech.onBargeIn = { [weak self] in
            self?.speaker.stop()
        }
    }

    var wakeWordEnabled: Bool { defaults.object(forKey: SettingsKey.wakeWord) as? Bool ?? true }

    /// Active ou coupe l'écoute permanente du mot « Jarvis ».
    func applyWakeWord() async {
        if wakeWordEnabled {
            guard await speech.requestAuthorization() else {
                post(jarvis: "Pour m'activer en disant « Jarvis », autorisez le micro et la reconnaissance vocale.", speak: false)
                return
            }
            speech.setWakeMode(true)
        } else {
            speech.setWakeMode(false)
        }
    }

    func setAccent(_ hex: String) {
        defaults.set(hex, forKey: SettingsKey.accentHex)
        accentHex = hex
        Task { await cloud.push(["color": hex]) }
    }

    /// Récupère les réglages du compte et les applique (nom, ville, couleur, localisation…).
    func syncProfile() async {
        guard cloud.isSignedIn else { return }
        guard let p = try? await cloud.pull() else { return }
        if let name = p["name"] as? String, !name.isEmpty { defaults.set(name, forKey: SettingsKey.userName) }
        if let city = p["city"] as? String, !city.isEmpty { defaults.set(city, forKey: SettingsKey.city) }
        if let color = p["color"] as? String, Color(hex: color) != nil {
            defaults.set(color, forKey: SettingsKey.accentHex)
            accentHex = color
        }
        if let consent = p["location_consent"] as? Bool, consent == false {
            defaults.set(false, forKey: SettingsKey.useLocation)  // déjà refusé ailleurs : on ne redemande pas
        }
        var missing: [String: Any] = [:]
        if p["name"] == nil { missing["name"] = userName }
        if p["color"] == nil { missing["color"] = accentHex }
        if !missing.isEmpty { await cloud.push(missing) }
    }

    // MARK: - Propriétés dérivées

    var coreMode: CoreMode {
        if speech.isCapturing || (speech.isRunning && !speech.wakeMode) { return .listening }
        if speaker.isSpeaking { return .speaking }
        if isThinking || remoteState.busy == true { return .thinking }
        return .idle
    }

    /// Texte de la confirmation affichée (action locale ou action du PC).
    var pendingLabel: String? { localPending?.label ?? remoteState.pending }

    func show(_ content: StageContent) {
        stage = content
        if content == .globe { Task { await globe.start() } }
    }

    func closeStage() {
        stage = nil
    }

    /// Balises que l'IA peut ajouter à sa réponse pour afficher quelque chose : [[web:URL]], [[image:sujet]], [[globe]].
    func applyStageTags(_ text: String) async -> String {
        guard let rx = try? NSRegularExpression(pattern: #"\[\[\s*(web|image|globe)\s*(?::\s*([^\]]+?))?\s*\]\]"#,
                                                options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        let matches = rx.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        for m in matches {
            let kind = ns.substring(with: m.range(at: 1)).lowercased()
            let arg = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            switch kind {
            case "web":
                if let url = URL(string: arg.trimmingCharacters(in: .whitespaces)),
                   let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
                    show(.web(url))
                }
            case "image":
                await DeviceCommands.showImage(arg, model: self)
            default:
                show(.globe)
            }
        }
        return rx.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setUserName(_ name: String) {
        defaults.set(name, forKey: SettingsKey.userName)
        objectWillChange.send()
        Task { await cloud.push(["name": name]) }
    }

    func startTimer(seconds: Int, label: String, reminder: Bool) {
        let timer = LocalTimer(label: label, end: Date().addingTimeInterval(TimeInterval(seconds)), isReminder: reminder)
        localTimers.append(timer)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
            guard let self, self.localTimers.contains(where: { $0.id == timer.id }) else { return }
            self.localTimers.removeAll { $0.id == timer.id }
            let text = reminder ? "⏰ Rappel : \(label)."
                : "⏰ Le minuteur" + (label.isEmpty ? "" : " « \(label) »") + " est terminé."
            self.post(jarvis: text, speak: true)
        }
    }

    var userName: String {
        let n = (defaults.string(forKey: SettingsKey.userName) ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Monsieur" : n
    }

    var city: String {
        let c = (defaults.string(forKey: SettingsKey.city) ?? "").trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? "Paris" : c
    }

    var voiceEnabled: Bool { defaults.object(forKey: SettingsKey.voiceEnabled) as? Bool ?? true }

    var useLocation: Bool { defaults.object(forKey: SettingsKey.useLocation) as? Bool ?? true }

    /// Vrai quand la météo affichée vient de la position de l'appareil.
    @Published var weatherFromLocation = false

    var client: JarvisClient? {
        JarvisClient.make(urlString: defaults.string(forKey: SettingsKey.pcURL) ?? "",
                          token: Keychain.get(Keychain.pcToken) ?? "")
    }

    var isConnected: Bool { connection == .connected }

    // MARK: - Cycle de vie

    func start() {
        guard !started else { return }
        guard accounts.isSignedIn else { return }   // rien ne démarre avant la connexion
        started = true
        WakeMusic.shared.play()          // Highway to Hell pendant le démarrage et le récap
        post(jarvis: "\(greetingWord()) \(userName). Systèmes en ligne. Dites « Jarvis » ou écrivez-moi.", speak: false)
        #if os(macOS)
        MacShell.configureAtStart(model: self)
        if screens > 1 { MultiScreen.shared.apply(model: self) }
        #endif
        local.start()
        connect()
        Task {
            await syncProfile()
            await applyWakeWord()   // demande micro + reconnaissance vocale dès le premier lancement
            // Guide de configuration : seulement s'il manque l'essentiel (rien à régler sinon).
            if !missingSetup(requiredOnly: true).isEmpty {
                showSetup = true
            }
            await refreshWeather()
            // Sans PC : résumé de l'appareil + rappel de configuration (avec le PC, c'est le PC qui fait le point).
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if connection != .connected { post(jarvis: localSummary(), speak: true) }
        }
        // Sans PC : mails importants et maison suivis par l'appareil lui-même
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard let self, !self.isConnected else { continue }
                await self.refreshLocalMail(force: false)
            }
        }
        if HomeAssistant.isConfigured || TuyaCloud.isConfigured { Task { await refreshHome() } }
    }

    func connect() {
        pollTask?.cancel()
        guard let client else {
            connection = .notConfigured
            stats = nil
            Task { if await SyncCloud.importIfUseful(into: hub) { loadLocal() } }
            loadLocal()
            Task { await refreshLocalMail(force: false) }
            return
        }
        connection = .connecting
        lastDashboard = .distantPast
        pollTask = Task { [weak self] in await self?.pollLoop(client) }
    }

    private func pollLoop(_ client: JarvisClient) async {
        var first = true
        while !Task.isCancelled {
            do {
                let r: StateResponse = try await client.get("/api/state?since=\(lastSeq)")
                remoteState = r.state
                stats = r.stats
                if !first { (r.events ?? []).forEach(handle(event:)) }  // pas de rejeu de l'historique
                lastSeq = r.seq ?? lastSeq
                first = false
                connection = .connected
                if !SyncCloud.isConfigured { Task { await SyncCloud.fetchInfo(from: client) } }
                if Date().timeIntervalSince(lastDashboard) > 600 { await refreshDashboard() }
                if !summaryRequested {
                    summaryRequested = true
                    Task { await requestPCSummary() }
                }
            } catch {
                if Task.isCancelled { return }
                connection = .failed(error.localizedDescription)
            }
            let delay: UInt64 = connection == .connected ? 1_500_000_000 : 5_000_000_000
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func handle(event e: RemoteEvent) {
        if e.topic == "jarvis_said", let t = e.text {
            post(jarvis: t, speak: false, time: e.time)
        } else if e.topic == "notification", let m = e.message, !m.isEmpty {
            post(jarvis: "🔔 " + (e.title.map { "\($0) : " } ?? "") + m, speak: false)
        }
    }

    func refreshDashboard() async {
        guard let client, isConnected else {
            loadLocal()
            await refreshLocalMail(force: false)
            return
        }
        lastDashboard = Date()
        if let d: DashboardResponse = try? await client.get("/api/dashboard", timeout: 40) {
            agenda = d.agenda
            mail = d.mail
        }
        if let r: RoutinesResponse = try? await client.get("/api/routines") {
            routines = r.routines
        }
    }

    func refreshWeather() async {
        do {
            if useLocation, let loc = await location.currentLocation() {
                let name = await LocationService.cityName(for: loc) ?? "Votre position"
                weather = try await WeatherService.fetch(latitude: loc.coordinate.latitude,
                                                         longitude: loc.coordinate.longitude, name: name)
                weatherFromLocation = true
                if cloud.profile["location_consent"] as? Bool != true {
                    await cloud.push(["location_consent": true])
                }
            } else {
                if useLocation && location.isDenied && cloud.profile["location_consent"] as? Bool != false {
                    await cloud.push(["location_consent": false])
                }
                weather = try await WeatherService.fetch(city: city)
                weatherFromLocation = false
            }
            weatherError = nil
        } catch {
            weatherError = "Météo indisponible : \(error.localizedDescription)"
        }
    }

    // MARK: - Conversation

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard accounts.isSignedIn else {   // pas de compte, pas de JARVIS
            #if os(macOS)
            MacShell.showMainWindow()
            #endif
            return
        }
        speaker.stop()
        // Réponse vocale à une action locale en attente (« oui » / « annule »)
        if let p = localPending {
            let n = LocalBrain.normalize(text)
            let yes = ["oui", "ouais", "confirme", "je confirme", "vas y", "ok", "d'accord", "fais le", "valide"]
            let no = ["non", "annule", "annuler", "laisse tomber", "stop", "non merci"]
            if Date().timeIntervalSince(p.created) > 45 {
                localPending = nil
            } else if yes.contains(n) || no.contains(n) {
                messages.append(ChatMessage(fromUser: true, text: text, time: Self.clock()))
                localPending = nil
                post(jarvis: yes.contains(n) ? p.run() : "Entendu, j'annule.", speak: true)
                return
            }
        }
        messages.append(ChatMessage(fromUser: true, text: text, time: Self.clock()))
        isThinking = true
        defer { isThinking = false }
        #if os(macOS)
        if MacShell.userIsElsewhere { OverlayController.shared.show(model: self) }
        #endif
        // Globe et fichiers : toujours sur cet appareil, même relié au PC
        if let r = await DeviceCommands.localFirst(LocalBrain.normalize(text), raw: text, model: self) {
            post(jarvis: r, speak: true)
            return
        }

        var reply: String
        if let client, connection != .notConfigured {
            do {
                let r: CommandResponse = try await client.post("/api/command", body: ["text": text], timeout: 150)
                if let s = r.state { remoteState = s }
                reply = r.reply
            } catch {
                connection = .failed(error.localizedDescription)
                reply = await LocalBrain(model: self).handle(text, pcError: error.localizedDescription)
            }
        } else {
            reply = await LocalBrain(model: self).handle(text, pcError: nil)
        }
        reply = await applyStageTags(reply)
        if reply.isEmpty { reply = "C'est fait." }
        post(jarvis: reply, speak: true)
    }

    func answerConfirmation(_ yes: Bool) async {
        if let p = localPending {
            localPending = nil
            messages.append(ChatMessage(fromUser: true, text: yes ? "Je confirme." : "Annule.", time: Self.clock()))
            post(jarvis: yes ? p.run() : "Entendu, j'annule.", speak: true)
            return
        }
        guard let client else { return }
        messages.append(ChatMessage(fromUser: true, text: yes ? "Je confirme." : "Annule.", time: Self.clock()))
        do {
            let r: CommandResponse = try await client.post(yes ? "/api/confirm" : "/api/cancel", body: [:])
            if let s = r.state { remoteState = s }
            post(jarvis: r.reply, speak: true)
        } catch {
            post(jarvis: "Connexion au PC perdue : \(error.localizedDescription)", speak: false)
        }
    }

    // MARK: - Résumé et guide de configuration

    /// Ce qui manque encore (rappelé à chaque ouverture).
    func missingSetup(requiredOnly: Bool = false) -> [String] {
        var out: [String] = []

        if !ai.isConfigured && ai.provider != .jarvis { out.append("intelligence artificielle") }
        if !speech.isAuthorized { out.append("micro et reconnaissance vocale") }
        if !requiredOnly {
            if connection == .notConfigured { out.append("connexion au PC") }
            if useLocation && location.status == .notDetermined { out.append("localisation") }
        }
        return out
    }

    func localSummary() -> String {
        var parts = ["\(greetingWord()) \(userName)."]
        if let s = local.stats {
            let h = s.health
            parts.append("\(local.deviceName.prefix(1).uppercased() + local.deviceName.dropFirst()) : santé \(h.score) sur 100, "
                         + "processeur à \(Int(s.cpu.rounded())) %, mémoire à \(Int(s.ramPercent.rounded())) %.")
            if h.score < 75 { parts.append(h.advice) }
        }
        let missing = missingSetup(requiredOnly: true)
        if !missing.isEmpty {
            parts.append("Il reste à configurer : " + missing.joined(separator: ", ") + ". Ouvrez le guide dans les Réglages.")
        }
        return parts.joined(separator: " ")
    }

    func requestPCSummary() async {
        guard let client else { return }
        if let r: CommandResponse = try? await client.post("/api/command", body: ["text": "fais le point"], timeout: 60) {
            post(jarvis: r.reply, speak: true)
        }
    }

    // MARK: - Catégories (données du PC)

    func refreshHome() async {
        guard let client, isConnected else {
            if HomeAssistant.isConfigured {
                home = await HomeAssistant.load()
            } else {
                home = await TuyaCloud.load()
            }
            return
        }
        if let h: HomeInfo = try? await client.get("/api/home", timeout: 20) { home = h }
    }

    func toggleDevice(_ id: String) async {
        guard let client, isConnected else {
            if let d = home?.devices.first(where: { $0.id == id }) {
                let msg: String
                if HomeAssistant.isConfigured {
                    msg = await HomeAssistant.toggle(d)
                } else {
                    msg = await TuyaCloud.toggle(d)
                }
                post(jarvis: msg, speak: false)
                try? await Task.sleep(nanoseconds: 800_000_000)
                await refreshHome()
            }
            return
        }
        if let h: HomeInfo = try? await client.post("/api/home/toggle", body: ["id": id]) {
            home = h
            if let m = h.message { post(jarvis: m, speak: false) }
        }
    }

    func refreshOrganisation() async {
        guard let client, isConnected else { loadLocal(); return }
        if let r: ShoppingResponse = try? await client.get("/api/shopping") { shopping = r.items }
        if let r: TimersResponse = try? await client.get("/api/timers") { timers = r.timers }
        if let a: AgendaInfo = try? await client.get("/api/agenda") { agenda = a }
    }

    func addShopping(_ item: String) async {
        guard !item.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let client, isConnected else { hub.addShopping(item); loadLocal(); return }
        if let r: ShoppingResponse = try? await client.post("/api/shopping/add", body: ["item": item]) { shopping = r.items }
    }

    func removeShopping(_ id: Int) async {
        guard let client, isConnected else { hub.removeShopping(id); loadLocal(); return }
        if let r: ShoppingResponse = try? await client.post("/api/shopping/remove", body: ["id": id]) { shopping = r.items }
    }

    func refreshMail() async {
        guard let client, isConnected else { await refreshLocalMail(force: true); return }
        if let m: MailInfo = try? await client.get("/api/mail?force=1", timeout: 40) { mail = m }
    }

    func toggleListening() async {
        if speech.isCapturing || (speech.isRunning && !speech.wakeMode) {
            speech.stop(commit: true)
            return
        }
        speaker.stop()
        guard await speech.requestAuthorization() else {
            post(jarvis: "J'ai besoin de l'accès au micro et à la reconnaissance vocale. Autorisez-les dans les réglages du système.", speak: false)
            return
        }
        do {
            try speech.listenOnce()
        } catch {
            post(jarvis: "Micro indisponible : \(error.localizedDescription)", speak: false)
        }
    }

    func post(jarvis text: String, speak: Bool, time: String? = nil) {
        messages.append(ChatMessage(fromUser: false, text: text, time: time ?? Self.clock()))
        if messages.count > 200 { messages.removeFirst(messages.count - 200) }
        if speak && voiceEnabled {
            speech.speakingText = text
            speaker.say(text)
        }
    }

    // MARK: - Tâches et routines (sur le PC)

    func addTask(_ title: String) async {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let client, isConnected else { hub.addTask(title); loadLocal(); return }
        if let r: AgendaWrapper = try? await client.post("/api/tasks/add", body: ["title": title]) { agenda = r.agenda }
    }

    func addEvent(_ title: String, start: Date) async {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        guard let client, isConnected else { hub.addEvent(t, start: start); loadLocal(); return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let r: AgendaWrapper = try? await client.post("/api/events/add", body: ["title": t, "start": f.string(from: start)]) {
            agenda = r.agenda
        }
    }

    func completeTask(_ id: Int) async {
        guard let client, isConnected else { hub.completeTask(id); loadLocal(); return }
        if let r: AgendaWrapper = try? await client.post("/api/tasks/complete", body: ["id": id]) { agenda = r.agenda }
    }

    func toggleRoutine(_ name: String, enabled: Bool) async {
        guard let client, isConnected else { hub.setRoutine(name, enabled: enabled); loadLocal(); return }
        if let r: RoutinesResponse = try? await client.post("/api/routines/toggle", body: ["name": name, "enabled": enabled]) {
            routines = r.routines
        }
    }

    func runRoutine(_ name: String) async {
        guard let client, isConnected else {
            await send(name == "briefing du matin" ? "briefing" : name)
            return
        }
        messages.append(ChatMessage(fromUser: true, text: "Routine « \(name) »", time: Self.clock()))
        do {
            let r: CommandResponse = try await client.post("/api/routines/run", body: ["name": name], timeout: 90)
            if let s = r.state { remoteState = s }
            post(jarvis: r.reply, speak: true)
        } catch {
            post(jarvis: "Impossible de lancer la routine : \(error.localizedDescription)", speak: false)
        }
    }

    // MARK: - Données locales (sans PC)

    func loadLocal() {
        agenda = hub.agenda
        shopping = hub.shopping
        routines = hub.routines
        timers = localTimers.enumerated().map { i, t in
            TimerInfo(id: i, kind: t.isReminder ? "Rappel" : "Minuteur", label: t.label,
                      remaining: max(0, t.end.timeIntervalSinceNow))
        }
    }

    /// Mails importants de l'app Mail du Mac (lecture seule). `force` ouvre Mail s'il est fermé.
    func refreshLocalMail(force: Bool) async {
        #if os(macOS)
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.mail" }
        guard running || force else {
            if mail == nil {
                mail = MailInfo(configured: true, items: [],
                                error: "Ouvrez l'app Mail (ou touchez Actualiser) pour que je surveille vos mails importants.")
            }
            return
        }
        guard let list = await DeviceCommands.fetchAppleMail() else {
            mail = MailInfo(configured: false, items: [], error: nil)
            return
        }
        let now = Date().timeIntervalSince1970
        let items: [MailItem] = list.enumerated().compactMap { i, m in
            let why = LocalHub.importance(sender: m.sender, subject: m.subject, body: m.body)
            guard !why.isEmpty else { return nil }
            return MailItem(id: "\(i)-\(m.subject)", sender: m.sender, subject: m.subject,
                            snippet: String(m.body.prefix(160)), ts: now, why: why)
        }
        mail = MailInfo(configured: true, items: items, error: nil)
        #endif
    }

    // MARK: - Utilitaires

    static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    func greetingWord() -> String {
        let h = Calendar.current.component(.hour, from: Date())
        return (5..<18).contains(h) ? "Bonjour" : "Bonsoir"
    }
}

import SwiftUI

// MARK: - Formulaire de compte (réutilisé dans les Réglages et le guide de démarrage)

struct AccountForm: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let acc = model.accounts.current {
            LabeledContent(acc.name, value: acc.email)
            if acc.isAdmin {
                Text("👑 Administrateur : sur Discord, /comptes liste tous les comptes, /bloquer et /debloquer gèrent l'accès.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("Se déconnecter") { model.accounts.signOut() }
        }
    }
}

// MARK: - Couleur : palette du système + code couleur

struct ColorChooser: View {
    @EnvironmentObject var model: AppModel
    @State private var picked: Color = Theme.cyan
    @State private var hex: String = Theme.accentHex
    @State private var hexError = false

    var body: some View {
        // ColorPicker ouvre la palette native : panneau Couleurs de macOS, sélecteur d'iOS.
        ColorPicker("Palette du système", selection: $picked, supportsOpacity: false)
            .onChange(of: picked) { _, newValue in
                if let h = newValue.hexString, h != model.accentHex {
                    hex = h
                    model.setAccent(h)
                }
            }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Theme.presets, id: \.1) { preset in
                    Button { apply(preset.1) } label: {
                        Circle()
                            .fill(Color(hex: preset.1) ?? .cyan)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color.white.opacity(preset.1 == model.accentHex ? 1 : 0.4),
                                                     lineWidth: preset.1 == model.accentHex ? 3 : 1))
                            .shadow(color: Color(hex: preset.1) ?? .cyan, radius: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.0)
                }
            }
            .padding(.vertical, 4)
        }
        HStack {
            TextField("Code couleur, ex. #FF3B5C", text: $hex)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .font(Theme.mono(15))
                .onSubmit { apply(hex) }
            Circle().fill(Color(hex: hex) ?? .clear).frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.white.opacity(0.4)))
            Button("Appliquer") { apply(hex) }
        }
        if hexError {
            Text("Format attendu : #RRGGBB (ex. #FF3B5C).").font(.footnote).foregroundStyle(.red)
        }
    }

    private func apply(_ value: String) {
        var h = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !h.hasPrefix("#") { h = "#" + h }
        guard h.count == 7, Color(hex: h) != nil else {
            hexError = true
            return
        }
        hexError = false
        hex = h
        picked = Color(hex: h) ?? picked
        model.setAccent(h)
    }
}

// MARK: - Réglages

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.userName) private var userName = "Monsieur"
    @AppStorage(WakeMusic.enabledKey) private var wakeMusic = true
    @AppStorage(SettingsKey.city) private var city = "Paris"
    @AppStorage(SettingsKey.pcURL) private var pcURL = ""
    @AppStorage(SettingsKey.aiProvider) private var provider = AIService.Provider.jarvis.rawValue
    @AppStorage(SettingsKey.aiModel) private var aiModel = ""
    @AppStorage(SettingsKey.ollamaURL) private var ollamaURL = "http://localhost:11434"
    @AppStorage(SettingsKey.voiceEnabled) private var voiceEnabled = true
    @AppStorage(SettingsKey.useLocation) private var useLocation = true
    @AppStorage(SettingsKey.wakeWord) private var wakeWord = true
    @AppStorage(HomeAssistant.urlKey) private var haURL = ""
    @AppStorage(JarvisClient.deviceNameKey) private var deviceName = ""
    @State private var haToken = Keychain.get(HomeAssistant.tokenKey) ?? ""
    @AppStorage(TuyaCloud.idKey) private var tuyaID = ""
    @AppStorage(TuyaCloud.regionKey) private var tuyaRegion = "eu"
    @State private var tuyaSecret = Keychain.get(TuyaCloud.secretKey) ?? ""
    @State private var tuyaResult: String?

    @State private var token = Keychain.get(Keychain.pcToken) ?? ""
    @StateObject private var discovery = PCDiscovery()
    @State private var pairCode = ""
    @State private var pairing = false
    @State private var openrouterKey = Keychain.get(Keychain.openrouterKey) ?? ""
    @State private var anthropicKey = Keychain.get(Keychain.anthropicKey) ?? ""
    @State private var groqKey = Keychain.get(Keychain.groqKey) ?? ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AccountForm()
                } header: {
                    Text("Compte")
                }

                Section {
                    TextField("Votre nom", text: $userName)
                    Toggle("Utiliser ma position", isOn: $useLocation)
                    TextField(useLocation ? "Ville de secours (si position indisponible)" : "Ville", text: $city)
                    if useLocation && model.location.isDenied {
                        Text("Localisation refusée. Pour l'autoriser : Réglages du système › Confidentialité et "
                             + "sécurité › Service de localisation › JARVIS.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Vous")
                }

                Section {
                    ColorChooser()
                } header: {
                    Text("Couleur de JARVIS")
                }

                Section("Voix") {
                    VoicePicker()
                    Toggle("M'activer en disant « Jarvis »", isOn: $wakeWord)
                    Toggle("Réponses parlées", isOn: $voiceEnabled)
                    Toggle("Musique au démarrage (Highway to Hell)", isOn: $wakeMusic)
                    Text("Pour une voix plus naturelle : Réglages du système › Accessibilité › Contenu énoncé › Voix › "
                         + "Français, puis téléchargez une voix « améliorée » ou « premium ».")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                #if os(macOS)
                Section {
                    Button("Donner l'accès complet au disque…") { DeviceCommands.openFullDiskAccessSettings() }
                    Button("Autoriser JARVIS à voir l'écran…") { DeviceCommands.openScreenRecordingSettings() }
                    Button("Autoriser JARVIS à écrire à ma place…") { Typist.requestTrust(); Typist.openAccessibilitySettings() }
                    Toggle("Lancer JARVIS au démarrage du Mac (en arrière-plan)", isOn: Binding(
                        get: { LoginItem.isEnabled || LoginItem.needsApproval },
                        set: { LoginItem.set($0) }))
                    if LoginItem.needsApproval {
                        Button("Valider dans Réglages › Ouverture…") { LoginItem.openSettings() }
                    }
                    Text("Ajoutez JARVIS (bouton +, Applications › JARVIS) puis activez-le : JARVIS pourra lire tous vos "
                         + "fichiers quand vous le lui demandez. Les actions administrateur demandent votre mot de passe "
                         + "macOS à chaque fois ; JARVIS ne le voit ni ne le garde.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Oublier tout ce que JARVIS a retenu", role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: "memories")
                    }
                } header: {
                    Text("Accès au Mac et mémoire")
                }
                #endif

                Section("Intelligence artificielle") {
                    Label("Incluse — rien à configurer", systemImage: "sparkles")
                }
                if !AppConfig.hasBuiltInServer {
                    Section {
                        Picker("Fournisseur", selection: $provider) {
                            ForEach(AIService.Provider.allCases) { p in
                                Text(p.label).tag(p.rawValue)
                            }
                        }
                        if provider != AIService.Provider.jarvis.rawValue && provider != AIService.Provider.none.rawValue {
                            TextField("Modèle (vide = par défaut)", text: $aiModel)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        }
                        if provider == AIService.Provider.groq.rawValue {
                            SecureField("Clé Groq (gsk_…) — développement", text: $groqKey)
                        }
                        if provider == AIService.Provider.openrouter.rawValue {
                            SecureField("Clé OpenRouter (sk-or-…) — développement", text: $openrouterKey)
                        }
                        if provider == AIService.Provider.anthropic.rawValue {
                            SecureField("Clé Anthropic — développement", text: $anthropicKey)
                        }
                        if provider == AIService.Provider.ollama.rawValue {
                            TextField("Adresse d'Ollama — développement", text: $ollamaURL).autocorrectionDisabled()
                        }
                    } header: {
                        Text("Options développeur (facultatif — laissez « JARVIS »)")
                    } footer: {
                        Text("L'IA incluse fonctionne sans clé. Ces options ne servent qu'aux tests ; elles disparaissent "
                             + "quand AppConfig.swift est rempli.")
                    }
                }

                Section {
                    if discovery.found.isEmpty {
                        HStack {
                            if discovery.searching { ProgressView().controlSize(.small) }
                            Text(discovery.searching ? "Recherche des PC JARVIS sur le Wi-Fi…" : "Aucun PC détecté.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            Button("Chercher") { discovery.start() }
                        }
                    } else {
                        ForEach(discovery.found) { pc in
                            Button {
                                pcURL = pc.url
                            } label: {
                                Label(pc.name + (pcURL == pc.url ? "  ✓" : ""), systemImage: "desktopcomputer")
                            }
                        }
                    }
                    Button(pairing ? "En attente de l'accord du PC…" : "Relier avec mon compte JARVIS") {
                        Task { await loginWithAccount() }
                    }
                    .disabled(pairing || pcURL.isEmpty || model.accounts.current == nil)
                    HStack {
                        TextField("Code à 6 chiffres affiché sur le PC", text: $pairCode)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        Button(pairing ? "…" : "Relier") { Task { await pairWithCode() } }
                            .disabled(pairing || pcURL.isEmpty || pairCode.filter(\.isNumber).count != 6)
                    }
                    TextField("Adresse, ex. http://192.168.1.20:8765", text: $pcURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Jeton", text: $token)
                    TextField("Nom de cet appareil (pour les pièces), ex. iPhone d'Evan", text: $deviceName)
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Tester la connexion")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing)
                    if let testResult {
                        Text(testResult).font(.footnote)
                    }
                } header: {
                    Text("Piloter mon PC (facultatif)")
                } footer: {
                    Text("Choisissez le PC ci-dessus puis « Relier avec mon compte JARVIS » : le PC affiche « Nouvel appareil », "
                         + "acceptez-le. Le même compte (e-mail) doit exister sur le PC. Sinon : code à 6 chiffres (⚙︎ › Relier sur le PC).")
                }

                #if os(macOS)
                Section {
                    Stepper(value: Binding(get: { model.screens }, set: { model.setScreens($0) }), in: 1...4) {
                        Text("Nombre d'écrans : \(model.screens)")
                    }
                } header: {
                    Text("Écrans")
                } footer: {
                    Text(model.screens == 1 ? "Un seul écran : tout est dans la fenêtre JARVIS."
                         : "JARVIS reste sur l'écran principal ; les catégories s'ouvrent dans une fenêtre sur chacun des autres écrans.")
                }
                #endif

                Section {
                    TextField("Adresse, ex. http://homeassistant.local:8123", text: $haURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Jeton d'accès longue durée", text: $haToken)
                } header: {
                    Text("Maison connectée · Home Assistant (facultatif)")
                } footer: {
                    Text("Home Assistant › votre profil › Sécurité › Jetons d'accès longue durée › Créer. "
                         + "Ensuite : onglet Maison, ou « Jarvis, allume la lumière du salon ».")
                }

                Section {
                    TextField("Access ID (Client ID)", text: $tuyaID).autocorrectionDisabled()
                    SecureField("Access Secret (Client Secret)", text: $tuyaSecret)
                    Picker("Région", selection: $tuyaRegion) {
                        ForEach(TuyaCloud.regions) { r in Text(r.label).tag(r.id) }
                    }
                    Button("Enregistrer et tester") {
                        save()
                        Task { tuyaResult = await TuyaCloud.test(); await model.refreshHome() }
                    }
                    if let tuyaResult { Text(tuyaResult).font(.footnote) }
                } header: {
                    Text("Maison connectée · LSC Smart Connect / Tuya")
                } footer: {
                    Text("Projet gratuit sur platform.tuya.com (tutoriel, étape W). "
                         + "Ensuite : « Jarvis, allume la lampe du salon », « éteins tout ».")
                }

                Section {
                    Button("Revoir le guide de configuration") {
                        save()
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.showSetup = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Réglages")
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        save()
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 680)
        #endif
    }

    private func loginWithAccount() async {
        guard let email = model.accounts.current?.email else { return }
        pairing = true
        testResult = "Sur le PC, acceptez « \(JarvisClient.deviceName) » dans la fenêtre « Nouvel appareil »…"
        defer { pairing = false }
        do {
            token = try await PCDiscovery.login(url: pcURL, email: email, name: JarvisClient.deviceName)
            save()
            model.connect()
            testResult = "✅ Relié au PC avec votre compte."
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }

    private func pairWithCode() async {
        pairing = true
        defer { pairing = false }
        do {
            token = try await PCDiscovery.pair(url: pcURL, code: pairCode)
            pairCode = ""
            save()
            model.connect()
            testResult = "✅ PC relié."
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }

    private func save() {
        Keychain.set(token, for: Keychain.pcToken)
        Keychain.set(haToken, for: HomeAssistant.tokenKey)
        Keychain.set(tuyaSecret, for: TuyaCloud.secretKey)
        if HomeAssistant.isConfigured { Task { await model.refreshHome() } }
        Keychain.set(openrouterKey, for: Keychain.openrouterKey)
        Keychain.set(anthropicKey, for: Keychain.anthropicKey)
        Keychain.set(groqKey, for: Keychain.groqKey)
        model.ai.reset()
        if model.cloud.isSignedIn {
            Task { await model.cloud.push(["name": userName, "city": city, "location_consent": useLocation]) }
        }
    }

    private func testConnection() async {
        save()
        testing = true
        defer { testing = false }
        guard let client = JarvisClient.make(urlString: pcURL, token: token) else {
            testResult = "Renseignez l'adresse et le jeton."
            return
        }
        do {
            let r: StateResponse = try await client.get("/api/state")
            testResult = "✅ Connecté à JARVIS" + (r.state.ai.map { " — IA du PC : \($0)" } ?? "")
        } catch {
            testResult = "❌ \(error.localizedDescription)"
        }
    }
}

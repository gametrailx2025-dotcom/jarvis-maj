import SwiftUI

/// Connexion à JARVIS sur iPhone (v3.58) : on RELIE l'app au JARVIS du PC (code à 6 chiffres affiché sur le PC).
/// Le compte VTH du PC devient le compte de l'app, et le PC lui donne les clés de l'IA incluse
/// (elles ne sont plus dans l'app).
struct LoginGateView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var discovery = PCDiscovery()
    @State private var pcURL = UserDefaults.standard.string(forKey: SettingsKey.pcURL) ?? ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ZStack {
            BackgroundView()
            ScrollView {
                card
                    .frame(maxWidth: 640)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            error = model.accounts.logoutReason
            discovery.start()
        }
        .onDisappear { discovery.stop() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            CoreView(mode: busy ? .thinking : .idle, size: 76)
                .frame(width: 76, height: 76)
            Text("Relier à mon PC")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Theme.text)
            Text("Sur le PC, dans JARVIS : Paramètres › Outils › « 📱 Relier un appareil ». Un code à 6 chiffres s'affiche.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.text.opacity(0.8))

            if discovery.found.isEmpty {
                HStack(spacing: 8) {
                    if discovery.searching { ProgressView().controlSize(.small) }
                    Text(discovery.searching ? "Recherche des PC JARVIS sur le Wi-Fi…" : "Aucun PC trouvé : tape son adresse.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
            } else {
                ForEach(discovery.found) { pc in
                    Button {
                        pcURL = pc.url
                    } label: {
                        HStack {
                            Image(systemName: "desktopcomputer")
                            Text(pc.name)
                            Spacer()
                            if pcURL == pc.url { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.cyan) }
                        }
                        .foregroundStyle(Theme.text)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }

            TextField("Adresse du PC, ex. http://192.168.1.14:8765", text: $pcURL)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))

            TextField("Code à 6 chiffres", text: $code)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))

            Button {
                Task { await link() }
            } label: {
                Text(busy ? "Connexion…" : "Relier")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(Capsule().fill(Theme.cyan))
            }
            .buttonStyle(.plain)
            .disabled(busy || pcURL.isEmpty || code.filter(\.isNumber).count != 6)

            if let error {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
            Text("L'iPhone et le PC doivent être sur le même Wi-Fi, et JARVIS doit être ouvert sur le PC.")
                .font(.footnote).foregroundStyle(Theme.muted)
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(white: 0.05).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.cyan.opacity(0.25)))
    }

    private func link() async {
        busy = true
        error = nil
        defer { busy = false }
        var url = pcURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasPrefix("http") { url = "http://" + url }
        if !url.dropFirst(7).contains(":") { url += ":8765" }
        do {
            let token = try await PCDiscovery.pair(url: url, code: code)
            Keychain.set(token, for: Keychain.pcToken)
            UserDefaults.standard.set(url, forKey: SettingsKey.pcURL)
            guard let client = JarvisClient.make(urlString: url, token: token) else { throw ClientError.badURL }
            let who: PCAccount = try await client.get("/api/account")
            if let keys: PCKeys = try? await client.get("/api/keys") {
                Keychain.set(keys.groq_key ?? "", for: BuiltinKeys.groqStore)
                Keychain.set((keys.gemini_keys ?? []).joined(separator: ","), for: BuiltinKeys.geminiStore)
            }
            code = ""
            model.accounts.signIn(name: who.name ?? "JARVIS", email: who.email ?? "", discord: "")
            model.connect()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Compte du PC (VTH) : GET /api/account
struct PCAccount: Decodable {
    let name: String?
    let email: String?
    let avatar: String?
}

/// Clés de l'IA incluse, données par le PC : GET /api/keys
struct PCKeys: Decodable {
    let groq_key: String?
    let gemini_keys: [String]?
}

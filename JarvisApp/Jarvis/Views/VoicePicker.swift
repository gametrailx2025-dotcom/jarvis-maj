import SwiftUI

/// Réglages › Voix : choix de la voix premium, extrait à écouter, qualité.
struct VoicePicker: View {
    @EnvironmentObject var model: AppModel
    @State private var voices: [PremiumVoice.Voice] = []
    @State private var selected = PremiumVoice.current.id
    @State private var enabled = PremiumVoice.isEnabled
    @State private var quality = PremiumVoice.highQuality
    @State private var loading = false
    @State private var credits: [PremiumVoice.Credits] = []
    @State private var loadingCredits = false

    var body: some View {
        Toggle("Voix premium (très naturelle)", isOn: $enabled)
            .onChange(of: enabled) { _, on in PremiumVoice.isEnabled = on }
        if enabled {
            if voices.isEmpty {
                HStack {
                    Text("Voix actuelle : \(PremiumVoice.current.name)")
                    Spacer()
                    Button(loading ? "Chargement…" : "Voir les voix") { Task { await load() } }.disabled(loading)
                }
            } else {
                Picker("Voix", selection: $selected) {
                    ForEach(voices) { v in
                        Text(v.detail.isEmpty ? v.name : "\(v.name) — \(v.detail)").tag(v.id)
                    }
                }
                .onChange(of: selected) { _, id in
                    if let v = voices.first(where: { $0.id == id }) {
                        PremiumVoice.select(v)
                        model.speaker.say("Bonjour, je suis JARVIS. Voici ma nouvelle voix.")
                    }
                }
                if let v = voices.first(where: { $0.id == selected }), let url = v.previewURL {
                    Button("▶︎ Écouter un extrait") { model.speaker.preview(url) }
                }
            }
            Toggle("Haute qualité (plus expressive, un peu plus lente)", isOn: $quality)
                .onChange(of: quality) { _, on in PremiumVoice.highQuality = on }
            HStack {
                Text("Crédits de la voix premium").font(.subheadline.bold())
                Spacer()
                Button(loadingCredits ? "…" : "Actualiser") { Task { await loadCredits() } }.disabled(loadingCredits)
            }
            .task { if credits.isEmpty { await loadCredits() } }
            ForEach(credits) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Clé \(c.id) \(c.key)").font(.callout)
                        Spacer()
                        Text(c.active ? "● utilisée" : "en réserve").font(.caption)
                            .foregroundStyle(c.active ? .green : .secondary)
                    }
                    if let err = c.error {
                        Text(err).font(.caption).foregroundStyle(.orange)
                    } else {
                        ProgressView(value: Double(c.used), total: Double(max(c.limit, 1)))
                        Text("\(c.remaining.formatted()) caractères restants sur \(c.limit.formatted())"
                             + (c.reset.map { " · remise à zéro le \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func loadCredits() async {
        loadingCredits = true
        credits = await PremiumVoice.credits()
        loadingCredits = false
    }

    private func load() async {
        loading = true
        voices = await PremiumVoice.listVoices()
        loading = false
        if !voices.contains(where: { $0.id == selected }) { voices.insert(PremiumVoice.current, at: 0) }
    }
}

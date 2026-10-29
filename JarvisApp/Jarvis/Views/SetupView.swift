import CoreLocation
import Speech
import SwiftUI

/// Guide de configuration : au premier lancement, puis rappelé à chaque ouverture tant qu'il manque l'essentiel.
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("setupSeen") private var setupSeen = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Bienvenue ! Il suffit d'autoriser le micro : l'IA est incluse, rien d'autre à configurer. "
                         + "Le reste est facultatif.")
                        .font(.system(size: 15))
                }

                step(1, "Autoriser le micro et la reconnaissance vocale", done: model.speech.isAuthorized, required: true) {
                    Text("Pour me parler et m'activer en disant « Jarvis ».").font(.footnote)
                    Button("Autoriser") { Task { await model.applyWakeWord(); model.objectWillChange.send() } }
                }

                step(2, "Autoriser la localisation", done: model.location.status != .notDetermined, required: false) {
                    Text("Pour savoir où vous êtes (météo du briefing).").font(.footnote)
                    Button("Autoriser") { Task { await model.refreshWeather() } }
                }

                step(3, "Choisir la couleur de JARVIS", done: model.accentHex != Theme.defaultAccent, required: false) {
                    ColorChooser()
                }

                step(4, "Relier votre PC", done: model.isConnected, required: false) {
                    Text("Pour piloter le PC, la maison connectée, les mails, tâches et routines. "
                         + "Installez d'abord JARVIS sur le PC (fichier TUTORIEL.md, étapes G et N).")
                        .font(.footnote)
                    Button("Saisir l'adresse et le jeton du PC") {
                        finish()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.showSettings = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(setupSeen ? "Configuration" : "Bienvenue")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.missingSetup(requiredOnly: true).isEmpty ? "Terminer" : "Plus tard") { finish() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
    }

    private func finish() {
        setupSeen = true
        dismiss()
    }

    @ViewBuilder
    private func step<Content: View>(_ n: Int, _ title: String, done: Bool, required: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        Section {
            if !done { content() }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : (required ? "exclamationmark.circle.fill" : "circle"))
                    .foregroundStyle(done ? .green : (required ? .orange : .secondary))
                Text(n > 0 ? "\(n). \(title)" : title)
                if !required { Text("facultatif").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

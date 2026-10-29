import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.accounts.isSignedIn {
            LoginGateView()        // pas de JARVIS sans compte
        } else {
            mainView
        }
    }

    private var mainView: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 980
            ZStack {
                BackgroundView()
                VStack(spacing: 0) {
                    HeaderView(compact: !wide)
                    if let stage = model.stage {
                        // Mode « Iron Man » : le contenu en grand, JARVIS dans un coin
                        StageView(content: stage)
                    } else {
                    if model.screens == 1 { CategoryBar() }
                    Group {
                        if model.tab == .accueil {
                            if model.screens > 1 { soloHome } else if wide { wideHome } else { compactHome }
                        } else {
                            CategoryContent(tab: model.tab)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: model.stage)
            }
            .sheet(isPresented: $model.showSetup) {
                SetupView().environmentObject(model)
            }
        }
        .id(model.accentHex)              // redessine tout quand la couleur change
        .preferredColorScheme(.dark)
        .tint(Theme.cyan)
        .sheet(isPresented: $model.showSettings, onDismiss: {
            model.connect()
            Task {
                await model.refreshWeather()
                await model.applyWakeWord()
            }
        }) {
            SettingsView().environmentObject(model)
        }
        .task { model.start() }
    }

    /// Mac et iPad : trois colonnes, comme l'interface Windows.
    private var wideHome: some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                VStack(spacing: 16) { MailPanel(); SystemSummaryPanel() }
            }
            .frame(width: 330)
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                CoreView(mode: model.coreMode, size: 250)
                CoreStatusText()
                Spacer(minLength: 0)
                ChatPanel()
                    .frame(height: 290)
            }
            ScrollView {
                VStack(spacing: 16) { TodayPanel(); PCToolsPanel() }
            }
            .frame(width: 350)
        }
        .padding(16)
    }

    /// Plusieurs écrans : l'écran principal ne garde que JARVIS, en grand (le reste est sur les autres écrans).
    private var soloHome: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            CoreView(mode: model.coreMode, size: 340)
            CoreStatusText()
            Spacer(minLength: 0)
            ChatPanel()
                .frame(maxWidth: 900)
                .frame(height: 300)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    /// iPhone : le noyau et la conversation ; le reste est dans les catégories.
    private var compactHome: some View {
        VStack(spacing: 6) {
            CoreView(mode: model.coreMode, size: 190)
            CoreStatusText()
            ChatPanel()
                .frame(maxHeight: 360)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
}

/// Résumé système de l'accueil : le PC s'il est connecté, sinon cet appareil.
struct SystemSummaryPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.isConnected {
            SystemPanel()
        } else if let s = model.local.stats {
            Panel(title: "Système · \(model.local.deviceName)", tag: "santé \(s.health.score)/100") {
                HStack {
                    RingGauge(value: s.cpu, label: "CPU", text: "\(Int(s.cpu.rounded()))%")
                    RingGauge(value: s.ramPercent, label: "RAM", text: "\(Int(s.ramPercent.rounded()))%", warn: 85, crit: 95)
                    RingGauge(value: s.diskPercent, label: "Disque", text: "\(Int(s.diskPercent.rounded()))%", warn: 85, crit: 95)
                }
                Sparkline(values: s.history)
                Button("Voir le détail") { model.tab = .systeme }.buttonStyle(HUDButtonStyle(filled: false))
            }
        }
    }
}

struct HeaderView: View {
    @EnvironmentObject var model: AppModel
    let compact: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFill()
                .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
                .clipShape(Circle())
                .shadow(color: Theme.cyan, radius: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("J.A.R.V.I.S")
                    .font(Theme.display(compact ? 17 : 20, weight: .heavy))
                    .tracking(compact ? 4 : 6)
                    .foregroundStyle(Theme.cyan)
                    .shadow(color: Theme.cyan.opacity(0.7), radius: 8)
                if !compact {
                    Text(model.remoteState.ai.map { "IA : \($0)" } ?? "Assistant personnel")
                        .font(.system(size: 11)).tracking(1).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer()
            if !compact {
                TimelineView(.periodic(from: .now, by: 1)) { tl in
                    VStack(spacing: 0) {
                        Text(tl.date, format: .dateTime.hour().minute().second())
                            .font(Theme.display(28)).foregroundStyle(.white).shadow(color: Theme.cyan, radius: 8)
                        Text(tl.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Locale(identifier: "fr_FR"))).uppercased())
                            .font(.system(size: 11)).tracking(2).foregroundStyle(Theme.cyanSoft)
                    }
                }
                Spacer()
            }
            connectionChip
            Button {
                let on = !model.voiceEnabled
                UserDefaults.standard.set(on, forKey: SettingsKey.voiceEnabled)
                if !on { model.speaker.stop() }
                model.objectWillChange.send()
            } label: {
                Image(systemName: model.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .foregroundStyle(model.voiceEnabled ? Theme.cyan : Theme.muted)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(Theme.cyan.opacity(0.3)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voix")
            Button { model.showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(Theme.cyan)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(Theme.cyan.opacity(0.3)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Réglages")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [Theme.cyan.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var connectionChip: some View {
        let color: Color = {
            switch model.connection {
            case .connected: return Theme.green
            case .connecting: return Theme.amber
            case .failed: return Theme.red
            case .notConfigured: return Theme.muted
            }
        }()
        return Button { model.connect() } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8).shadow(color: color, radius: 4)
                if !compact {
                    Text(model.connection.label.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1)
                }
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(Capsule().stroke(Theme.cyan.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        if case .failed(let why) = model.connection { return why }
        return model.connection.label
    }
}

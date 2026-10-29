import SwiftUI

// MARK: - Météo

struct WeatherPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(title: "Météo", tag: (model.weatherFromLocation ? "📍 " : "") + (model.weather?.city ?? model.city)) {
            if let w = model.weather {
                HStack(spacing: 14) {
                    Image(systemName: WeatherCodes.symbol(w.code))
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.cyan)
                        .shadow(color: Theme.cyan, radius: 6)
                    Text("\(Int(w.temp.rounded()))°")
                        .font(Theme.display(44))
                        .foregroundStyle(.white)
                        .shadow(color: Theme.cyan.opacity(0.6), radius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.description.prefix(1).uppercased() + w.description.dropFirst())
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(details(w)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(Array(w.days.prefix(4).enumerated()), id: \.offset) { i, d in
                        VStack(spacing: 3) {
                            Text(i == 0 ? "AUJ." : dayName(d.date))
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.cyanSoft)
                            Image(systemName: WeatherCodes.symbol(d.code)).foregroundStyle(Theme.cyan)
                            Text("\(Int(d.min.rounded()))° / \(Int(d.max.rounded()))°").font(Theme.mono(11))
                                .foregroundStyle(Theme.text)
                            if let r = d.rain {
                                Text("☂ \(r) %").font(.system(size: 10)).foregroundStyle(Theme.muted)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Theme.cyan.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.cyan.opacity(0.2)))
                    }
                }
            } else {
                Text(model.weatherError ?? "Chargement…").foregroundStyle(Theme.muted)
            }
        }
    }

    private func details(_ w: WeatherInfo) -> String {
        var parts: [String] = []
        if let f = w.feels { parts.append("Ressenti \(Int(f.rounded()))°") }
        if let v = w.wind { parts.append("vent \(Int(v.rounded())) km/h") }
        if let h = w.humidity { parts.append("\(Int(h.rounded())) %") }
        return parts.joined(separator: " · ")
    }

    private func dayName(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE"
        return f.string(from: d).uppercased()
    }
}

// MARK: - Système (PC)

struct SystemPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(title: "Système du PC", tag: uptime) {
            if let s = model.stats {
                HStack {
                    RingGauge(value: s.cpu, label: "CPU", text: "\(Int(s.cpu.rounded()))%")
                    RingGauge(value: s.ram.percent, label: "RAM", text: "\(Int(s.ram.percent.rounded()))%", warn: 80, crit: 92)
                    let disk = s.disks.max(by: { $0.percent < $1.percent })
                    RingGauge(value: disk?.percent, label: "Disque",
                              text: disk.map { "\(Int($0.percent.rounded()))%" } ?? "--", warn: 85, crit: 95)
                    let t = s.temps?.cpu
                    RingGauge(value: t, label: "Temp.", text: t.map { "\(Int($0.rounded()))°" } ?? "N/D", warn: 75, crit: 88)
                }
                HStack {
                    Text("CHARGE PROCESSEUR").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                    Spacer()
                    Text(String(format: "%.1f %%", s.cpu)).font(Theme.mono(11))
                }
                .foregroundStyle(Theme.muted)
                Sparkline(values: s.cpu_history ?? [])
                if let top = s.top, !top.isEmpty {
                    Text("PROCESSUS GOURMANDS").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                        .foregroundStyle(Theme.muted)
                    ForEach(top.prefix(5)) { p in
                        HStack {
                            Text(p.name + ((p.count ?? 1) > 1 ? " ×\(p.count ?? 1)" : ""))
                                .lineLimit(1).font(.system(size: 13)).foregroundStyle(Theme.text)
                            Spacer()
                            Text(String(format: "%.1f %%", p.cpu)).font(Theme.mono(11)).foregroundStyle(Theme.cyanSoft)
                            Text("\(Int(p.mem_mb)) Mo").font(Theme.mono(11)).foregroundStyle(Theme.cyanSoft)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            } else {
                Text(model.connection == .connected ? "En attente des mesures…" : "Connectez JARVIS sur votre PC (Réglages) pour voir son état en direct.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
        }
    }

    private var uptime: String? {
        guard let u = model.stats?.uptime_s else { return nil }
        let h = Int(u) / 3600, m = (Int(u) % 3600) / 60
        return "actif \(h) h \(String(format: "%02d", m))"
    }
}

struct RingGauge: View {
    let value: Double?
    let label: String
    let text: String
    var warn: Double = 75
    var crit: Double = 90

    private var color: Color {
        guard let v = value else { return Theme.muted }
        return v >= crit ? Theme.red : (v >= warn ? Theme.amber : Theme.cyan)
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Theme.cyan.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(value ?? 0, 0), 100) / 100))
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color, radius: 4)
                    .animation(.easeOut(duration: 0.8), value: value)
                Text(text).font(Theme.display(14)).foregroundStyle(.white)
            }
            .frame(width: 60, height: 60)
            Text(label.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let data = Array(values.suffix(90))
            if data.count > 1 {
                let step = w / 89
                let x0 = w - CGFloat(data.count - 1) * step
                let pts = data.enumerated().map { CGPoint(x: x0 + CGFloat($0.offset) * step,
                                                          y: h - CGFloat($0.element / 100) * (h - 4) - 2) }
                Path { p in
                    p.addLines(pts)
                    p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: h))
                    p.addLine(to: CGPoint(x: pts[0].x, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Theme.cyan.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                Path { p in p.addLines(pts) }
                    .stroke(Theme.cyan, lineWidth: 1.6)
                    .shadow(color: Theme.cyan, radius: 4)
            }
        }
        .frame(height: 70)
    }
}

// MARK: - Agenda (PC)

struct TodayPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var newTask = ""
    @State private var showEvent = false
    @State private var eventTitle = ""
    @State private var eventDate = Date().addingTimeInterval(3600)

    var body: some View {
        Panel(title: "Aujourd'hui", tag: tag) {
            if let a = model.agenda {
                if a.events.isEmpty {
                    Text("Aucun rendez-vous aujourd'hui.").foregroundStyle(Theme.muted).font(.system(size: 14))
                }
                ForEach(a.events) { e in
                    HStack(spacing: 10) {
                        Text(e.timeLabel).font(Theme.mono(13)).foregroundStyle(Theme.cyan).frame(width: 60, alignment: .leading)
                        Text(e.title).font(.system(size: 14)).foregroundStyle(Theme.text)
                    }
                }
                Divider().overlay(Theme.cyan.opacity(0.2))
                Text("TÂCHES").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Theme.muted)
                if a.tasks.isEmpty {
                    Text("Aucune tâche en attente.").foregroundStyle(Theme.muted).font(.system(size: 14))
                }
                ForEach(a.tasks) { t in
                    HStack(spacing: 10) {
                        Button { Task { await model.completeTask(t.id) } } label: {
                            Image(systemName: "square").foregroundStyle(Theme.cyan)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Marquer comme faite")
                        Text(t.title).font(.system(size: 14)).foregroundStyle(Theme.text)
                        Spacer()
                        if let due = t.due {
                            Text(String(due.suffix(5))).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                HStack {
                    TextField("Nouvelle tâche…", text: $newTask)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.text)
                        .padding(8)
                        .background(Color.black.opacity(0.35))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.cyan.opacity(0.25)))
                        .onSubmit(add)
                    Button("+", action: add).buttonStyle(HUDButtonStyle(filled: false))
                }
                DisclosureGroup("Ajouter un rendez-vous", isExpanded: $showEvent) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Titre", text: $eventTitle)
                            .textFieldStyle(.plain).foregroundStyle(Theme.text).padding(8)
                            .background(Color.black.opacity(0.35))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.cyan.opacity(0.25)))
                        HStack {
                            DatePicker("", selection: $eventDate).labelsHidden()
                            Spacer()
                            Button("Ajouter") {
                                let t = eventTitle, d = eventDate
                                eventTitle = ""
                                showEvent = false
                                Task { await model.addEvent(t, start: d) }
                            }
                            .buttonStyle(HUDButtonStyle(filled: false))
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.muted)
            } else {
                Text("Chargement…").font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
        }
    }

    private var tag: String? {
        guard let a = model.agenda else { return nil }
        return "\(a.events.count) rdv · \(a.tasks.count) tâche\(a.tasks.count > 1 ? "s" : "")"
    }

    private func add() {
        let t = newTask
        newTask = ""
        Task { await model.addTask(t) }
    }
}

// MARK: - Routines (PC)

struct RoutinesPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(title: "Routines") {
            if model.routines.isEmpty {
                Text("Aucune routine.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            ForEach(model.routines) { r in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name.prefix(1).uppercased() + r.name.dropFirst())
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                        Text(r.trigger ?? "").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    Button("Lancer") { Task { await model.runRoutine(r.name) } }
                        .buttonStyle(HUDButtonStyle(filled: false))
                    Toggle("", isOn: Binding(get: { r.enabled },
                                             set: { on in Task { await model.toggleRoutine(r.name, enabled: on) } }))
                        .labelsHidden()
                        .tint(Theme.cyan)
                }
            }
        }
    }
}

// MARK: - Gestion du PC (commandes envoyées au PC ; les actions sensibles demandent confirmation)

struct PCToolsPanel: View {
    @EnvironmentObject var model: AppModel
    private let pcTools: [(String, String, Bool)] = [
        ("Analyser", "Optimise mon PC", false),
        ("Nettoyer", "Nettoie les fichiers temporaires", false),
        ("Corbeille", "Vide la corbeille", false),
        ("Réseau", "Mon réseau", false),
        ("Mises à jour", "Mises à jour", false),
        ("Verrouiller", "Verrouille le PC", false),
        ("Veille", "Mets le PC en veille", false),
        ("Redémarrer", "Redémarre le PC", true),
        ("Éteindre", "Éteins le PC", true),
    ]
    private let macTools: [(String, String, Bool)] = [
        ("Analyser", "Optimise mon Mac", false),
        ("Nettoyer", "Nettoie les fichiers temporaires", false),
        ("Corbeille", "Vide la corbeille", false),
        ("Réseau", "Mon réseau", false),
        ("Mises à jour", "Mises à jour", false),
        ("Verrouiller", "Verrouille le Mac", false),
        ("Veille", "Mets le Mac en veille", false),
        ("Redémarrer", "Redémarre le Mac", true),
        ("Éteindre", "Éteins le Mac", true),
    ]
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6),
                           GridItem(.flexible(), spacing: 6)]

    private var onMac: Bool {
        #if os(macOS)
        return !model.isConnected
        #else
        return false
        #endif
    }

    var body: some View {
        Panel(title: onMac ? "Gestion du Mac" : "Gestion du PC") {
            if model.isConnected || onMac {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(onMac ? macTools : pcTools, id: \.0) { item in
                        Button { Task { await model.send(item.1) } } label: {
                            Text(item.0)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(item.2 ? Theme.amber : Theme.cyanSoft)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background((item.2 ? Theme.amber : Theme.cyan).opacity(0.07))
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke((item.2 ? Theme.amber : Theme.cyan).opacity(0.35)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Les actions sensibles demandent votre confirmation.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            } else {
                Text("Reliez JARVIS à votre PC (Réglages) pour le gérer d'ici.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
        }
    }
}

// MARK: - Mails importants (lus par le PC)

struct MailPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(title: "Mails importants", tag: model.mail.map { "\($0.items.count)" }) {
            if let m = model.mail {
                if !m.configured {
                    Text(model.isConnected ? "Boîte mail non configurée sur le PC (étape « Mails » du tutoriel)."
                         : "Ajoutez votre compte mail dans l'app Mail du Mac, puis autorisez JARVIS à la lire (touchez Actualiser).")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                } else if let err = m.error {
                    Text(err).font(.system(size: 14)).foregroundStyle(Theme.amber)
                } else if m.items.isEmpty {
                    Text("Aucun mail important non lu.").font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                ForEach(m.items.prefix(6)) { x in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(x.sender).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            Text(Self.when(x.ts)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        }
                        Text(x.subject).font(.system(size: 14)).foregroundStyle(Theme.text).lineLimit(2)
                        if let why = x.why?.first {
                            Text(why.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1)
                                .foregroundStyle(Theme.amber)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .overlay(Capsule().stroke(Theme.amber.opacity(0.4)))
                        }
                        if let snip = x.snippet, !snip.isEmpty {
                            Text(snip).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button("Actualiser") { Task { await model.refreshMail() } }
                    .buttonStyle(HUDButtonStyle(filled: false))
            } else {
                Text("Chargement…")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
        }
    }

    static func when(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "dd/MM"
        return f.string(from: d)
    }
}

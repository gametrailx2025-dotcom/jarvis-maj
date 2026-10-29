import Foundation

/// Tout ce que le PC fait pour l'organisation, mais directement sur ce Mac / iPhone (sans PC) :
/// tâches, rendez-vous, liste de courses, routines activées. Enregistré sur l'appareil.
@MainActor
final class LocalHub {
    struct Event: Codable, Identifiable { var id: Int; var title: String; var start: Date; var allDay: Bool }

    private struct Store: Codable {
        var tasks: [TaskItem] = []
        var events: [Event] = []
        var shopping: [ShoppingItem] = []
        var routinesOff: [String] = []
        var nextID = 1
    }

    private var store = Store()
    private let key = "jarvisLocalHub"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(Store.self, from: data) {
            store = s
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(store) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func newID() -> Int {
        defer { store.nextID += 1 }
        return store.nextID
    }

    // MARK: Tâches et rendez-vous

    var agenda: AgendaInfo {
        let cal = Calendar.current
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let today = store.events.filter { cal.isDateInToday($0.start) }.sorted { $0.start < $1.start }
            .map { AgendaEvent(title: $0.title, start: iso.string(from: $0.start), all_day: $0.allDay) }
        return AgendaInfo(events: today, tasks: store.tasks, error: nil)
    }

    var upcomingEvents: [Event] {
        store.events.filter { $0.start > Date().addingTimeInterval(-3600) }.sorted { $0.start < $1.start }
    }

    @discardableResult
    func addTask(_ title: String, due: String? = nil) -> TaskItem? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let item = TaskItem(id: newID(), title: String(t.prefix(200)), due: due)
        store.tasks.append(item)
        save()
        return item
    }

    func completeTask(_ id: Int) {
        store.tasks.removeAll { $0.id == id }
        save()
    }

    func completeTask(matching text: String) -> TaskItem? {
        let n = DeviceCommands.fold(text)
        guard let t = store.tasks.first(where: { DeviceCommands.fold($0.title).contains(n) }) else { return nil }
        completeTask(t.id)
        return t
    }

    var tasks: [TaskItem] { store.tasks }

    func addEvent(_ title: String, start: Date, allDay: Bool = false) {
        store.events.append(Event(id: newID(), title: title, start: start, allDay: allDay))
        store.events.removeAll { $0.start < Date().addingTimeInterval(-7 * 86400) }   // ménage : + de 7 jours
        save()
    }

    func removeEvent(_ id: Int) {
        store.events.removeAll { $0.id == id }
        save()
    }

    /// Reprise de la sauvegarde cloud du PC (quand le PC est injoignable).
    func replaceFromCloud(tasks: [String], events: [(String, Date)], shopping: [String]) {
        store.tasks = tasks.map { TaskItem(id: newID(), title: $0, due: nil) }
        store.events = events.map { Event(id: newID(), title: $0.0, start: $0.1, allDay: false) }
        store.shopping = shopping.map { ShoppingItem(id: newID(), item: $0) }
        save()
    }

    // MARK: Courses

    var shopping: [ShoppingItem] { store.shopping }

    func addShopping(_ item: String) {
        let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if store.shopping.contains(where: { DeviceCommands.fold($0.item) == DeviceCommands.fold(t) }) { return }
        store.shopping.append(ShoppingItem(id: newID(), item: String(t.prefix(120))))
        save()
    }

    func removeShopping(_ id: Int) {
        store.shopping.removeAll { $0.id == id }
        save()
    }

    func removeShopping(matching text: String) -> Bool {
        let n = DeviceCommands.fold(text)
        let before = store.shopping.count
        store.shopping.removeAll { DeviceCommands.fold($0.item) == n }
        save()
        return store.shopping.count < before
    }

    func clearShopping() {
        store.shopping.removeAll()
        save()
    }

    // MARK: Routines

    static let routineList: [(name: String, trigger: String, description: String)] = [
        ("briefing du matin", "Phrase : « briefing », « debout »", "Salutation, météo, agenda et état de l'appareil"),
        ("bonne nuit", "Phrase : « bonne nuit »", "Baisse le son, ferme l'écran Iron Man, éteint l'écran"),
        ("je pars", "Phrase : « je pars »", "Éteint l'écran (mot de passe au retour)"),
        ("je rentre", "Phrase : « je rentre »", "Bon retour + résumé"),
        ("mode travail", "Phrase : « mode travail »", "Ouvre Mail, Calendrier et Notes, son à 30 %"),
        ("mode gaming", "Phrase : « mode gaming »", "Ouvre Discord et Steam, son à 70 %"),
        ("mode concentration", "Phrase : « mode concentration »", "Ferme les messageries, son à 20 %"),
    ]

    var routines: [RoutineInfo] {
        Self.routineList.map {
            RoutineInfo(name: $0.name, description: $0.description, enabled: !store.routinesOff.contains($0.name),
                        trigger: $0.trigger, type: "phrase")
        }
    }

    func isRoutineEnabled(_ name: String) -> Bool { !store.routinesOff.contains(name) }

    func setRoutine(_ name: String, enabled: Bool) {
        store.routinesOff.removeAll { $0 == name }
        if !enabled { store.routinesOff.append(name) }
        save()
    }

    // MARK: Mails importants (classement, comme sur le PC)

    static func importance(sender: String, subject: String, body: String) -> [String] {
        let t = DeviceCommands.fold(sender + " " + subject + " " + String(body.prefix(600)))
        var why: [String] = []
        let rules: [(String, String)] = [
            ("securite", #"(securite|connexion inhabituelle|nouvelle connexion|mot de passe|code de verification|code de confirmation|2fa|alerte)"#),
            ("echeance", #"(echeance|facture|paiement|a regler|impaye|relance|date limite|avant le)"#),
            ("rendez-vous", #"(rendez-vous|rdv|reunion|invitation|convocation|entretien)"#),
            ("livraison", #"(livraison|colis|expedie|commande n|suivi de commande)"#),
            ("administratif", #"(impots|caf|ameli|urssaf|banque|assurance|mutuelle|pole emploi|france travail)"#),
        ]
        for (label, pattern) in rules where t.range(of: pattern, options: .regularExpression) != nil {
            why.append(label)
        }
        if t.range(of: #"(newsletter|promo|soldes|offre speciale|-\d+ ?%|se desabonner|unsubscribe)"#,
                   options: .regularExpression) != nil, !why.contains("securite") {
            return []
        }
        return why
    }
}

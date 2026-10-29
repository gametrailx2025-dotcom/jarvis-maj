import Foundation

/// Réponses quand le PC n'est pas joignable : heure, date, météo, aide, et conversation IA.
/// Les commandes qui agissent sur un ordinateur ne sont JAMAIS simulées : elles exigent le PC.
@MainActor
struct LocalBrain {
    let model: AppModel

    static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        t = t.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "-", with: " ")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for wake in ["ok jarvis", "hey jarvis", "jarvis"] where t.hasPrefix(wake) {
            t = String(t.dropFirst(wake.count))
            break
        }
        if t.hasSuffix("jarvis") { t = String(t.dropLast(6)) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // Fautes de frappe courantes sur le premier mot (« étein la prise », « alume la lampe »)
        var words = t.split(separator: " ", maxSplits: 1).map(String.init)
        if let first = words.first, let fixed = typos[first] {
            words[0] = fixed
            t = words.joined(separator: " ")
        }
        return t
    }

    private static let typos: [String: String] = [
        "etein": "eteins", "eteint": "eteins", "eteind": "eteins", "etain": "eteins", "etin": "eteins",
        "alume": "allume", "allumes": "allume", "alumes": "allume", "allum": "allume", "ouvres": "ouvre", "met": "mets",
    ]

    private static let pcVerbs = ["ouvre", "ferme", "lance", "demarre", "quitte", "mets", "monte", "baisse",
                                  "coupe", "ajoute", "rappelle", "memorise", "oublie", "va sur"]
    private static let pcWords: Set<String> = ["pc", "processus", "temperature"]

    func handle(_ text: String, pcError: String?) async -> String {
        let t = Self.normalize(text)
        let words = Set(t.split(separator: " ").map(String.init))
        if t.isEmpty { return "Oui ? Je vous écoute." }
        // Commandes exécutées sur cet appareil (prénom, minuteurs ; sur Mac : applis, volume, sites, veille)
        if let local = await DeviceCommands.handle(t, raw: text, model: model) { return local }

        if t.contains("quelle heure") || t == "l'heure" {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let h = c.hour ?? 0, m = c.minute ?? 0
            return "Il est \(h) heure\(h > 1 ? "s" : "")" + (m > 0 ? " \(String(format: "%02d", m))." : ".")
        }
        if t.contains("quel jour") || t.contains("quelle date") {
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = "EEEE d MMMM yyyy"
            return "Nous sommes \(f.string(from: Date()))."
        }
        if t.contains("meteo") || t.contains("quel temps") || t.contains("pleuvoir") {
            await model.refreshWeather()
            return model.weather?.spoken ?? model.weatherError ?? "Météo indisponible."
        }
        if ["bonjour", "salut", "bonsoir", "coucou", "hello"].contains(t) {
            return "\(model.greetingWord()) \(model.userName). Je suis opérationnel. Que puis-je faire pour vous ?"
        }
        if t == "debout" || t.contains("briefing") || t.contains("reveille") {
            await model.refreshWeather()
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = "EEEE d MMMM, HH:mm"
            var s = "\(model.greetingWord()) \(model.userName). Nous sommes \(f.string(from: Date())). "
            s += model.weather?.spoken ?? ""
            s += " Pour l'agenda, les actualités et l'état de l'ordinateur, connectez-moi au JARVIS de votre PC."
            return s
        }
        if t == "aide" || t.contains("que sais tu faire") || t.contains("que peux tu faire") {
            #if os(macOS)
            return "Sur ce Mac : applications, sites, volume, musique, fichiers, écran, mails importants, tâches, "
                + "rendez-vous, liste de courses, minuteurs et rappels, briefing, routines (bonne nuit, je pars, mode travail, "
                + "mode gaming), entretien (corbeille, fichiers temporaires, réseau, mises à jour), veille, redémarrage, "
                + "maison connectée, la météo, et répondre à vos questions."
            #else
            return "Sur l'iPhone : tâches, rendez-vous, liste de courses, minuteurs et rappels, briefing, la météo, "
                + "la maison connectée, et répondre à vos questions. Relié au PC : piloter l'ordinateur."
            #endif
        }
        if Self.pcVerbs.contains(where: { t.hasPrefix($0) }) || !words.isDisjoint(with: Self.pcWords) {
            if let pcError {
                return "Cette commande s'exécute sur votre PC, mais je n'arrive pas à le joindre (\(pcError))."
            }
            return "Cette commande s'exécute sur votre PC. Renseignez son adresse et son jeton dans les Réglages."
        }
        guard model.ai.isConfigured else {
            if model.ai.provider == .jarvis {
                return "Connectez-vous à votre compte JARVIS (Réglages) pour discuter avec moi."
            }
            return "Je n'ai pas compris, et l'IA choisie n'est pas configurée (Réglages)."
        }
        do {
            let reply = try await model.ai.chat(text, userName: model.userName)
            // L'IA a compris une commande mal formulée : on l'exécute au lieu de demander de reformuler
            if let cmd = DeviceCommands.firstGroup(reply, #"\[\[\s*cmd\s*:\s*(.+?)\s*\]\]"#) {
                if let done = await DeviceCommands.handle(Self.normalize(cmd), raw: cmd, model: model) { return done }
                return "Je n'ai pas pu faire « \(cmd) » ici."
            }
            return reply.replacingOccurrences(of: #"\[\[\s*cmd\s*:[^\]]*\]\]"#, with: "", options: .regularExpression)
        } catch {
            return "L'IA ne répond pas : \(error.localizedDescription)"
        }
    }
}

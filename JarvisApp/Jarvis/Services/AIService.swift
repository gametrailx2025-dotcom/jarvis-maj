import Foundation

enum AIError: LocalizedError {
    case notConfigured, missingKey, http(Int, String), empty

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Aucune IA configurée (Réglages)."
        case .missingKey: return "Clé API manquante (Réglages)."
        case .http(401, _): return "Clé API refusée."
        case .http(402, _): return "Crédit du service d'IA insuffisant."
        case .http(let code, let msg): return "Erreur \(code) : \(msg)"
        case .empty: return "Réponse vide de l'IA."
        }
    }
}

/// IA conversationnelle de l'app (utilisée quand le PC n'est pas joignable).
/// Comme sur le PC, elle ne produit que du texte : aucune action n'est déclenchée.
@MainActor
final class AIService {
    enum Provider: String, CaseIterable, Identifiable {
        case jarvis, groq, openrouter, ollama, anthropic, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .jarvis: return "JARVIS (inclus avec le compte)"
            case .groq: return "Groq — développement"
            case .openrouter: return "OpenRouter — développement"
            case .ollama: return "Ollama (local)"
            case .anthropic: return "Anthropic"
            case .none: return "Aucune"
            }
        }
    }

    private var history: [[String: String]] = []
    /// Compte JARVIS : l'IA « incluse » passe par le serveur, avec la session de l'utilisateur.
    weak var cloud: SupabaseService?
    /// IA incluse (clés de l'éditeur) : rien à saisir pour l'utilisateur.
    private let builtin = BuiltinAI()
    private var defaults: UserDefaults { .standard }

    var provider: Provider {
        // Version publiée : toujours l'IA incluse (les autres choix ne servent qu'au développement).
        if AppConfig.hasBuiltInServer { return .jarvis }
        return Provider(rawValue: defaults.string(forKey: SettingsKey.aiProvider) ?? "") ?? .jarvis
    }

    /// Pas de compte connecté (ou clé de développement absente) → IA incluse directe.
    var usesBuiltin: Bool {
        switch provider {
        // IA incluse directe par défaut ; la fonction serveur seulement si « useServerAI » est activé (une fois déployée)
        case .jarvis: return !(UserDefaults.standard.bool(forKey: "useServerAI") && (cloud?.isSignedIn ?? false))
        case .groq: return Keychain.get(Keychain.groqKey) == nil
        case .openrouter: return Keychain.get(Keychain.openrouterKey) == nil
        default: return false
        }
    }

    var model: String {
        if usesBuiltin { return "IA JARVIS incluse" }
        let custom = (defaults.string(forKey: SettingsKey.aiModel) ?? "").trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        switch provider {
        case .jarvis: return "serveur JARVIS"
        case .groq: return "openai/gpt-oss-120b"
        case .openrouter: return "openrouter/auto"
        case .ollama: return "llama3.1:8b"
        case .anthropic: return "claude-sonnet-5-5"
        case .none: return ""
        }
    }

    var isConfigured: Bool {
        if usesBuiltin { return true }
        switch provider {
        case .none: return false
        case .jarvis: return cloud?.isSignedIn ?? false
        case .groq: return Keychain.get(Keychain.groqKey) != nil
        case .ollama: return true
        case .openrouter: return Keychain.get(Keychain.openrouterKey) != nil
        case .anthropic: return Keychain.get(Keychain.anthropicKey) != nil
        }
    }

    func reset() { history.removeAll() }

    /// Rédige un texte prêt à envoyer (mail, message…), sans reformatage oral : les retours à la ligne sont gardés.
    func compose(_ request: String, userName: String) async throws -> String {
        let system = "Tu rédiges des textes pour \(userName), en français, à sa place et à la première personne. "
            + "Réponds UNIQUEMENT avec le texte final, prêt à être collé : pas d'introduction, pas de guillemets, "
            + "pas de commentaire, pas de markdown. Ton naturel et adapté au destinataire. Si un objet de mail est utile, "
            + "ne l'écris pas : seulement le corps du message."
        var out = try await complete([["role": "user", "content": request]], system: system, allowWeb: false)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("\""), out.hasSuffix("\""), out.count > 2 { out = String(out.dropFirst().dropLast()) }
        return out
    }

    /// Analyse d'image (écran) : toujours via l'IA incluse, qui sait lire les images.
    func describeImage(_ data: Data, mime: String = "image/jpeg", question: String) async throws -> String {
        let system = "Tu es JARVIS. Réponds en français, naturellement, en quelques phrases. Décris ce que tu vois "
            + "avec précision, lis le texte visible si c'est utile, et ne devine pas ce qui n'est pas visible."
        let raw = try await builtin.describeImage(data, mime: mime, question: question, system: system)
        return Self.naturalize(raw)
    }

    /// Créateurs de JARVIS (Réglages avancés : clé « creators », séparés par des virgules).
    static var creators: String {
        let raw = UserDefaults.standard.string(forKey: "creators") ?? "Nathan"
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if names.count <= 1 { return names.first ?? "Nathan" }
        return names.dropLast().joined(separator: ", ") + " et " + names.last!
    }

    func chat(_ text: String, userName: String) async throws -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        let mem = UserDefaults.standard.stringArray(forKey: "memories") ?? []
        let memoryText = mem.isEmpty ? "(rien pour l'instant)" : mem.suffix(30).map { "• " + $0 }.joined(separator: "\n")
        let system = """
        Tu es JARVIS, l'assistant personnel de \(userName). Tu parles comme une vraie personne, pas comme une IA : \
        phrases courtes et naturelles, ton chaleureux et calme, une pointe d'humour quand ça s'y prête. \
        Réponds directement, comme à l'oral (tes réponses sont lues à voix haute) : pas de listes à puces, pas de titres, \
        pas de markdown, pas d'émojis. Bannis les formules robotiques (« En tant qu'IA », « N'hésitez pas », \
        « Je suis là pour vous aider », « Bien sûr ! Voici… », « Excellente question »). Ne répète pas la question, \
        ne résume pas ta réponse à la fin. Vouvoie l'utilisateur. Une à trois phrases suffisent le plus souvent. \
        N'invente jamais de chiffres ni de sources. Date : \(f.string(from: Date())). \
        Tu as été créé par \(Self.creators). Si on te demande qui t'a créé, cite-les tous. \
        Les phrases viennent souvent de la reconnaissance vocale, avec des mots mal entendus : devine le sens le plus \
        probable au lieu de répondre à côté, et sers-toi de la conversation pour comprendre « ça », « le », « encore ».

        Ce que l'application JARVIS sait faire (réponds-y avec assurance si on te le demande) :
        - Internet : pour l'actualité ou une information récente, une recherche en ligne est faite automatiquement \
        et ses résultats te sont fournis ; cite brièvement tes sources. Si rien n'est trouvé, dis-le.
        - Onglet « Globe » (Mac) : la Terre en 3D en direct, issue du projet open source God's Eye View : avions \
        (dont trafic militaire), bateaux, satellites et lancements de fusées, séismes, incendies, météo (vent, radar \
        de pluie, nuages, éclairs, cyclones), trafic routier, caméras publiques, transports, vue cockpit, filtres \
        vision nocturne et thermique. Commandes : « ouvre le globe », « ferme le globe ». Tu ne vois pas toi-même \
        les données affichées : invite l'utilisateur à regarder l'onglet ou à cliquer sur un objet pour le suivre.
        - Fichiers (Mac) : « cherche le fichier … », « ouvre le fichier … » ou « ouvre le 2 » après une recherche, \
        « résume le fichier … », « mes téléchargements », « mon bureau », « mes documents ». Jamais de suppression.
        - Notes (« note que… », « cherche dans mes notes… »), trajets (« combien de temps pour aller à Lyon »), trafic,
        musique (« lance ma playlist chill »), routines « bonne nuit », « je pars », « je rentre ».
        - Écran (Mac) : « analyse mon écran », « c'est quoi cette erreur sur mon écran » : une capture est analysée à la demande.
        - Mac : ouvrir/fermer une application, aller sur un site, volume, veille, état du Mac. Minuteurs, rappels, \
        « appelle-moi … ». Relié au PC : maison connectée, mails, tâches, routines.
        Tu ne prétends jamais avoir fait une action toi-même. Mais si l'utilisateur demande une action que JARVIS sait faire (allumer / éteindre un appareil, ouvrir une appli, minuteur, volume, musique…) avec une faute, un mot manquant ou « ça » (ce dont on vient de parler), réponds UNIQUEMENT par la commande corrigée entre balises, par exemple [[cmd: éteins la prise 1]] : JARVIS l'exécute aussitôt. Ne demande jamais à l'utilisateur de reformuler.
        - Affichage à l'écran (comme le JARVIS d'Iron Man) : tu PEUX afficher quelque chose en grand dans l'app en \
        ajoutant à la fin de ta réponse UNE balise : [[web:https://adresse-exacte]] pour une page web utile et sûre, \
        [[image:sujet précis]] pour montrer une image, [[globe]] pour le globe. Utilise-la quand l'utilisateur veut voir \
        quelque chose ou quand c'est vraiment utile ; jamais d'adresse inventée. La balise est invisible pour lui.
        - Mémoire (« retiens que… ») — ce que l'utilisateur t'a demandé de retenir :
        \(memoryText)
        """
        var msgs = history
        msgs.append(["role": "user", "content": text])
        let raw = try await complete(msgs, system: system)
        let reply = Self.naturalize(raw)
        guard !reply.isEmpty else { throw AIError.empty }
        history.append(["role": "user", "content": text])
        history.append(["role": "assistant", "content": reply])
        if history.count > 24 { history.removeFirst(history.count - 24) }
        return reply
    }

    private func complete(_ msgs: [[String: String]], system: String, allowWeb: Bool = true) async throws -> String {
        if usesBuiltin { return try await builtin.complete(msgs, system: system, allowWeb: allowWeb) }
        let withSystem: [[String: String]] = [["role": "system", "content": system]] + msgs
        switch provider {
        case .none:
            throw AIError.notConfigured
        case .jarvis:
            guard let cloud else { throw AIError.notConfigured }
            return try await cloud.aiChat(messages: msgs, system: system)
        case .groq:
            guard let key = Keychain.get(Keychain.groqKey) else { throw AIError.missingKey }
            let json = try await post("https://api.groq.com/openai/v1/chat/completions",
                                      headers: ["Authorization": "Bearer \(key)"],
                                      body: ["model": model, "messages": withSystem])
            return Self.openAIText(json)
        case .openrouter:
            guard let key = Keychain.get(Keychain.openrouterKey) else { throw AIError.missingKey }
            let json = try await post("https://openrouter.ai/api/v1/chat/completions",
                                      headers: ["Authorization": "Bearer \(key)", "X-Title": "JARVIS",
                                                "HTTP-Referer": "https://localhost/jarvis"],
                                      body: ["model": model, "messages": withSystem])
            return Self.openAIText(json)
        case .ollama:
            let base = (defaults.string(forKey: SettingsKey.ollamaURL) ?? "http://localhost:11434")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let json = try await post(base + "/api/chat", headers: [:],
                                      body: ["model": model, "stream": false, "messages": withSystem])
            return (json["message"] as? [String: Any])?["content"] as? String ?? ""
        case .anthropic:
            guard let key = Keychain.get(Keychain.anthropicKey) else { throw AIError.missingKey }
            let json = try await post("https://api.anthropic.com/v1/messages",
                                      headers: ["x-api-key": key, "anthropic-version": "2023-06-01"],
                                      body: ["model": model, "max_tokens": 1500, "system": system, "messages": msgs])
            let blocks = json["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        }
    }

    /// Réponse plus naturelle à l'oral : sans markdown ni formules toutes faites (le code est préservé).
    static func naturalize(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("```") { return t }
        t = t.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        var parts: [String] = []
        for raw in t.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: #"^\s*([-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let last = parts.last, let end = last.last, !".!?:;…»".contains(end) {
                parts[parts.count - 1] = last + "."
            }
            parts.append(line.prefix(1).uppercased() + line.dropFirst())
        }
        t = parts.joined(separator: " ")
        let robotic = [
            #"^(bien s[uû]r|absolument|certainement|tout à fait|excellente question|bonne question)\s*[!,.]\s*"#,
            #"^(voici|voilà) (ce que|quelques?|la réponse)[^:]*:\s*"#,
            #"\s*(n'hésitez pas|n'hésite pas)[^.!?]*[.!?]\s*$"#,
            #"\s*(j'espère que cela|j'espère que ça)[^.!?]*[.!?]\s*$"#,
            #"\s*(si vous avez d'autres questions|souhaitez-vous que je|voulez-vous que je)[^.!?]*[.!?]\s*$"#,
            #"en tant qu'(ia|intelligence artificielle|assistant virtuel),?\s*"#,
        ]
        for _ in 0..<2 {
            for rx in robotic {
                t = t.replacingOccurrences(of: rx, with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        guard !t.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    private static func openAIText(_ json: [String: Any]) -> String {
        let choices = json["choices"] as? [[String: Any]] ?? []
        return (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
    }

    private func post(_ urlString: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw AIError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? (json["error"] as? String) ?? ""
            throw AIError.http(code, msg)
        }
        return json
    }
}

import Foundation

/// IA incluse : l'utilisateur n'a aucune clé à saisir. Les clés viennent du PC relié (elles ne sont pas dans l'app).
enum BuiltinKeys {
    /// Les clés ne sont plus dans l'app : le PC les donne au moment où on relie l'app (GET /api/keys).
    static let groqStore = "builtinGroq"
    static let geminiStore = "builtinGemini"
    static var geminiKeys: [String] {
        (Keychain.get(geminiStore) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
    static let geminiAPIBase = "https://generativelanguage.googleapis.com/v1beta/models"
    static var groqAPIKey: String { Keychain.get(groqStore) ?? "" }
    static let groqAPIURL = "https://api.groq.com/openai/v1/chat/completions"

    /// Du meilleur au plus léger ; bascule automatique si l'un échoue ou est saturé.
    static let chain: [(provider: String, model: String)] = [
        ("groq", "openai/gpt-oss-120b"),
        ("gemini", "gemini-3.8-flash"),
        ("groq", "openai/gpt-oss-20b"),
        ("gemini", "gemini-3.5-flash-lite"),
        ("groq", "llama-3.1-8b-instant"),
    ]
}

struct BuiltinAIError: LocalizedError {
    let offline: Bool
    var errorDescription: String? {
        offline ? "Impossible de joindre l'IA. Vérifiez votre connexion Internet."
                : "L'IA est momentanément indisponible. Réessayez dans un instant."
    }
}

final class BuiltinAI: @unchecked Sendable {
    private var geminiIndex = 0
    private let lock = NSLock()

    /// Questions d'actualité : recherche Google via Gemini (sources citées) ; secours : Wikipédia.
    static let webModel = "gemini-3.8-flash"

    static func needsWeb(_ text: String) -> Bool {
        let pattern = #"\b(aujourd'?hui|actuel(le)?s?|actualit[ée]s?|en ce moment|derni[eè]re?s?|r[ée]cent|news|"#
            + #"cherche|recherche|sur internet|sur le web|en ligne|prix|co[uû]te?|cours|score|r[ée]sultats?|match|"#
            + #"classement|sortie|sorti|qui est|qui a gagn[ée]|combien|quand|horaires?|ouvert|20[2-3][0-9]|"#
            + #"cette (semaine|ann[ée]e)|ce (mois|week-?end)|demain|hier)\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func complete(_ msgs: [[String: String]], system: String, allowWeb: Bool = true) async throws -> String {
        let question = msgs.last(where: { $0["role"] == "user" })?["content"] ?? ""
        var system = system
        if allowWeb && Self.needsWeb(question) {
            if let text = try? await geminiWeb(msgs, system), !text.isEmpty { return text }
            let wiki = await wikipedia(question)
            if !wiki.isEmpty {
                system += "\n\nInformations trouvées sur Internet (Wikipédia) — utilise-les si utiles :\n" + wiki
            }
        }
        return try await chain(msgs, system: system)
    }

    private func geminiWeb(_ msgs: [[String: String]], _ system: String) async throws -> String {
        let contents: [[String: Any]] = msgs.map { m -> [String: Any] in
            ["role": m["role"] == "assistant" ? "model" : "user", "parts": [["text": m["content"] ?? ""]]]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "tools": [["google_search": [String: Any]()]],
            "generationConfig": ["maxOutputTokens": 1024, "temperature": 0.4],
        ]
        let keys = BuiltinKeys.geminiKeys
        for _ in 0..<keys.count {
            let key = lock.withLock { keys[geminiIndex % keys.count] }
            do {
                let json = try await post("\(BuiltinKeys.geminiAPIBase)/\(Self.webModel):generateContent",
                                          headers: ["x-goog-api-key": key], body: body)
                let cand = (json["candidates"] as? [[String: Any]])?.first ?? [:]
                let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                var text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                let chunks = (cand["groundingMetadata"] as? [String: Any])?["groundingChunks"] as? [[String: Any]] ?? []
                var sources: [String] = []
                var titles: Set<String> = []
                for c in chunks {
                    let web = c["web"] as? [String: Any] ?? [:]
                    if let title = web["title"] as? String, !title.isEmpty, !titles.contains(title) {
                        titles.insert(title)
                        let uri = web["uri"] as? String ?? ""
                        sources.append(uri.isEmpty ? title : "\(title) \(uri)")
                    }
                }
                if !text.isEmpty && !sources.isEmpty {
                    text += "\n\nSources : " + sources.prefix(3).joined(separator: " · ")
                }
                return text
            } catch let e as HTTPStatus {
                lock.withLock { geminiIndex += 1 }
                if e.code == 400 || e.code == 404 { throw e }
            }
        }
        return ""
    }

    private func wikipedia(_ question: String) async -> String {
        var q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = q.range(of: #"^(jarvis[ ,]+)?(cherche|recherche|dis[- ]moi|explique[- ]moi)\s+(sur internet\s+)?"#,
                           options: [.regularExpression, .caseInsensitive]) {
            q.removeSubrange(r)
        }
        guard !q.isEmpty, var comps = URLComponents(string: "https://fr.wikipedia.org/w/api.php") else { return "" }
        comps.queryItems = [URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
                            URLQueryItem(name: "srsearch", value: String(q.prefix(200))),
                            URLQueryItem(name: "srlimit", value: "2"), URLQueryItem(name: "format", value: "json")]
        guard let url = comps.url else { return "" }
        var out: [String] = []
        do {
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("JARVIS-assistant/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let hits = (json["query"] as? [String: Any])?["search"] as? [[String: Any]] ?? []
            for hit in hits {
                guard let title = hit["title"] as? String,
                      let enc = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let sURL = URL(string: "https://fr.wikipedia.org/api/rest_v1/page/summary/" + enc) else { continue }
                var sReq = URLRequest(url: sURL, timeoutInterval: 8)
                sReq.setValue("JARVIS-assistant/1.0", forHTTPHeaderField: "User-Agent")
                let (sData, _) = try await URLSession.shared.data(for: sReq)
                let sJSON = (try? JSONSerialization.jsonObject(with: sData)) as? [String: Any] ?? [:]
                if let extract = sJSON["extract"] as? String, !extract.isEmpty {
                    out.append("« \(title) » : " + String(extract.prefix(900)))
                }
            }
        } catch {
            return out.joined(separator: "\n")
        }
        return out.joined(separator: "\n")
    }

    /// Analyse d'une image (capture d'écran…) par Gemini. Envoyée seulement à la demande de l'utilisateur.
    func describeImage(_ data: Data, mime: String, question: String, system: String) async throws -> String {
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [
                ["inline_data": ["mime_type": mime, "data": data.base64EncodedString()]],
                ["text": question.isEmpty ? "Décris précisément ce que tu vois." : question],
            ]]],
            "generationConfig": ["maxOutputTokens": 1024, "temperature": 0.4],
        ]
        let keys = BuiltinKeys.geminiKeys
        for model in [Self.webModel, "gemini-3.5-flash-lite"] {
            for _ in 0..<keys.count {
                let key = lock.withLock { keys[geminiIndex % keys.count] }
                do {
                    let json = try await post("\(BuiltinKeys.geminiAPIBase)/\(model):generateContent",
                                              headers: ["x-goog-api-key": key], body: body)
                    let cand = (json["candidates"] as? [[String: Any]])?.first ?? [:]
                    let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                    let text = parts.compactMap { $0["text"] as? String }.joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { return text }
                } catch let e as HTTPStatus {
                    lock.withLock { geminiIndex += 1 }
                    if e.code == 404 { break }
                }
            }
        }
        throw BuiltinAIError(offline: false)
    }

    private func chain(_ msgs: [[String: String]], system: String) async throws -> String {
        var allNetwork = true
        for step in BuiltinKeys.chain {
            do {
                let text: String
                if step.provider == "groq" {
                    text = try await groq(step.model, msgs, system)
                } else {
                    text = try await gemini(step.model, msgs, system)
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
                allNetwork = false
            } catch is URLError {
                // réseau injoignable : on garde allNetwork
            } catch {
                allNetwork = false
            }
        }
        throw BuiltinAIError(offline: allNetwork)
    }

    private func groq(_ model: String, _ msgs: [[String: String]], _ system: String) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system]] + msgs,
            "max_tokens": 1024,
            "temperature": 0.6,
        ]
        if model.hasPrefix("openai/gpt-oss") { body["reasoning_effort"] = "low" }
        let json = try await post(BuiltinKeys.groqAPIURL,
                                  headers: ["Authorization": "Bearer \(BuiltinKeys.groqAPIKey)"], body: body)
        let choices = json["choices"] as? [[String: Any]] ?? []
        return (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
    }

    private func gemini(_ model: String, _ msgs: [[String: String]], _ system: String) async throws -> String {
        let contents: [[String: Any]] = msgs.map { m -> [String: Any] in
            ["role": m["role"] == "assistant" ? "model" : "user", "parts": [["text": m["content"] ?? ""]]]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": ["maxOutputTokens": 1024, "temperature": 0.6],
        ]
        let keys = BuiltinKeys.geminiKeys
        var lastError: Error = BuiltinAIError(offline: false)
        for _ in 0..<keys.count {
            let key = lock.withLock { keys[geminiIndex % keys.count] }
            do {
                let json = try await post("\(BuiltinKeys.geminiAPIBase)/\(model):generateContent",
                                          headers: ["x-goog-api-key": key], body: body)
                let candidates = json["candidates"] as? [[String: Any]] ?? []
                let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                return parts.compactMap { $0["text"] as? String }.joined()
            } catch let e as HTTPStatus {
                lastError = e
                lock.withLock { geminiIndex += 1 }
                if e.code == 404 { break }   // modèle inconnu : inutile d'essayer les autres clés
            }
        }
        throw lastError
    }

    private struct HTTPStatus: Error { let code: Int }

    private func post(_ urlString: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw HTTPStatus(code: 0) }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HTTPStatus(code: code) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

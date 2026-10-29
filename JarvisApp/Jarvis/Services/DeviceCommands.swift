import Foundation
#if os(macOS)
import AppKit
import PDFKit
#endif

/// Action en attente de confirmation sur cet appareil (fermer une appli, mettre en veille…).
struct LocalPending {
    let label: String
    let created = Date()
    let run: @MainActor () -> String
}

/// Minuteur ou rappel géré par l'app elle-même (sans PC).
struct LocalTimer: Identifiable {
    let id = UUID()
    let label: String
    let end: Date
    let isReminder: Bool
}

/// Commandes exécutées directement sur cet appareil, sans PC :
/// prénom, minuteurs et rappels (iPhone + Mac) ; applis, volume, sites, veille (Mac).
@MainActor
enum DeviceCommands {

    /// Renvoie la réponse si la phrase est une commande locale, sinon nil.
    /// `t` = phrase normalisée (minuscules, sans accents) ; `raw` = phrase d'origine.
    static func handle(_ t: String, raw: String, model: AppModel) async -> String? {
        if let r = setName(raw, model: model) { return r }
        if let r = timers(t, model: model) { return r }
        if let r = await localFirst(t, raw: raw, model: model) { return r }
        if let r = await LocalCommands.handle(t, raw: raw, model: model) { return r }
        #if os(macOS)
        if let r = mac(t, model: model) { return r }
        #endif
        return nil
    }

    /// Commandes toujours traitées sur cet appareil, même relié au PC : globe et fichiers du Mac.
    static func localFirst(_ t: String, raw: String, model: AppModel) async -> String? {
        if let r = stageCommand(t, model: model) { return r }
        if let r = memory(raw, t, model: model) { return r }
        if let r = globeCommand(t, model: model) { return r }
        if let r = await voiceCommand(t, model: model) { return r }
        if let r = notes(raw, t, model: model) { return r }
        if let r = await travel(t, model: model) { return r }
        if let r = website(t, model: model) { return r }
        if let r = await imageCommand(t, model: model) { return r }
        #if os(macOS)
        if let r = overlayCommand(t) { return r }
        if let r = await typing(t, raw: raw, model: model) { return r }
        if let r = await screen(t, raw: raw, model: model) { return r }
        if let r = access(t, model: model) { return r }
        if let r = await mails(t, model: model) { return r }
        if let r = await files(t, model: model) { return r }
        #endif
        return nil
    }

    // MARK: - Écran « Iron Man » (fermer, déplacer JARVIS)

    private static func stageCommand(_ t: String, model: AppModel) -> String? {
        guard model.stage != nil else { return nil }
        if t.range(of: #"^(ferme|enleve|retire|cache|quitte)( (ca|tout|la page|le site|l'image|la fenetre|le fichier|l'ecran))?$|^(retour|c'est bon|merci)$"#,
                   options: .regularExpression) != nil {
            model.closeStage()
            return "Très bien."
        }
        if let g = groups(t, #"(?:mets toi|va|place toi|deplace toi|positionne toi) (?:en |dans le coin )?(haut|bas) (?:a )?(gauche|droite)"#),
           g.count == 2 {
            let corner: StageCorner = g[0] == "haut" ? (g[1] == "gauche" ? .topLeading : .topTrailing)
                                                     : (g[1] == "gauche" ? .bottomLeading : .bottomTrailing)
            model.stageCorner = corner
            return "Je me place \(corner.label)."
        }
        return nil
    }

    // MARK: - Voix premium (« liste les voix », « prends la voix George »)

    private static var listedVoices: [PremiumVoice.Voice] = []

    private static func voiceCommand(_ t: String, model: AppModel) async -> String? {
        if t.range(of: #"^((liste|montre|donne)( moi)? (les |tes )?voix( disponibles)?|quelles? voix (as tu|il y a|sont disponibles))$"#,
                   options: .regularExpression) != nil {
            listedVoices = await PremiumVoice.listVoices()
            guard !listedVoices.isEmpty else { return "Je n'arrive pas à charger les voix pour le moment." }
            let lines = listedVoices.prefix(12).enumerated().map { (pair) -> String in
                "\(pair.offset + 1). \(pair.element.name)" + (pair.element.detail.isEmpty ? "" : " (\(pair.element.detail))")
            }
            return "Voix disponibles (actuelle : \(PremiumVoice.current.name)) : " + lines.joined(separator: " ; ")
                + ". Dites « prends la voix 2 » ou « prends la voix George »."
        }
        if let sel = firstGroup(t, #"^(?:prends|choisis|utilise|mets|passe sur|change pour) (?:la |ta )?voix (?:numero )?(.+)$|^change de voix (?:pour )?(.+)$"#) {
            if listedVoices.isEmpty { listedVoices = await PremiumVoice.listVoices() }
            var chosen: PremiumVoice.Voice? = nil
            if let n = Int(sel), n >= 1, n <= listedVoices.count {
                chosen = listedVoices[n - 1]
            } else {
                chosen = listedVoices.first { fold($0.name) == sel } ?? listedVoices.first { fold($0.name).contains(sel) }
                if chosen == nil { chosen = await PremiumVoice.listVoices(search: sel).first }
            }
            guard let v = chosen else { return "Je ne trouve pas la voix « \(sel) ». Dites « liste les voix »." }
            PremiumVoice.select(v)
            return "C'est fait, je parle maintenant avec la voix \(v.name)."
        }
        if t.range(of: #"^(voix haute qualite|meilleure voix)$"#, options: .regularExpression) != nil {
            PremiumVoice.highQuality = true
            return "Voix haute qualité activée."
        }
        if t == "voix rapide" {
            PremiumVoice.highQuality = false
            return "Voix rapide activée."
        }
        if t.range(of: #"^(voix standard|voix normale|reprends ta voix normale)$"#, options: .regularExpression) != nil {
            PremiumVoice.isEnabled = false
            return "Je repasse sur ma voix standard."
        }
        return nil
    }

    // MARK: - Notes (« note que… », « cherche dans mes notes… »)

    static var savedNotes: [String] { UserDefaults.standard.stringArray(forKey: "notes") ?? [] }

    private static func notes(_ raw: String, _ t: String, model: AppModel) -> String? {
        if let content = firstGroup(raw, #"^\s*(?:(?:ok |hey )?jarvis[ ,]+)?(?:note|prends note|prends en note|ajoute une note|nouvelle note)(?:\s+que|\s*:)?\s+(.{3,}?)[\s.!]*$"#) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = "d MMM"
            var list = savedNotes
            list.append("\(content) (\(f.string(from: Date())))")
            UserDefaults.standard.set(Array(list.suffix(300)), forKey: "notes")
            return "C'est noté."
        }
        if t.range(of: #"^(mes notes|lis mes notes|montre mes notes|quelles sont mes notes|lis moi mes notes)$"#,
                   options: .regularExpression) != nil {
            let list = savedNotes
            return list.isEmpty ? "Vous n'avez aucune note. Dites « note que… »."
                                : "Vos dernières notes : " + list.suffix(6).reversed().joined(separator: " ; ") + "."
        }
        if let key = firstGroup(t, #"^(?:cherche|retrouve|trouve)(?: moi)? (?:dans mes notes|la note|les notes|une note|ma note)(?: sur| a propos de| de| qui parle de| avec)? (.+)$"#) {
            let found = searchNotes(key)
            return found.isEmpty ? "Je ne trouve aucune note à ce sujet."
                                 : "J'ai trouvé : " + found.prefix(5).joined(separator: " ; ") + "."
        }
        if let key = firstGroup(t, #"^(?:supprime|efface|retire)(?: la| les)? notes? (?:sur |de |a propos de )?(.+)$"#) {
            let found = searchNotes(key)
            guard !found.isEmpty else { return "Je ne trouve aucune note à ce sujet." }
            model.localPending = LocalPending(label: "Supprimer \(found.count) note(s) sur « \(key) »") {
                let remaining = DeviceCommands.savedNotes.filter { !found.contains($0) }
                UserDefaults.standard.set(remaining, forKey: "notes")
                return "\(found.count) note(s) supprimée(s)."
            }
            return "Je supprime \(found.count) note\(found.count > 1 ? "s" : "") sur « \(key) ». Confirmez-vous ?"
        }
        return nil
    }

    private static func searchNotes(_ keyword: String) -> [String] {
        let words = fold(keyword).split(separator: " ").map(String.init).filter { $0.count > 2 }
        let keys = words.isEmpty ? [fold(keyword)] : words
        return savedNotes.reversed().filter { note in keys.allSatisfy { fold(note).contains($0) } }
    }

    // MARK: - Trajets et trafic (OpenStreetMap, sans clé)

    private static func travel(_ t: String, model: AppModel) async -> String? {
        if let g = groups(t, #"\b(?:trafic|bouchons?|embouteillages?)\b(?: (?:pour|vers|jusqu'a|jusqu'au|a) (?:aller )?(?:a |au |aux )?(.+))?"#) {
            let dest = g.first?.trimmingCharacters(in: CharacterSet(charactersIn: " ?")) ?? ""
            var comps = URLComponents(string: "https://www.google.com/maps/dir/")
            comps?.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "destination", value: dest),
                                 URLQueryItem(name: "travelmode", value: "driving")]
            let url = dest.isEmpty ? URL(string: "https://www.google.com/maps/@?api=1&map_action=map&layer=traffic")
                                   : comps?.url
            if let url { model.show(.web(url)) }
            return dest.isEmpty ? "Voici le trafic en temps réel autour de vous."
                                : "Voici l'itinéraire vers \(dest) avec le trafic en temps réel."
        }
        let pattern = #"^(?:quel(?: est le)? )?(?:temps de trajet|trajet|itineraire|distance)\b(.*)$|^(?:combien de temps|combien de (?:km|kilometres)|quelle distance|il faut combien de temps)(.*\b(?:pour aller|pour rejoindre|pour me rendre|jusqu'a|jusqu'au|jusqu'aux|d'ici a|en voiture|a pied|a velo|en velo)\b.*)$"#
        guard let rest = groups(t, pattern)?.first else { return nil }
        var r = rest.trimmingCharacters(in: CharacterSet(charactersIn: " ?"))
        var mode = "driving"
        if r.range(of: #"a pied|en marchant"#, options: .regularExpression) != nil { mode = "foot" }
        if r.range(of: #"velo|trottinette"#, options: .regularExpression) != nil { mode = "bike" }
        r = r.replacingOccurrences(of: #"\b(en voiture|a pied|en marchant|a velo|en velo|en trottinette)\b"#, with: "",
                                   options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " ?"))
        var origin: String? = nil
        if let g = groups(r, #"^(?:de|depuis|entre) (.+?) (?:a|au|aux|jusqu'a|jusqu'au|vers|et) (.+)$"#), g.count == 2 {
            origin = g[0]
            r = g[1]
        } else {
            r = r.replacingOccurrences(of: #"^(?:il faut |faut il )?(?:pour aller|pour rejoindre|pour me rendre|pour|jusqu'aux|jusqu'au|jusqu'a|d'ici a|vers|a|au|aux)\s+"#,
                                       with: "", options: .regularExpression)
            r = r.replacingOccurrences(of: #"^(?:a|au|aux)\s+"#, with: "", options: .regularExpression)
        }
        guard !r.isEmpty else { return "Où voulez-vous aller ?" }
        return await TravelService.route(to: r, from: origin, mode: mode, model: model)
    }

    // MARK: - Mémoire (« retiens que… »)

    static var memories: [String] { UserDefaults.standard.stringArray(forKey: "memories") ?? [] }

    private static func memory(_ raw: String, _ t: String, model: AppModel) -> String? {
        if let fact = firstGroup(raw, #"^\s*(?:(?:ok |hey )?jarvis[ ,]+)?(?:retiens|souviens[- ]toi|n['’]oublie pas|m[ée]morise|note bien)\s+(?:bien\s+)?(?:que\s+|qu['’])?(.{3,300}?)[\s.!]*$"#) {
            var list = memories
            list.append(fact)
            UserDefaults.standard.set(Array(list.suffix(100)), forKey: "memories")
            return "C'est noté, je m'en souviendrai."
        }
        if t.range(of: #"^(oublie tout|efface (ta|la) memoire)$"#, options: .regularExpression) != nil {
            UserDefaults.standard.removeObject(forKey: "memories")
            return "J'ai tout oublié."
        }
        if let what = firstGroup(t, #"^oublie (?:que |qu')?(.{3,})$"#) {
            let before = memories
            let after = before.filter { !fold($0).contains(what) }
            UserDefaults.standard.set(after, forKey: "memories")
            return before.count == after.count ? "Je n'avais rien retenu à ce sujet." : "C'est oublié."
        }
        if t.range(of: #"(que sais tu (de|sur) moi|qu'est ce que tu sais (de|sur) moi|tes souvenirs|ce que tu as retenu)"#,
                   options: .regularExpression) != nil {
            let list = memories
            return list.isEmpty ? "Vous ne m'avez encore rien demandé de retenir. Dites « retiens que… »."
                                : "Voici ce que j'ai retenu : " + list.suffix(10).joined(separator: " ; ") + "."
        }
        return nil
    }

    // MARK: - Sites web (affichés dans l'app)

    /// Sites connus : il suffit de dire « ouvre youtube », pas l'adresse complète.
    static let knownSites: [String: String] = [
        "youtube": "https://www.youtube.com", "you tube": "https://www.youtube.com", "google": "https://www.google.com",
        "netflix": "https://www.netflix.com", "twitch": "https://www.twitch.tv", "gmail": "https://mail.google.com",
        "wikipedia": "https://fr.wikipedia.org", "wikipedia en francais": "https://fr.wikipedia.org",
        "amazon": "https://www.amazon.fr", "twitter": "https://x.com", "x": "https://x.com",
        "instagram": "https://www.instagram.com", "insta": "https://www.instagram.com",
        "facebook": "https://www.facebook.com", "tiktok": "https://www.tiktok.com", "tik tok": "https://www.tiktok.com",
        "reddit": "https://www.reddit.com", "github": "https://github.com", "spotify": "https://open.spotify.com",
        "chatgpt": "https://chatgpt.com", "chat gpt": "https://chatgpt.com", "leboncoin": "https://www.leboncoin.fr",
        "le bon coin": "https://www.leboncoin.fr", "deezer": "https://www.deezer.com", "linkedin": "https://www.linkedin.com",
        "pinterest": "https://www.pinterest.fr", "snapchat": "https://web.snapchat.com", "whatsapp": "https://web.whatsapp.com",
        "whatsapp web": "https://web.whatsapp.com", "outlook": "https://outlook.live.com", "hotmail": "https://outlook.live.com",
        "google maps": "https://maps.google.com", "maps": "https://maps.google.com", "roblox": "https://www.roblox.com",
        "disney plus": "https://www.disneyplus.com", "disney+": "https://www.disneyplus.com",
        "prime video": "https://www.primevideo.com", "canal plus": "https://www.canalplus.com",
        "le monde": "https://www.lemonde.fr", "lequipe": "https://www.lequipe.fr", "l'equipe": "https://www.lequipe.fr",
        "meteo france": "https://meteofrance.com", "doctolib": "https://www.doctolib.fr", "ameli": "https://www.ameli.fr",
        "pronote": "https://www.index-education.com/fr/pronote-info191.php", "ecole directe": "https://www.ecoledirecte.com",
        "discord web": "https://discord.com/app", "steam": "https://store.steampowered.com", "epic games": "https://store.epicgames.com",
        "fnac": "https://www.fnac.com", "cdiscount": "https://www.cdiscount.com", "vinted": "https://www.vinted.fr",
    ]

    private static func website(_ t: String, model: AppModel) -> String? {
        var external = false
        var text = t
        if let r = text.range(of: #" (dans|sur|avec) (safari|chrome|le navigateur|mon navigateur|internet)$"#, options: .regularExpression) {
            external = true
            text.removeSubrange(r)
        }
        // « ouvre le site web de la fnac », « va sur youtube », « ouvre youtube.com », « ouvre youtube »
        var site = firstGroup(text, #"^(?:ouvre|affiche|montre(?: moi)?|lance|mets)(?: moi)? (?:le |un )?site(?: web| internet)?(?: de| du| des| d')? ?(.+)$"#)
            ?? firstGroup(text, #"^(?:va|vas|aller|allons) (?:sur|a) (?:le site (?:de |du |d')?)?(.+)$"#)
            ?? firstGroup(text, #"^(?:ouvre|lance|affiche|montre moi) ((?:www\.)?[a-z0-9-]+\.[a-z.]{2,}(?:/\S*)?)$"#)
        if site == nil, let w = firstGroup(text, #"^(?:ouvre|lance|affiche|montre moi|mets) (?:moi )?(.+)$"#),
           knownSites[w] != nil {
            #if os(macOS)
            if findApp(w) == nil { site = w }      // l'appli installée (Spotify, Steam…) reste prioritaire
            #else
            site = w
            #endif
        }
        guard let site, let url = siteURL(site) else { return nil }
        if external {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #endif
            return "J'ouvre \(siteLabel(site, url)) dans le navigateur."
        }
        model.show(.web(url))
        return "Voici \(siteLabel(site, url))."
    }

    private static func siteLabel(_ site: String, _ url: URL) -> String {
        if url.host?.contains("duckduckgo") == true { return site }
        return (url.host ?? site).replacingOccurrences(of: "www.", with: "")
    }

    /// Nom → adresse : site connu, adresse tapée, sinon le premier résultat de recherche (« J'ai de la chance »).
    static func siteURL(_ site: String) -> URL? {
        var s = site.trimmingCharacters(in: .whitespaces).lowercased()
        for art in ["le ", "la ", "les ", "l'"] where s.hasPrefix(art) && knownSites[s] == nil { s.removeFirst(art.count) }
        guard !s.isEmpty else { return nil }
        if let known = knownSites[s] { return URL(string: known) }
        if s.hasPrefix("http") { return URL(string: s) }
        let compact = s.replacingOccurrences(of: " ", with: "")
        if compact.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+(/\S*)?$"#, options: .regularExpression) != nil {
            return URL(string: "https://" + compact)
        }
        var comps = URLComponents(string: "https://duckduckgo.com/")
        comps?.queryItems = [URLQueryItem(name: "q", value: "!ducky " + s + " site officiel")]
        return comps?.url
    }

    // MARK: - Images (« montre-moi une image de… »)

    private static func imageCommand(_ t: String, model: AppModel) async -> String? {
        guard let q = firstGroup(t, #"^(?:montre(?: moi)?|affiche|trouve(?: moi)?|cherche(?: moi)?) (?:une |des |la |les |l')?(?:images?|photos?|illustrations?) (?:de |d'|du |des |de la |sur )?(.+)$"#)
        else { return nil }
        return await showImage(q, model: model)
    }

    /// Image libre de droits trouvée via Wikipédia ; sinon la recherche Wikimedia Commons s'affiche.
    @discardableResult
    static func showImage(_ query: String, model: AppModel) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "Quelle image voulez-vous voir ?" }
        if let found = await wikiImage(q) {
            model.show(.image(found.0, found.1))
            return "Voici « \(found.1) »."
        }
        var comps = URLComponents(string: "https://commons.wikimedia.org/w/index.php")
        comps?.queryItems = [URLQueryItem(name: "search", value: q), URLQueryItem(name: "title", value: "Special:MediaSearch"),
                             URLQueryItem(name: "type", value: "image")]
        if let url = comps?.url { model.show(.web(url)) }
        return "Voici des images de « \(q) »."
    }

    nonisolated static func wikiImage(_ q: String) async -> (URL, String)? {
        guard var comps = URLComponents(string: "https://fr.wikipedia.org/w/api.php") else { return nil }
        comps.queryItems = [URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
                            URLQueryItem(name: "srsearch", value: q), URLQueryItem(name: "srlimit", value: "3"),
                            URLQueryItem(name: "format", value: "json")]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("JARVIS-assistant/1.0", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: req),
              let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] else { return nil }
        let hits = (json["query"] as? [String: Any])?["search"] as? [[String: Any]] ?? []
        for hit in hits {
            guard let title = hit["title"] as? String,
                  let enc = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let sURL = URL(string: "https://fr.wikipedia.org/api/rest_v1/page/summary/" + enc) else { continue }
            var sReq = URLRequest(url: sURL, timeoutInterval: 8)
            sReq.setValue("JARVIS-assistant/1.0", forHTTPHeaderField: "User-Agent")
            guard let sResult = try? await URLSession.shared.data(for: sReq),
                  let sJSON = (try? JSONSerialization.jsonObject(with: sResult.0)) as? [String: Any] else { continue }
            let img = (sJSON["originalimage"] as? [String: Any])?["source"] as? String
                ?? (sJSON["thumbnail"] as? [String: Any])?["source"] as? String
            if let img, let imgURL = URL(string: img) { return (imgURL, title) }
        }
        return nil
    }

    // MARK: - Prénom

    private static func setName(_ raw: String, model: AppModel) -> String? {
        guard let name = firstGroup(raw, #"^\s*(?:(?:ok |hey )?jarvis[ ,]+)?(?:appelle[- ]moi|je m['’]appelle|mon (?:pr[ée])?nom (?:est|c['’]est))\s+(.{2,40}?)[\s.!?]*$"#)
        else { return nil }
        let pretty = name.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        model.setUserName(pretty)
        return "Enchanté, \(pretty). Je vous appellerai ainsi désormais."
    }

    // MARK: - Globe (God's Eye View)

    /// Aussi appelé avant l'envoi au PC : le globe s'affiche toujours sur cet appareil.
    static func globeCommand(_ t: String, model: AppModel) -> String? {
        let pattern = #"^(?:(?:ouvre|lance|affiche|montre(?: moi)?|active|demarre|ferme|quitte|arrete) )?"#
            + #"(?:le |la |les |l')?(?:globe|god'?s ?eye(?: view)?|vue (?:globale|satellite|du monde)|"#
            + #"terre en 3d|carte du monde|avions en direct|bateaux en direct|satellites en direct)$"#
        let asks = t.range(of: pattern, options: .regularExpression) != nil
        guard asks else { return nil }
        if t.range(of: #"^(ferme|quitte|arrete) "#, options: .regularExpression) != nil {
            model.globe.stop()
            if model.stage == .globe { model.closeStage() }
            if model.tab == .globe { model.tab = .accueil }
            return "Globe fermé."
        }
        model.show(.globe)
        #if os(macOS)
        return "Ouverture du globe : avions, bateaux, satellites, séismes et météo en direct."
        #else
        return "Le globe 3D fonctionne dans l'app Mac."
        #endif
    }

    // MARK: - Minuteurs et rappels

    private static let units: [String: Int] = ["seconde": 1, "secondes": 1, "sec": 1, "s": 1,
                                               "minute": 60, "minutes": 60, "min": 60, "mn": 60,
                                               "heure": 3600, "heures": 3600, "h": 3600]

    private static func number(_ s: String) -> Int? {
        let words = ["un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "sept": 7,
                     "huit": 8, "neuf": 9, "dix": 10, "quinze": 15, "vingt": 20, "trente": 30, "quarante": 40,
                     "cinquante": 50, "soixante": 60]
        return Int(s) ?? words[s]
    }

    private static func timers(_ t: String, model: AppModel) -> String? {
        let amount = #"(\d+|une?|deux|trois|quatre|cinq|six|sept|huit|neuf|dix|quinze|vingt|trente|quarante|cinquante|soixante) ?(secondes?|sec|minutes?|min|mn|heures?|h)\b"#
        if let g = groups(t, #"minuteur (?:de |d')?"# + amount + #"(?: pour (?:les |la |le )?(.+))?"#),
           let n = number(g[0]), let u = units[g[1]] {
            let label = g.count > 2 ? g[2] : ""
            model.startTimer(seconds: n * u, label: label, reminder: false)
            return "Minuteur de \(n) \(g[1]) lancé" + (label.isEmpty ? "." : " pour \(label).")
        }
        if let g = groups(t, #"rappelle moi dans "# + amount + #" (?:de |d'|qu'|que |pour )?(.+)$"#),
           let n = number(g[0]), let u = units[g[1]] {
            model.startTimer(seconds: n * u, label: g[2], reminder: true)
            return "C'est noté : je vous rappellerai dans \(n) \(g[1]) de \(g[2])."
        }
        if t.range(of: #"(annule|arrete|stoppe|supprime) (le |les |mon |mes )?(minuteur|rappel)"#, options: .regularExpression) != nil {
            let n = model.localTimers.count
            model.localTimers.removeAll()
            return n == 0 ? "Aucun minuteur en cours." : "J'ai annulé \(n == 1 ? "le minuteur" : "les \(n) minuteurs")."
        }
        if t.contains("combien de temps") || t.contains("temps restant") || t == "mes minuteurs" {
            guard !model.localTimers.isEmpty else { return "Aucun minuteur en cours." }
            return model.localTimers.map { (timer: LocalTimer) -> String in
                let left = max(0, Int(timer.end.timeIntervalSinceNow.rounded()))
                let txt = left >= 60 ? "\(left / 60) min \(String(format: "%02d", left % 60))" : "\(left) s"
                return (timer.label.isEmpty ? "Minuteur" : "« \(timer.label) »") + " : \(txt)"
            }.joined(separator: ". ") + "."
        }
        return nil
    }

    #if os(macOS)
    // MARK: - Mac : mails de l'app Mail (lecture seule, rien n'est marqué comme lu)

    struct MailItem {
        let sender: String
        let subject: String
        let body: String
    }

    private static var lastMails: [MailItem] = []

    private static func mails(_ t: String, model: AppModel) async -> String? {
        let listing = t.range(of: #"^((lis|lit|lire|montre|affiche|liste)( moi)? )?(mes|les|tous mes|mes derniers|mes nouveaux|nouveaux) (e ?)?mails?( importants?)?$|^(est ce que )?j'ai (des|de nouveaux) (e ?)?mails?$"#,
                              options: .regularExpression) != nil
        let reading = groups(t, #"^(lis|lit|lire|ouvre|resume)(?: moi)? (?:le |la |mon )?(?:(dernier|premier|deuxieme|troisieme|quatrieme|cinquieme) )?(?:e ?)?mails?(?: (?:numero |n )?(\d{1,2}))?(?: (?:de|d'|du|des|sur) ?(.+))?$"#)
        guard listing || reading != nil else { return nil }
        if listing || lastMails.isEmpty {
            guard let list = await fetchAppleMail() else {
                return "Je n'arrive pas à lire l'app Mail. Ouvrez Mail une fois (compte configuré), puis autorisez JARVIS "
                    + "dans Réglages › Confidentialité › Automatisation."
            }
            lastMails = list
            if listing {
                if list.isEmpty { return "Aucun mail non lu dans votre boîte de réception." }
                let lines = list.enumerated().map { (pair) -> String in
                    "\(pair.offset + 1). \(pair.element.sender) : \(pair.element.subject)"
                }
                return "\(list.count) mail\(list.count > 1 ? "s" : "") non lu\(list.count > 1 ? "s" : "") : "
                    + lines.joined(separator: " ; ") + ". Dites « lis le mail 1 » ou « lis le mail de … »."
            }
        }
        guard let g = reading else { return nil }
        let verb = g.first ?? "lis"
        let rest = Array(g.dropFirst())
        var mail: MailItem? = nil
        let ordinals = ["dernier": 1, "premier": 1, "deuxieme": 2, "troisieme": 3, "quatrieme": 4, "cinquieme": 5]
        if let first = rest.first, let n = Int(first) ?? ordinals[first] {
            mail = n >= 1 && n <= lastMails.count ? lastMails[n - 1] : nil
        } else if let who = rest.last, !who.isEmpty {
            var key = who
            for art in ["le ", "la ", "les ", "l'", "mon ", "ma "] where key.hasPrefix(art) { key.removeFirst(art.count) }
            mail = lastMails.first { fold($0.sender + " " + $0.subject).contains(key) }
        } else {
            mail = lastMails.first
        }
        guard let m = mail else { return "Je ne trouve pas ce mail parmi les non lus." }
        if verb.hasPrefix("resum") && m.body.count > 200 {
            let prompt = "Résume ce mail en 3 phrases, en français. De : \(m.sender). Objet : \(m.subject).\n\n" + m.body
            if let summary = try? await model.ai.chat(prompt, userName: model.userName) {
                return "Mail de \(m.sender) (\(m.subject)) : " + summary
            }
        }
        let body = m.body.isEmpty ? "Il n'a pas de texte." : String(m.body.prefix(1500))
        return "Mail de \(m.sender), objet : \(m.subject). " + body
    }

    /// Mails non lus de la boîte de réception de l'app Mail (8 au maximum), via AppleScript.
    static func fetchAppleMail() async -> [MailItem]? {
        let script = """
        tell application "Mail"
            set out to ""
            set msgs to (messages of inbox whose read status is false)
            set n to count of msgs
            if n > 8 then set n to 8
            repeat with i from 1 to n
                set m to item i of msgs
                set c to ""
                try
                    set c to content of m as string
                end try
                if length of c > 3000 then set c to text 1 thru 3000 of c
                set out to out & (sender of m) & "‖" & (subject of m) & "‖" & c & "⁂"
            end repeat
            return out
        end tell
        """
        let (out, status) = await runCaptureStatus("/usr/bin/osascript", ["-e", script])
        if status != 0 { return nil }          // Mail non configuré ou accès refusé
        if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        return out.components(separatedBy: "⁂").compactMap { chunk in
            let f = chunk.components(separatedBy: "‖")
            guard f.count >= 3 else { return nil }
            var sender = f[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if let lt = sender.firstIndex(of: "<"), lt > sender.startIndex {
                sender = String(sender[..<lt]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            }
            let body = f[2].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MailItem(sender: sender, subject: f[1].trimmingCharacters(in: .whitespacesAndNewlines), body: body)
        }
    }

    // MARK: - Mac : fichiers (recherche, ouverture, lecture, résumé). Jamais de suppression.

    private static let folders: [(key: String, name: String, dir: FileManager.SearchPathDirectory)] = [
        ("telechargements", "Téléchargements", .downloadsDirectory),
        ("bureau", "Bureau", .desktopDirectory),
        ("documents", "Documents", .documentDirectory),
    ]

    private static func files(_ t: String, model: AppModel) async -> String? {
        stageModel = model
        // Dossiers : « mes téléchargements », « qu'y a-t-il sur mon bureau », « ouvre mes documents »
        if let g = groups(t, #"^(ouvre |montre moi |montre |liste |affiche |qu'y a t il (?:dans|sur) |quoi de neuf (?:dans|sur) )?"#
                            + #"(?:mes |mon |le |les )?(?:derniers? |fichiers? (?:du |des |de mes |dans mes )?)?(telechargements|bureau|documents)$"#),
           let key = g.last, let folder = folders.first(where: { $0.key == key }),
           let dir = FileManager.default.urls(for: folder.dir, in: .userDomainMask).first {
            if g.count > 1 && g[0].hasPrefix("ouvre") {
                NSWorkspace.shared.open(dir)
                return "J'ouvre le dossier \(folder.name)."
            }
            let items = recentFiles(in: dir)
            model.lastFiles = items
            if items.isEmpty { return "Le dossier \(folder.name) est vide (ou je n'y ai pas encore accès : acceptez la demande d'autorisation)." }
            return "Derniers éléments de \(folder.name) : " + describe(items) + " Dites « ouvre le 1 » ou « résume le 2 »."
        }
        // « ouvre le 2 », « résume le 1 » (après une recherche ou une liste)
        if let g = groups(t, #"^(ouvre|resume|lis|analyse) (?:le |la )?(?:fichier |resultat |numero |n )?(\d{1,2})$"#),
           let n = Int(g[1]) {
            guard n >= 1, n <= model.lastFiles.count else { return "Je n'ai pas de fichier numéro \(n). Lancez d'abord une recherche." }
            let url = model.lastFiles[n - 1]
            if g[0] == "ouvre" { return open(url) }
            return await summarize(url, model: model)
        }
        // « résume le fichier rapport », « que contient le document facture »
        if let q = firstGroup(t, #"^(?:resume(?: moi)?|lis(?: moi)?|analyse|que contient|qu'y a t il dans) (?:le |la |mon |ma )?(?:fichier|document|pdf) (.+)$"#) {
            let found = await searchFiles(q)
            model.lastFiles = found
            guard let first = found.first else { return "Je ne trouve aucun fichier contenant « \(q) » dans son nom." }
            return await summarize(first, model: model)
        }
        // « ouvre le fichier rapport »
        if let q = firstGroup(t, #"^ouvre (?:le |la |mon |ma )?(?:fichier|document|pdf|photo|dossier) (.+)$"#) {
            let found = await searchFiles(q)
            model.lastFiles = found
            guard let first = found.first else { return "Je ne trouve aucun fichier « \(q) »." }
            return open(first)
        }
        // « cherche le fichier facture », « où est mon document CV », « trouve mes photos de vacances »
        if let q = firstGroup(t, #"^(?:cherche|trouve|recherche|ou est|ou se trouve|ou sont)(?: moi)? (?:le |la |les |un |une |mon |ma |mes )?(?:fichiers?|documents?|dossiers?|photos?|pdf|images?) (?:de |du |des |sur |nomme |appele )?(.+)$"#) {
            let found = await searchFiles(q)
            model.lastFiles = found
            if found.isEmpty { return "Je ne trouve aucun fichier contenant « \(q) » dans son nom." }
            return "J'ai trouvé \(found.count) élément\(found.count > 1 ? "s" : "") : " + describe(found)
                + " Dites « ouvre le 1 » ou « résume le 1 »."
        }
        return nil
    }

    private static func describe(_ urls: [URL]) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM"
        return urls.enumerated().map { (pair) -> String in
            let (i, url) = pair
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { f.string(from: $0) }
            return "\(i + 1). \(url.lastPathComponent) (\(url.deletingLastPathComponent().lastPathComponent)\(date.map { ", " + $0 } ?? ""))"
        }.joined(separator: " ; ") + "."
    }

    private static func recentFiles(in dir: URL, limit: Int = 8) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return Array(items.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }.prefix(limit))
    }

    /// Recherche Spotlight dans le dossier de l'utilisateur (nom de fichier, sans accents ni majuscules).
    static func searchFiles(_ query: String, limit: Int = 8) async -> [URL] {
        let q = query.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let home = NSHomeDirectory()
        let out = await runCapture("/usr/bin/mdfind", ["-onlyin", home, "kMDItemFSName == \"*\(q)*\"cd"])
        let urls = out.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }.filter { u in
            let p = u.path
            return !p.hasPrefix(home + "/Library") && !p.contains("/.") && !p.contains(".app/")
                && !p.contains("/node_modules/")
        }
        return Array(urls.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }.prefix(limit))
    }

    private static let viewable: Set<String> = ["pdf", "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg",
                                                "txt", "md", "html", "htm", "json", "csv", "log", "mp4", "mov", "m4v", "mp3", "m4a"]

    private static var stageModel: AppModel?

    private static func open(_ url: URL) -> String {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue, viewable.contains(url.pathExtension.lowercased()), let model = stageModel {
            model.show(.file(url))
            return "Voici « \(url.lastPathComponent) »."
        }
        NSWorkspace.shared.open(url)
        return "J'ouvre « \(url.lastPathComponent) »."
    }

    // MARK: - Mac : accès complet et actions administrateur

    private static func access(_ t: String, model: AppModel) -> String? {
        if t.range(of: #"(acces (complet|total|a tous mes fichiers|a tout|au disque)|full disk|autorise toi|donne toi (l'acces|acces))"#,
                   options: .regularExpression) != nil {
            openFullDiskAccessSettings()
            return "J'ouvre Réglages › Confidentialité › Accès complet au disque. Ajoutez JARVIS (bouton +, puis "
                + "Applications › JARVIS) et activez-le : je pourrai alors lire tous vos fichiers quand vous me le demandez."
        }
        if t.range(of: #"(es tu|t'es|tu es) (administrateur|admin)|droits? (admin|administrateur)|session admin"#,
                   options: .regularExpression) != nil {
            return "Sur Mac, je n'ai pas les droits administrateur en permanence : pour une action qui en a besoin "
                + "(vider le cache DNS, libérer la mémoire), macOS vous demande votre mot de passe, que je ne vois "
                + "ni ne garde jamais. Dites par exemple « vide le cache DNS »."
        }
        if t.range(of: #"(vide|purge|nettoie|reinitialise) (le )?(cache )?dns"#, options: .regularExpression) != nil {
            model.localPending = LocalPending(label: "Vider le cache DNS (mot de passe administrateur)") {
                DeviceCommands.runAdmin("dscacheutil -flushcache; killall -HUP mDNSResponder")
                    ? "Cache DNS vidé." : "Action annulée ou refusée."
            }
            return "Je vide le cache DNS ; macOS va demander votre mot de passe. Confirmez-vous ?"
        }
        if t.range(of: #"(libere|purge|vide|nettoie) (la )?(memoire|ram)"#, options: .regularExpression) != nil {
            model.localPending = LocalPending(label: "Libérer la mémoire (mot de passe administrateur)") {
                DeviceCommands.runAdmin("purge") ? "Mémoire libérée." : "Action annulée ou refusée."
            }
            return "Je libère la mémoire inutilisée ; macOS va demander votre mot de passe. Confirmez-vous ?"
        }
        return nil
    }

    // MARK: - Mac : musique

    private static func music(_ t: String) -> String? {
        if t.range(of: #"^(mets|lance|joue)( moi)? (de la |un peu de )?musique$"#, options: .regularExpression) != nil {
            runAppleScript("tell application \"Music\" to play")
            return "Je lance la musique."
        }
        if t.range(of: #"^(pause|mets en pause|arrete la musique|coupe la musique|stop la musique)$"#, options: .regularExpression) != nil {
            runAppleScript("tell application \"Music\" to pause")
            runAppleScript("if application \"Spotify\" is running then tell application \"Spotify\" to pause")
            return "Musique en pause."
        }
        if t.range(of: #"^(chanson suivante|musique suivante|suivant|next)$"#, options: .regularExpression) != nil {
            runAppleScript("if application \"Spotify\" is running then tell application \"Spotify\" to next track")
            runAppleScript("if application \"Music\" is running then tell application \"Music\" to next track")
            return "Suivante."
        }
        guard let what = firstGroup(t, #"^(?:lance|mets|joue|ecoute)(?: moi)? (?:ma |la |une )?(?:playlist|chanson|album|son|musique) (.+)$|^(?:joue|ecoute) (.+)$"#)
        else { return nil }
        let safe = what.replacingOccurrences(of: "\"", with: "")
        if runAppleScriptOK("tell application \"Music\" to play playlist \"\(safe)\"") {
            return "Je lance la playlist « \(what) »."
        }
        let query = what.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? what
        if let uri = URL(string: "spotify:search:" + query), NSWorkspace.shared.urlForApplication(toOpen: uri) != nil {
            NSWorkspace.shared.open(uri)
            return "J'ouvre « \(what) » dans Spotify : lancez la lecture d'un clic."
        }
        if let url = URL(string: "https://music.youtube.com/search?q=" + query) { NSWorkspace.shared.open(url) }
        return "J'ouvre « \(what) » sur YouTube Music."
    }

    // MARK: - Mac : routines (« bonne nuit », « je pars », « je rentre »)

    private static func macRoutine(_ t: String, model: AppModel) -> String? {
        if t.range(of: #"^(bonne nuit|je vais dormir|je vais me coucher)$"#, options: .regularExpression) != nil {
            guard model.hub.isRoutineEnabled("bonne nuit") else { return "La routine « bonne nuit » est désactivée." }
            runAppleScript("set volume output volume 10")
            model.closeStage()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { DeviceCommands.runTool("/usr/bin/pmset", ["displaysleepnow"]) }
            return "Bonne nuit, \(model.userName). Je baisse le son et j'éteins l'écran."
        }
        if t.range(of: #"^(je pars|j'y vais|je sors|je m'en vais|a plus)$"#, options: .regularExpression) != nil {
            guard model.hub.isRoutineEnabled("je pars") else { return "La routine « je pars » est désactivée." }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { DeviceCommands.runTool("/usr/bin/pmset", ["displaysleepnow"]) }
            return "Bonne journée. J'éteins l'écran : votre mot de passe sera demandé au retour."
        }
        if t.range(of: #"^(je rentre|je suis rentre|me revoila|je suis la)$"#, options: .regularExpression) != nil {
            return "Bon retour, \(model.userName). " + model.localSummary()
        }
        return nil
    }

    // MARK: - Mac : mini-JARVIS flottant

    private static func overlayCommand(_ t: String) -> String? {
        if OverlayController.shared.isVisible,
           t.range(of: #"^(c'est bon|c'est tout|merci|merci beaucoup|ok merci|ferme toi|cache toi|disparais|a plus|au revoir|bonne nuit|tu peux partir|laisse moi)$"#,
                   options: .regularExpression) != nil {
            OverlayController.shared.hide()
            return "Très bien, je reste à l'écoute."
        }
        if t.range(of: #"^(montre toi|affiche toi|ouvre ta fenetre|ouvre jarvis|grande fenetre|plein ecran)$"#,
                   options: .regularExpression) != nil {
            MacShell.showMainWindow()
            return "Me voilà."
        }
        return nil
    }

    // MARK: - Mac : écrire à la place de l'utilisateur

    private static func typing(_ t: String, raw: String, model: AppModel) async -> String? {
        guard t.range(of: #"^(ecris|ecrit|tape|redige|ecrire)( moi| pour moi)? "#, options: .regularExpression) != nil else {
            return nil
        }
        let composes = t.range(of: #"^(ecris|ecrit|tape|redige)( moi| pour moi)? (moi )?(un|une|la|le) (message|mail|e mail|email|texte|reponse|sms|paragraphe|lettre|post|tweet|commentaire|resume|description|introduction|conclusion|discours|poeme|histoire)\b"#,
                               options: .regularExpression) != nil
        let text: String
        if composes {
            do {
                text = try await model.ai.compose(raw, userName: model.userName)
            } catch {
                return "Je n'ai pas réussi à rédiger ce texte."
            }
        } else if let literal = firstGroup(raw, #"^\s*(?:(?:ok |hey )?jarvis[ ,]+)?(?:[ée]cris|[ée]crit|tape)(?: moi| pour moi)?\s*:?\s+(.+?)\s*$"#) {
            text = literal
        } else {
            return nil
        }
        guard !text.isEmpty else { return "Il n'y a rien à écrire." }
        if await Typist.type(text) {
            return composes ? "C'est écrit. Relisez avant d'envoyer." : "C'est tapé."
        }
        return "Pour écrire à votre place, autorisez JARVIS dans Réglages › Confidentialité et sécurité › Accessibilité "
            + "(la fenêtre vient de s'ouvrir), puis redemandez."
    }

    // MARK: - Mac : voir l'écran (capture analysée par l'IA, à la demande, rien n'est gardé)

    private static func screen(_ t: String, raw: String, model: AppModel) async -> String? {
        let pattern = #"((analyse|regarde|decris|lis|explique|observe|scanne)( moi)? (ce qu'il y a (sur|a) )?(mon |l'|cet )?ecran|"#
            + #"(que vois tu|qu'est ce que tu vois|qu'est ce qu'il y a|tu vois quoi) (sur|a) (mon |l')?ecran|"#
            + #"aide moi avec (ce qui est sur )?(mon |l')?ecran|c'est quoi (ce message|cette erreur|ca) (sur|a) (mon |l')?ecran)"#
        guard t.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let path = NSTemporaryDirectory() + "jarvis-ecran-\(UUID().uuidString).jpg"
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = await runCaptureStatus("/usr/sbin/screencapture", ["-x", "-t", "jpg", path])
        guard FileManager.default.fileExists(atPath: path) else {
            openScreenRecordingSettings()
            return "Je n'ai pas encore le droit de voir votre écran. J'ouvre Réglages › Confidentialité › "
                + "Enregistrement de l'écran : activez JARVIS, relancez-moi, puis redemandez."
        }
        _ = await runCaptureStatus("/usr/bin/sips", ["-Z", "1600", path])   // image plus légère
        guard let data = FileManager.default.contents(atPath: path), data.count > 1000 else {
            return "La capture d'écran a échoué."
        }
        let question = raw.count > 25 ? raw : "Explique ce qui apparaît sur cet écran."
        do {
            return try await model.ai.describeImage(data, question: question)
        } catch {
            return "Je n'arrive pas à analyser l'écran pour le moment."
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Commande prévue à l'avance, exécutée avec les droits administrateur : macOS demande le mot de passe.
    @discardableResult
    static func runAdmin(_ command: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        let ok = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
            .executeAndReturnError(&error) != nil
        return ok && error == nil
    }

    private static func summarize(_ url: URL, model: AppModel) async -> String {
        guard let text = readText(url)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return "Je ne sais pas lire « \(url.lastPathComponent) » (formats lus : texte, PDF, Word, RTF, HTML, code)."
        }
        let prompt = "Résume en français, en 5 à 8 phrases claires, le document « \(url.lastPathComponent) » "
            + "ci-dessous, en commençant par l'idée principale. N'ajoute rien qui n'y figure pas.\n\n---\n"
            + String(text.prefix(12000))
        do {
            return try await model.ai.chat(prompt, userName: model.userName)
        } catch {
            return "Je n'arrive pas à résumer ce fichier : \(error.localizedDescription)"
        }
    }

    static func readText(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { return nil }
            var out = ""
            for i in 0..<min(doc.pageCount, 40) { out += (doc.page(at: i)?.string ?? "") + "\n" }
            return out
        }
        if ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive"].contains(ext) {
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        let textExts = ["txt", "md", "csv", "json", "log", "py", "swift", "js", "ts", "html", "css", "yaml", "yml",
                        "xml", "sh", "c", "cpp", "h", "java", "kt", "go", "rs", "php", "rb", "sql", "ini", "toml", ""]
        guard textExts.contains(ext) else { return nil }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
    }

    nonisolated static func runCaptureStatus(_ path: String, _ args: [String]) async -> (String, Int32) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: ("", -1)); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (String(decoding: data, as: UTF8.self), p.terminationStatus))
            }
        }
    }

    nonisolated static func runCapture(_ path: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: ""); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    // MARK: - Mac : applis, sites, volume, veille

    private static func mac(_ t: String, model: AppModel) -> String? {
        if let r = music(t) { return r }
        if let r = macRoutine(t, model: model) { return r }

        if let what = firstGroup(t, #"^(?:ouvre|lance|demarre|execute) (?:l'application |l'appli |le logiciel |le programme )?(.+)$"#) {
            if findApp(what) == nil, !t.contains("application"), let url = siteURL(what) {
                model.show(.web(url))      // pas d'appli de ce nom : on ouvre le site
                return "Je n'ai pas d'application « \(what) », voici le site."
            }
            return openApp(what)
        }
        if let what = firstGroup(t, #"^(?:ferme|quitte|arrete) (?:l'application |l'appli |le logiciel |le programme )?(.+)$"#) {
            return quitApp(what, model: model)
        }
        // Volume
        if let v = firstGroup(t, #"(?:mets |regle )?(?:le )?(?:volume|son) a (\d{1,3})"#), let n = Int(v) {
            setVolume(min(100, n)); return "Volume réglé à \(min(100, n)) %."
        }
        if t.range(of: #"(monte|augmente|plus fort)"#, options: .regularExpression) != nil
            && t.range(of: #"(son|volume|fort)"#, options: .regularExpression) != nil {
            let v = min(100, currentVolume() + 12); setVolume(v); return "Volume à \(v) %."
        }
        if t.range(of: #"(baisse|diminue|moins fort)"#, options: .regularExpression) != nil
            && t.range(of: #"(son|volume|fort)"#, options: .regularExpression) != nil {
            let v = max(0, currentVolume() - 12); setVolume(v); return "Volume à \(v) %."
        }
        if t.range(of: #"^(coupe le son|mute|silence|mets en sourdine)$"#, options: .regularExpression) != nil {
            runAppleScript("set volume with output muted"); return "Son coupé."
        }
        if t.range(of: #"^(remets le son|reactive le son|unmute)$"#, options: .regularExpression) != nil {
            runAppleScript("set volume without output muted"); return "Son rétabli."
        }
        // Veille
        if t.range(of: #"^(?:mets (?:le mac |l'ordinateur |l'ordi )?en veille|veille|mode veille)$"#, options: .regularExpression) != nil {
            model.localPending = LocalPending(label: "Mettre le Mac en veille") {
                DeviceCommands.runTool("/usr/bin/pmset", ["sleepnow"])
                return "Mise en veille."
            }
            return "Je mets le Mac en veille. Confirmez-vous ?"
        }
        if t.range(of: #"^(?:verrouille|eteins l'ecran|ecran en veille)"#, options: .regularExpression) != nil {
            runTool("/usr/bin/pmset", ["displaysleepnow"])
            return "Écran mis en veille."
        }
        // État du Mac
        if t.range(of: #"(etat|sante|statut) (du|de l') ?(mac|ordinateur|ordi|pc)"#, options: .regularExpression) != nil
            || t == "fais le point" {
            return model.localSummary()
        }
        return nil
    }

    private static let appAliases: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome", "vscode": "Visual Studio Code",
        "vs code": "Visual Studio Code", "visual studio": "Visual Studio Code", "musique": "Music",
        "calculatrice": "Calculator", "calculette": "Calculator", "reglages": "System Settings",
        "parametres": "System Settings", "preferences systeme": "System Settings", "plans": "Maps",
        "calendrier": "Calendar", "rappels": "Reminders", "apercu": "Preview", "contacts": "Contacts",
        "moniteur d'activite": "Activity Monitor", "gestionnaire des taches": "Activity Monitor",
        "l'app store": "App Store", "word": "Microsoft Word", "excel": "Microsoft Excel",
        "powerpoint": "Microsoft PowerPoint", "teams": "Microsoft Teams", "le terminal": "Terminal",
        "le finder": "Finder", "photo": "Photos", "appareil photo": "Photo Booth",
    ]

    static func findApp(_ query: String) -> URL? {
        let q = fold(query)
        let target = fold(appAliases[q] ?? q)
        if target == "finder" { return URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app") }
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var partial: URL?
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                let names = [fold(String(item.dropLast(4))),
                             fold(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))]
                if names.contains(target) { return url }
                if partial == nil && names.contains(where: { $0.hasPrefix(target) || $0.contains(target) }) { partial = url }
            }
        }
        return partial
    }

    private static func openApp(_ name: String) -> String {
        guard let url = findApp(name) else {
            return "Je ne trouve pas l'application « \(name) » sur ce Mac."
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        return "J'ouvre \(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))."
    }

    private static func quitApp(_ name: String, model: AppModel) -> String {
        let q = fold(appAliases[fold(name)] ?? name)
        let me = Bundle.main.bundleIdentifier
        guard let app = NSWorkspace.shared.runningApplications.first(where: { app in
            app.activationPolicy == .regular && app.bundleIdentifier != me
                && fold(app.localizedName ?? "").contains(q)
        }) else {
            return "L'application « \(name) » n'est pas ouverte."
        }
        let label = app.localizedName ?? name
        model.localPending = LocalPending(label: "Fermer \(label)") {
            app.terminate() ? "\(label) est fermé." : "\(label) refuse de se fermer."
        }
        return "Je ferme \(label). Confirmez-vous ?"
    }

    // MARK: - Outils système

    /// Vrai si le script s'est exécuté sans erreur.
    @discardableResult
    private static func runAppleScriptOK(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return result != nil && error == nil
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return result?.stringValue
    }

    private static func currentVolume() -> Int {
        Int(runAppleScript("output volume of (get volume settings)") ?? "") ?? 50
    }

    private static func setVolume(_ v: Int) {
        runAppleScript("set volume without output muted")
        runAppleScript("set volume output volume \(max(0, min(100, v)))")
    }

    nonisolated static func runTool(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }
    #endif

    // MARK: - Utilitaires

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Groupes capturés (les groupes absents sont ignorés).
    static func groups(_ text: String, _ pattern: String) -> [String]? {
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        var out: [String] = []
        for i in 1..<max(1, m.numberOfRanges) {
            if let r = Range(m.range(at: i), in: text) {
                out.append(String(text[r]).trimmingCharacters(in: .whitespaces))
            }
        }
        return out
    }

    static func firstGroup(_ text: String, _ pattern: String) -> String? {
        groups(text, pattern)?.first
    }
}

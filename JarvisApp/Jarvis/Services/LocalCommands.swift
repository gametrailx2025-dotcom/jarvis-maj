import Foundation
#if os(macOS)
import AppKit
#endif

/// Fonctions du PC reproduites sur ce Mac / iPhone : tâches, rendez-vous, courses, briefing, routines,
/// et sur Mac l'entretien (corbeille, caches, DNS, réseau, mises à jour, redémarrage…).
@MainActor
enum LocalCommands {
    typealias D = DeviceCommands

    static func handle(_ t: String, raw: String, model: AppModel) async -> String? {
        if let r = organizer(t, raw: raw, model: model) { return r }
        if let r = await briefing(t, model: model) { return r }
        if let r = await HomeAssistant.voice(t, devices: model.home?.devices ?? []) { return r }
        if let r = await TuyaCloud.voice(t, devices: model.home?.devices ?? []) { return r }
        #if os(macOS)
        if let r = await maintenance(t, model: model) { return r }
        if let r = modes(t, model: model) { return r }
        #endif
        return nil
    }

    // MARK: - Tâches, rendez-vous, courses

    private static func organizer(_ t: String, raw: String, model: AppModel) -> String? {
        let hub = model.hub
        // Tâches
        if let what = D.firstGroup(t, #"^(?:ajoute|note|cree|mets)(?: (?:une|la|a la liste des|dans mes))? taches? (?:de |d'|: )?(.+)$"#)
            ?? D.firstGroup(t, #"^(?:ajoute|note) (.+?) (?:a|dans) (?:mes|la liste des) taches$"#) {
            guard let item = hub.addTask(original(raw, what)) else { return nil }
            model.loadLocal()
            return "Tâche ajoutée : « \(item.title) »."
        }
        if t.range(of: #"^(?:quelles sont |c'est quoi |lis |liste |donne moi )?(?:mes|les) taches"#, options: .regularExpression) != nil
            || t == "qu'est ce que j'ai a faire" {
            let list = hub.tasks
            if list.isEmpty { return "Aucune tâche en attente." }
            return "Vous avez \(list.count) tâche\(list.count > 1 ? "s" : "") : " + list.prefix(8).map(\.title).joined(separator: ", ") + "."
        }
        if let what = D.firstGroup(t, #"^(?:j'ai (?:fini|termine|fait)|termine|coche|supprime la tache|enleve la tache) (?:la tache )?(.+)$"#),
           let done = hub.completeTask(matching: what) {
            model.loadLocal()
            return "Bravo, « \(done.title) » est terminée."
        }
        // Courses
        if let what = D.firstGroup(t, #"^(?:ajoute|mets|rajoute) (.+?) (?:a|dans|sur) (?:la|ma) liste(?: de courses| des courses)?$"#) {
            let items = what.components(separatedBy: CharacterSet(charactersIn: ",")).flatMap { $0.components(separatedBy: " et ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            items.forEach { hub.addShopping(original(raw, $0)) }
            model.loadLocal()
            return items.count == 1 ? "« \(items[0]) » ajouté à la liste de courses." : "\(items.count) articles ajoutés à la liste de courses."
        }
        if let what = D.firstGroup(t, #"^(?:enleve|retire|supprime) (.+?) (?:de|sur) (?:la|ma) liste(?: de courses| des courses)?$"#) {
            let ok = hub.removeShopping(matching: what)
            model.loadLocal()
            return ok ? "« \(what) » retiré de la liste." : "« \(what) » n'est pas sur la liste."
        }
        if t.range(of: #"^(?:vide|efface) (?:la|ma) liste(?: de courses| des courses)?$"#, options: .regularExpression) != nil {
            hub.clearShopping()
            model.loadLocal()
            return "Liste de courses vidée."
        }
        if t.range(of: #"(?:qu'est ce qu'il y a sur|lis|donne moi|c'est quoi) (?:la|ma) liste(?: de courses| des courses)?$"#,
                   options: .regularExpression) != nil || t == "la liste de courses" || t == "ma liste de courses" {
            let list = hub.shopping
            return list.isEmpty ? "La liste de courses est vide." : "Sur la liste : " + list.map(\.item).joined(separator: ", ") + "."
        }
        // Rendez-vous : « ajoute un rendez-vous dentiste demain à 14 h 30 »
        if let g = D.groups(t, #"^(?:ajoute|note|cree|mets)(?: moi)? un (?:rendez vous|rdv|evenement) (?:de |pour |: )?(.+?) (aujourd'hui|demain|apres demain|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)(?: a (\d{1,2})(?: ?h ?| heures? ?)?(\d{2})?)?$"#) {
            guard let date = dateFrom(day: g[1], hour: g.count > 2 ? g[2] : "", minute: g.count > 3 ? g[3] : "") else { return nil }
            let allDay = g.count < 3 || g[2].isEmpty
            hub.addEvent(original(raw, g[0]).capitalizedFirst, start: date, allDay: allDay)
            model.loadLocal()
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = allDay ? "EEEE d MMMM" : "EEEE d MMMM 'à' HH'h'mm"
            return "Rendez-vous « \(g[0]) » noté pour \(f.string(from: date))."
        }
        if t.range(of: #"(?:mes |les )?(?:rendez vous|rdv|agenda|evenements)(?: d'aujourd'hui| de demain| a venir)?$"#,
                   options: .regularExpression) != nil, t.count < 40 {
            let next = hub.upcomingEvents.prefix(5)
            if next.isEmpty { return "Aucun rendez-vous à venir." }
            let f = DateFormatter()
            f.locale = Locale(identifier: "fr_FR")
            f.dateFormat = "EEEE 'à' HH'h'mm"
            return "À venir : " + next.map { "\($0.title), \(f.string(from: $0.start))" }.joined(separator: " ; ") + "."
        }
        return nil
    }

    /// Reprend le texte d'origine (avec accents et majuscules) correspondant à un morceau normalisé.
    private static func original(_ raw: String, _ folded: String) -> String {
        let words = raw.split(separator: " ").map(String.init)
        let target = folded.split(separator: " ").count
        guard target > 0, words.count >= target else { return folded }
        for start in 0...(words.count - target) {
            let slice = words[start..<(start + target)].joined(separator: " ")
            if LocalBrain.normalize(slice) == folded { return slice.trimmingCharacters(in: .punctuationCharacters) }
        }
        return folded
    }

    private static func dateFrom(day: String, hour: String, minute: String) -> Date? {
        let cal = Calendar.current
        var base = cal.startOfDay(for: Date())
        let days = ["dimanche": 1, "lundi": 2, "mardi": 3, "mercredi": 4, "jeudi": 5, "vendredi": 6, "samedi": 7]
        switch day {
        case "aujourd'hui": break
        case "demain": base = cal.date(byAdding: .day, value: 1, to: base)!
        case "apres demain": base = cal.date(byAdding: .day, value: 2, to: base)!
        default:
            guard let wd = days[day] else { return nil }
            var comps = DateComponents()
            comps.weekday = wd
            base = cal.nextDate(after: base, matching: comps, matchingPolicy: .nextTime) ?? base
        }
        let h = Int(hour) ?? 9
        let m = Int(minute) ?? 0
        return cal.date(bySettingHour: min(h, 23), minute: min(m, 59), second: 0, of: base)
    }

    // MARK: - Briefing complet (comme sur le PC)

    private static func briefing(_ t: String, model: AppModel) async -> String? {
        guard t == "debout" || t.contains("briefing") || t == "ma journee" || t.contains("que dois je faire")
            || t.contains("au rapport") else { return nil }
        guard model.hub.isRoutineEnabled("briefing du matin") || !t.contains("briefing") else {
            return "La routine « briefing du matin » est désactivée."
        }
        await model.refreshWeather()
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM, HH'h'mm"
        var s = ["\(model.greetingWord()) \(model.userName). Nous sommes \(f.string(from: Date()))."]
        if let w = model.weather?.spoken { s.append(w) }
        let agenda = model.hub.agenda
        if agenda.events.isEmpty {
            s.append("Aucun rendez-vous aujourd'hui.")
        } else {
            s.append("Aujourd'hui : " + agenda.events.map { "\($0.title) \($0.all_day == true ? "" : "à " + $0.timeLabel)" }
                .joined(separator: ", ") + ".")
        }
        if !agenda.tasks.isEmpty {
            s.append("\(agenda.tasks.count) tâche\(agenda.tasks.count > 1 ? "s" : "") en attente, dont « \(agenda.tasks[0].title) ».")
        }
        if let m = model.mail, m.configured, !m.items.isEmpty {
            s.append("\(m.items.count) mail\(m.items.count > 1 ? "s" : "") important\(m.items.count > 1 ? "s" : "") non lu\(m.items.count > 1 ? "s" : "").")
        }
        if let st = model.local.stats {
            s.append("\(model.local.deviceName.capitalizedFirst) : santé \(st.health.score) sur 100.")
        }
        return s.joined(separator: " ")
    }

    #if os(macOS)
    // MARK: - Mac : entretien (les actions qui suppriment ou redémarrent demandent confirmation)

    private static let machine = #"(?:le |mon |l')?(?:mac|pc|ordinateur|ordi)"#

    private static func maintenance(_ t: String, model: AppModel) async -> String? {
        if t.range(of: #"^(?:optimise|analyse|accelere) "# + machine, options: .regularExpression) != nil
            || t == "analyse express" {
            return await analyze(model: model)
        }
        if t.range(of: #"^(?:vide|videz) (?:la )?corbeille$"#, options: .regularExpression) != nil {
            model.localPending = LocalPending(label: "Vider définitivement la corbeille") {
                applescript(#"tell application "Finder" to empty trash"#) ? "Corbeille vidée." : "Je n'ai pas pu vider la corbeille (autorisez JARVIS à contrôler le Finder)."
            }
            return "Je vide définitivement la corbeille. Confirmez-vous ?"
        }
        if t.range(of: #"^(?:nettoie|supprime|efface) (?:les )?(?:fichiers temporaires|caches?|fichiers inutiles)"#,
                   options: .regularExpression) != nil {
            let size = cacheSizeMB()
            model.localPending = LocalPending(label: "Nettoyer les caches (\(size) Mo)") {
                let freed = cleanCaches()
                return "Nettoyage terminé : \(freed) Mo libérés. Rien de personnel n'a été touché."
            }
            return "J'ai trouvé environ \(size) Mo de fichiers temporaires de plus de 24 heures. Je les supprime ? Confirmez."
        }
        if t.range(of: #"^(?:vide|purge) (?:le )?cache dns$"#, options: .regularExpression) != nil {
            return D.runAdmin("dscacheutil -flushcache; killall -HUP mDNSResponder")
                ? "Cache DNS vidé." : "Opération annulée."
        }
        if t.range(of: #"^(?:mon reseau|etat du reseau|diagnostic reseau|test de connexion|ma connexion)$"#,
                   options: .regularExpression) != nil {
            return await network()
        }
        if t.range(of: #"^(?:mises? a jour|fais les mises a jour|verifie les mises a jour)$"#, options: .regularExpression) != nil {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
            return "J'ouvre la mise à jour de macOS."
        }
        if t.range(of: #"^(?:verrouille) "# + machine + "$", options: .regularExpression) != nil || t == "verrouille" {
            D.runTool("/usr/bin/pmset", ["displaysleepnow"])
            return "Mac verrouillé."
        }
        if t.range(of: #"^(?:redemarre) "# + machine + "$", options: .regularExpression) != nil {
            model.localPending = LocalPending(label: "Redémarrer le Mac") {
                applescript(#"tell application "System Events" to restart"#) ? "Redémarrage…" : "Redémarrage impossible."
            }
            return "Je redémarre le Mac. Pensez à enregistrer votre travail. Confirmez-vous ?"
        }
        if t.range(of: #"^(?:eteins|arrete) "# + machine + "$", options: .regularExpression) != nil {
            model.localPending = LocalPending(label: "Éteindre le Mac") {
                applescript(#"tell application "System Events" to shut down"#) ? "Extinction…" : "Extinction impossible."
            }
            return "J'éteins le Mac. Confirmez-vous ?"
        }
        if t.range(of: #"mode (?:economie|eco|economie d'energie)"#, options: .regularExpression) != nil {
            return D.runAdmin("pmset -a lowpowermode 1") ? "Mode économie d'énergie activé." : "Opération annulée."
        }
        if t.range(of: #"mode (?:performance|equilibre|normal)"#, options: .regularExpression) != nil {
            return D.runAdmin("pmset -a lowpowermode 0") ? "Économie d'énergie désactivée : pleine puissance." : "Opération annulée."
        }
        return nil
    }

    private static func analyze(model: AppModel) async -> String {
        var parts: [String] = []
        if let s = model.local.stats {
            parts.append("Santé \(s.health.score) sur 100. \(s.health.advice)")
            if s.diskPercent > 85 { parts.append("Le stockage est presque plein (\(Int(s.diskPercent)) %) : videz la corbeille et les téléchargements.") }
        }
        let top = await topProcesses(limit: 3)
        if !top.isEmpty {
            parts.append("Les applications les plus gourmandes : " + top.map { "\($0.name) (\(Int($0.cpu.rounded())) %)" }.joined(separator: ", ") + ".")
        }
        let cache = cacheSizeMB()
        if cache > 300 { parts.append("Environ \(cache) Mo de fichiers temporaires peuvent être nettoyés : dites « nettoie les fichiers temporaires ».") }
        return parts.isEmpty ? "Tout va bien." : parts.joined(separator: " ")
    }

    /// Applications les plus gourmandes (processeur), via ps.
    static func topProcesses(limit: Int = 8) async -> [ProcInfo] {
        let out = await D.runCapture("/bin/ps", ["-Aceo", "pcpu=,rss=,comm="])
        var merged: [String: (Double, Double, Int)] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let cpu = Double(f[0]), let rss = Double(f[1]) else { continue }
            var name = String(f[2])
            if let r = name.range(of: " Helper") { name = String(name[..<r.lowerBound]) }   // « Google Chrome Helper » → Chrome
            if ["kernel_task", "WindowServer", "launchd", "ps"].contains(name) { continue }
            let old = merged[name] ?? (0, 0, 0)
            merged[name] = (old.0 + cpu, old.1 + rss / 1024, old.2 + 1)
        }
        return merged.map { ProcInfo(name: $0.key, cpu: $0.value.0, mem_mb: $0.value.1, count: $0.value.2) }
            .sorted { $0.cpu == $1.cpu ? $0.mem_mb > $1.mem_mb : $0.cpu > $1.cpu }
            .prefix(limit).map { $0 }
    }

    private static func network() async -> String {
        let ping = await D.runCapture("/sbin/ping", ["-c", "3", "-t", "5", "1.1.1.1"])
        guard let avg = D.firstGroup(ping, #"= [\d.]+/([\d.]+)/"#), let ms = Double(avg) else {
            return "Pas de connexion à Internet pour le moment. Vérifiez le Wi-Fi ou la box."
        }
        let quality = ms < 30 ? "excellente" : ms < 80 ? "bonne" : ms < 150 ? "moyenne" : "lente"
        return "Connexion \(quality) : \(Int(ms.rounded())) millisecondes de latence vers Internet."
    }

    private static var cacheDirs: [URL] {
        let fm = FileManager.default
        var dirs = fm.urls(for: .cachesDirectory, in: .userDomainMask)
        dirs.append(fm.temporaryDirectory)
        return dirs
    }

    private static func oldFiles(_ action: (URL, Int) -> Void) {
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-86400)
        for dir in cacheDirs {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                      v.isRegularFile == true, let d = v.contentModificationDate, d < limit else { continue }
                action(url, v.fileSize ?? 0)
            }
        }
    }

    static func cacheSizeMB() -> Int {
        var total = 0
        oldFiles { _, size in total += size }
        return total / 1_048_576
    }

    static func cleanCaches() -> Int {
        var freed = 0
        oldFiles { url, size in
            if (try? FileManager.default.removeItem(at: url)) != nil { freed += size }
        }
        return freed / 1_048_576
    }

    @discardableResult
    static func applescript(_ source: String) -> Bool {
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil
    }

    // MARK: - Mac : modes (travail, gaming, concentration)

    private static func modes(_ t: String, model: AppModel) -> String? {
        func open(_ names: [String]) -> [String] {
            names.compactMap { name in
                guard let url = D.findApp(name) else { return nil }
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return name
            }
        }
        func enabled(_ name: String) -> Bool { model.hub.isRoutineEnabled(name) }
        if t.range(of: #"^(?:mode travail|au travail|mode boulot)$"#, options: .regularExpression) != nil {
            guard enabled("mode travail") else { return "La routine « mode travail » est désactivée." }
            applescript("set volume output volume 30")
            let opened = open(["Mail", "Calendar", "Notes"])
            return "Mode travail : " + (opened.isEmpty ? "son à 30 %." : "j'ouvre \(opened.joined(separator: ", ")), son à 30 %.")
        }
        if t.range(of: #"^(?:mode gaming|mode jeu|on joue)$"#, options: .regularExpression) != nil {
            guard enabled("mode gaming") else { return "La routine « mode gaming » est désactivée." }
            applescript("set volume output volume 70")
            let opened = open(["Discord", "Steam"])
            return "Mode gaming : " + (opened.isEmpty ? "son à 70 %." : "j'ouvre \(opened.joined(separator: " et ")), son à 70 %.") + " Bonne partie."
        }
        if t.range(of: #"^(?:mode concentration|mode focus|ne pas deranger)$"#, options: .regularExpression) != nil {
            guard enabled("mode concentration") else { return "La routine « mode concentration » est désactivée." }
            for app in ["Messages", "Discord", "Slack", "WhatsApp"] {
                applescript("if application \"\(app)\" is running then tell application \"\(app)\" to quit")
            }
            applescript("set volume output volume 20")
            return "Mode concentration : messageries fermées, son à 20 %. Bon courage."
        }
        return nil
    }
    #endif
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

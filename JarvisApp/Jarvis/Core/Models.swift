import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let fromUser: Bool
    let text: String
    let time: String
}

// MARK: - Réponses du cerveau JARVIS (PC)

struct RemoteState: Codable, Equatable {
    var mic: Bool? = nil
    var voice: Bool? = nil
    var speaking: Bool? = nil
    var busy: Bool? = nil
    var pending: String? = nil
    var ai: String? = nil
    var offline: Bool? = nil
    var user: String? = nil
}

struct RamInfo: Codable { var percent: Double; var used_gb: Double; var total_gb: Double }
struct DiskInfo: Codable { var mount: String; var percent: Double; var used_gb: Double?; var total_gb: Double? }
struct HealthInfo: Codable { var score: Int; var grade: String; var advice: String }
struct NetInfo: Codable { var up_kbs: Double?; var down_kbs: Double?; var sent_mb: Double?; var recv_mb: Double? }
struct Temps: Codable { var cpu: Double?; var gpu: Double? }

struct ProcInfo: Codable, Identifiable {
    var name: String
    var cpu: Double
    var mem_mb: Double
    var count: Int?
    var id: String { name }
}

struct SystemStats: Codable {
    var cpu: Double
    var cpu_freq_mhz: Double?
    var ram: RamInfo
    var disks: [DiskInfo]
    var temps: Temps?
    var uptime_s: Double?
    var top: [ProcInfo]?
    var cpu_history: [Double]?
    var health: HealthInfo?
    var net: NetInfo?
}

// MARK: - Catégories (maison, courses, minuteurs)

struct HomeDevice: Codable, Identifiable {
    var id: String
    var name: String
    var state: String?
    var domain: String
    var isOn: Bool { state == "on" || state == "open" }
}

struct HomeInfo: Codable {
    var configured: Bool
    var devices: [HomeDevice]
    var error: String?
    var message: String?
}

struct ShoppingItem: Codable, Identifiable { var id: Int; var item: String }
struct ShoppingResponse: Codable { var items: [ShoppingItem] }
struct TimerInfo: Codable, Identifiable { var id: Int; var kind: String; var label: String; var remaining: Double }
struct TimersResponse: Codable { var timers: [TimerInfo] }

enum AppTab: String, CaseIterable, Identifiable {
    case accueil, globe, systeme, boost, nettoyage, maison, organisation, routines
    var id: String { rawValue }
    var label: String {
        switch self {
        case .accueil: return "Accueil"
        case .globe: return "Globe"
        case .systeme: return "Système"
        case .boost: return "Boost"
        case .nettoyage: return "Nettoyage"
        case .maison: return "Maison"
        case .organisation: return "Organisation"
        case .routines: return "Routines"
        }
    }
    var symbol: String {
        switch self {
        case .accueil: return "circle.hexagongrid"
        case .globe: return "globe.europe.africa.fill"
        case .systeme: return "cpu"
        case .boost: return "bolt.fill"
        case .nettoyage: return "sparkles"
        case .maison: return "house.fill"
        case .organisation: return "checklist"
        case .routines: return "arrow.triangle.2.circlepath"
        }
    }
}

struct RemoteEvent: Codable {
    var seq: Int
    var topic: String
    var text: String?
    var title: String?
    var message: String?
    var time: String?
}

struct StateResponse: Codable {
    var state: RemoteState
    var stats: SystemStats?
    var events: [RemoteEvent]?
    var seq: Int?
}

struct CommandResponse: Codable {
    var reply: String
    var state: RemoteState?
}

struct NewsItem: Codable, Identifiable {
    var title: String
    var link: String?
    var source: String?
    var ts: Double?
    var id: String { title }
}

struct NewsCategory: Codable {
    var items: [NewsItem]
    var error: String?
}

struct AgendaEvent: Codable, Identifiable {
    var title: String
    var start: String
    var all_day: Bool?
    var id: String { "\(title)-\(start)" }

    var timeLabel: String {
        if all_day == true { return "Journée" }
        let parts = start.split(separator: "T")
        return parts.count > 1 ? String(parts[1].prefix(5)) : start
    }
}

struct TaskItem: Codable, Identifiable {
    var id: Int
    var title: String
    var due: String?
}

struct AgendaInfo: Codable {
    var events: [AgendaEvent]
    var tasks: [TaskItem]
    var error: String?
}

struct DashboardResponse: Codable {
    var agenda: AgendaInfo?
    var mail: MailInfo?
}

struct MailItem: Codable, Identifiable {
    var id: String
    var sender: String
    var subject: String
    var snippet: String?
    var ts: Double
    var why: [String]?
}

struct MailInfo: Codable {
    var configured: Bool
    var items: [MailItem]
    var error: String?
}

struct AgendaWrapper: Codable { var agenda: AgendaInfo }

struct RoutineInfo: Codable, Identifiable {
    var name: String
    var description: String?
    var enabled: Bool
    var trigger: String?
    var type: String?
    var id: String { name }
}

struct RoutinesResponse: Codable { var routines: [RoutineInfo] }

// MARK: - Météo locale

struct DayForecast: Identifiable {
    let date: Date
    let min: Double
    let max: Double
    let code: Int
    let rain: Int?
    var id: Date { date }
}

struct WeatherInfo {
    let city: String
    let temp: Double
    let feels: Double?
    let code: Int
    let wind: Double?
    let humidity: Double?
    let days: [DayForecast]

    var description: String { WeatherCodes.label(code) }

    var spoken: String {
        var s = "À \(city), il fait actuellement \(Int(temp.rounded())) degrés, \(description)."
        if let d = days.first {
            s += " Aujourd'hui, entre \(Int(d.min.rounded())) et \(Int(d.max.rounded())) degrés"
            s += d.rain.map { ", risque de pluie de \($0) %." } ?? "."
        }
        if days.count > 1 {
            let d = days[1]
            s += " Demain : \(WeatherCodes.label(d.code)), de \(Int(d.min.rounded())) à \(Int(d.max.rounded())) degrés."
        }
        return s
    }
}

enum WeatherCodes {
    static let labels: [Int: String] = [
        0: "ciel dégagé", 1: "ciel plutôt dégagé", 2: "partiellement nuageux", 3: "temps couvert",
        45: "brouillard", 48: "brouillard givrant", 51: "bruine légère", 53: "bruine", 55: "bruine dense",
        56: "bruine verglaçante", 57: "bruine verglaçante", 61: "pluie faible", 63: "pluie", 65: "forte pluie",
        66: "pluie verglaçante", 67: "forte pluie verglaçante", 71: "neige faible", 73: "neige", 75: "forte neige",
        77: "grains de neige", 80: "quelques averses", 81: "averses", 82: "violentes averses",
        85: "averses de neige", 86: "fortes averses de neige", 95: "orage", 96: "orage avec grêle",
        99: "orage avec forte grêle",
    ]

    static func label(_ code: Int) -> String { labels[code] ?? "conditions inconnues" }

    static func symbol(_ code: Int) -> String {
        switch code {
        case 0, 1: return "sun.max"
        case 2: return "cloud.sun"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51...57: return "cloud.drizzle"
        case 71...77, 85, 86: return "cloud.snow"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud.rain"
        }
    }
}

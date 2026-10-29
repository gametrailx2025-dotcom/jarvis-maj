#if os(macOS)
import AppKit
import CryptoKit
import SwiftUI

/// Nettoyage avancé du Mac : gros fichiers, doublons, dossiers vides, dossiers d'applis (tout inclus).
enum MacFileTools {
    struct Item: Identifiable, Hashable { let id = UUID(); let url: URL; let size: Int64; var note = "" }

    static var userDirs: [URL] {
        let fm = FileManager.default
        return [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory, .documentDirectory,
                .picturesDirectory, .moviesDirectory, .musicDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
    }

    static func human(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private static func files(in roots: [URL]) -> [(URL, Int64)] {
        var out: [(URL, Int64)] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                out.append((url, Int64(v.fileSize ?? 0)))
            }
        }
        return out
    }

    static func bigFiles() async -> [Item] {
        await Task.detached {
            files(in: userDirs).filter { $0.1 >= 300 * 1_048_576 }.sorted { $0.1 > $1.1 }.prefix(25)
                .map { Item(url: $0.0, size: $0.1) }
        }.value
    }

    static func duplicates() async -> [Item] {
        await Task.detached {
            var bySize: [Int64: [URL]] = [:]
            for (u, s) in files(in: userDirs) where s >= 100 * 1024 { bySize[s, default: []].append(u) }
            var copies: [Item] = []
            for (size, urls) in bySize where urls.count > 1 {
                var byHash: [String: [URL]] = [:]
                for u in urls {
                    guard let h = try? FileHandle(forReadingFrom: u) else { continue }
                    var hasher = SHA256()
                    while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
                    try? h.close()
                    byHash[hasher.finalize().map { String(format: "%02x", $0) }.joined(), default: []].append(u)
                }
                for same in byHash.values where same.count > 1 {
                    let sorted = same.sorted {
                        ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                            < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    }
                    for c in sorted.dropFirst() { copies.append(Item(url: c, size: size, note: "copie de " + sorted[0].lastPathComponent)) }
                }
            }
            return copies.sorted { $0.size > $1.size }
        }.value
    }

    static func emptyFolders() async -> [Item] {
        await Task.detached {
            var out: [Item] = []
            for root in userDirs {
                guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in e {
                    guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    let content = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["x"]
                    if content.filter({ !$0.hasPrefix(".") }).isEmpty { out.append(Item(url: url, size: 0)) }
                }
            }
            return Array(out.prefix(300))
        }.value
    }

    static func appFolders() async -> [Item] {
        await Task.detached {
            let fm = FileManager.default
            guard let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return [] }
            var out: [Item] = []
            for sub in ["Application Support", "Caches", "Containers"] {
                let base = lib.appendingPathComponent(sub)
                for d in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                    let size = files(in: [d]).reduce(Int64(0)) { $0 + $1.1 }
                    if size > 50 * 1_048_576 { out.append(Item(url: d, size: size, note: sub)) }
                }
            }
            return Array(out.sorted { $0.size > $1.size }.prefix(25))
        }.value
    }

    /// Envoie à la Corbeille (récupérable).
    static func trash(_ urls: [URL]) async -> Int {
        await withCheckedContinuation { cont in
            NSWorkspace.shared.recycle(urls) { done, _ in cont.resume(returning: done.count) }
        }
    }
}

struct FileToolSheet: View {
    enum Kind: String, Identifiable { case big, dupes, empty, apps; var id: String { rawValue } }
    let kind: Kind
    @Environment(\.dismiss) private var dismiss
    @State private var items: [MacFileTools.Item] = []
    @State private var loading = true
    @State private var message: String?

    private var title: String {
        switch kind {
        case .big: return "Gros fichiers"
        case .dupes: return "Doublons"
        case .empty: return "Dossiers inutilisés (vides)"
        case .apps: return "Dossiers d'applis"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                Button("Fermer") { dismiss() }
            }
            if loading {
                ProgressView("Analyse en cours…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text(message ?? "✅ Rien à signaler.").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { it in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(it.url.lastPathComponent).lineLimit(1)
                            Text(it.note.isEmpty ? it.url.deletingLastPathComponent().path : it.note)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if it.size > 0 { Text(MacFileTools.human(it.size)).monospacedDigit() }
                        Button("Afficher") { NSWorkspace.shared.activateFileViewerSelecting([it.url]) }
                        if kind != .apps {
                            Button("Corbeille") {
                                Task {
                                    _ = await MacFileTools.trash([it.url])
                                    items.removeAll { $0.id == it.id }
                                }
                            }
                        }
                    }
                }
                if kind == .dupes || kind == .empty {
                    Button(kind == .dupes ? "Envoyer toutes les copies à la Corbeille" : "Envoyer les dossiers vides à la Corbeille") {
                        Task {
                            let n = await MacFileTools.trash(items.map(\.url))
                            message = "✅ \(n) élément(s) envoyé(s) à la Corbeille (récupérables)."
                            items = []
                        }
                    }
                }
                if let message { Text(message).font(.footnote) }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 460)
        .task {
            switch kind {
            case .big: items = await MacFileTools.bigFiles()
            case .dupes: items = await MacFileTools.duplicates()
            case .empty: items = await MacFileTools.emptyFolders()
            case .apps: items = await MacFileTools.appFolders()
            }
            loading = false
        }
    }
}
#endif

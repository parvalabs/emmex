import Foundation

/// Downloads a Hugging Face model repo file by file with real byte-level progress.
/// The hub client's snapshot download only reports xet-backed files on completion, which
/// makes a single-shard model jump from 0% to 100%; this keeps the UI honest instead.
public enum HFDownloader {
    public struct Entry: Sendable { public var path: String; public var size: Int64 }

    public static func listFiles(repo: String, revision: String = "main") async throws -> [Entry] {
        var req = URLRequest(url: URL(string: "https://huggingface.co/api/models/\(repo)/revision/\(revision)?blobs=true")!)
        if let t = ProcessInfo.processInfo.environment["HF_TOKEN"] { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, repo)
        }
        struct Info: Decodable { struct Sibling: Decodable { var rfilename: String; var size: Int64? }; var siblings: [Sibling] }
        return try JSONDecoder().decode(Info.self, from: data).siblings.map { .init(path: $0.rfilename, size: $0.size ?? 0) }
    }

    /// Downloads every entry matching `patterns` into `dest`, skipping files already complete.
    /// `progress` receives (bytesDone, bytesTotal, currentFile) about every 100 ms.
    public static func download(repo: String, revision: String = "main", into dest: URL,
                                matching patterns: [String] = ["*.safetensors", "*.json", "*.txt", "*.jinja", "*.model", "*.tiktoken"],
                                progress: @escaping @Sendable (Int64, Int64, String) -> Void) async throws {
        let entries = try await listFiles(repo: repo, revision: revision).filter { e in
            patterns.contains { fnmatch($0, (e.path as NSString).lastPathComponent, 0) == 0 }
        }
        let total = entries.reduce(0) { $0 + $1.size }
        var done: Int64 = 0
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for e in entries {
            let target = dest.appending(path: e.path)
            if let attrs = try? fm.attributesOfItem(atPath: target.path), (attrs[.size] as? Int64) == e.size, e.size > 0 {
                done += e.size; progress(done, total, e.path); continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(e.path)")!
            var req = URLRequest(url: url)
            if let t = ProcessInfo.processInfo.environment["HF_TOKEN"] { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw DownloadError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, e.path)
            }
            let tmp = target.appendingPathExtension("part")
            fm.createFile(atPath: tmp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmp)
            defer { try? handle.close() }
            var buffer = Data(); buffer.reserveCapacity(1 << 20)
            var fileDone: Int64 = 0
            var lastReport = Date.distantPast
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer); fileDone += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                    if Date().timeIntervalSince(lastReport) > 0.1 { lastReport = Date(); progress(done + fileDone, total, e.path) }
                }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer); fileDone += Int64(buffer.count) }
            try handle.close()
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: tmp, to: target)
            done += fileDone
            progress(done, total, e.path)
        }
    }

    public enum DownloadError: Error, CustomStringConvertible {
        case http(Int, String)
        public var description: String {
            switch self { case .http(let code, let what): "HTTP \(code) for \(what)" }
        }
    }
}

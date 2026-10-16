import Foundation
final class Diagnostics {
    let root: URL
    let session: URL
    private var log: FileHandle?
    private var bytes = 0
    private let maxLogBytes: Int
    private let totalLogBytes: Int
    private let retention: TimeInterval
    private var lastCleanup = Date.distantPast
    private var writeError: String?
    private var cleanupError: String?
    var lastError: String? { writeError ?? cleanupError }
    private(set) var recent: [[String:Any]] = []
    init(root override: URL? = nil, maxLogBytes: Int = 8*1024*1024,
         totalLogBytes: Int = 64*1024*1024, retention: TimeInterval = 7*24*60*60) throws {
        self.maxLogBytes = maxLogBytes
        self.totalLogBytes = totalLogBytes
        self.retention = retention
        let base = Bundle.main.object(forInfoDictionaryKey:"VBReportsPath") as? String
        root = override ?? base.map { URL(fileURLWithPath:$0) } ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VoiceBridge/Reports")
        session = root.appendingPathComponent("session-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at:session,withIntermediateDirectories:true)
        let file = session.appendingPathComponent("events.jsonl")
        guard FileManager.default.createFile(atPath:file.path,contents:nil) else { throw CocoaError(.fileWriteUnknown) }
        log = try FileHandle(forWritingTo:file)
        cleanup()
    }
    deinit { try? log?.close() }
    static func timestamp() -> String { ISO8601DateFormatter().string(from:Date()) }
    func event(_ type: String, _ data: [String:Any] = [:]) {
        var record = data;record["event"] = type;record["time"] = Self.timestamp();record["unixTime"] = Date().timeIntervalSince1970
        recent.append(record);if recent.count > 180 { recent.removeFirst(recent.count-180) }
        do {
            var json = try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]);json.append(10)
            guard json.count <= maxLogBytes else {
                writeError = "Diagnostic event exceeds the log size limit; recent measurements are still available."
                return
            }
            if bytes + json.count > maxLogBytes { try rotate() }
            // Reopen after a recoverable rotation/open failure instead of silently dropping events.
            if log == nil { log = try FileHandle(forWritingTo:session.appendingPathComponent("events.jsonl"));try log?.seekToEnd() }
            try log?.write(contentsOf:json);bytes += json.count
            writeError = nil
        } catch { writeError = "Could not write diagnostics: \(error.localizedDescription)" }
        if Date().timeIntervalSince(lastCleanup) >= 3600 { cleanup() }
    }
    private func rotate() throws {
        let fm = FileManager.default
        let current = session.appendingPathComponent("events.jsonl")
        let previous = session.appendingPathComponent("events.previous.jsonl")
        try log?.close();log = nil
        if fm.fileExists(atPath:previous.path) { try fm.removeItem(at:previous) }
        if fm.fileExists(atPath:current.path) { try fm.moveItem(at:current,to:previous) }
        guard fm.createFile(atPath:current.path,contents:nil) else { throw CocoaError(.fileWriteUnknown) }
        bytes = 0
        log = try FileHandle(forWritingTo:current)
        cleanup()
    }
    // Only automatic logs are disposable. Never delete explicit reports, clips, or unknown files.
    // Called on the UI thread, outside the real-time audio callbacks.
    private func cleanup() {
        let fm = FileManager.default, now = Date()
        lastCleanup = now
        do {
            var oldLogs: [(url:URL, date:Date, size:Int)] = []
            var total = 0
            let folders = try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            for folder in folders where folder.lastPathComponent.hasPrefix("session-") {
                let info = try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard info.isDirectory == true,info.isSymbolicLink != true else { continue }
                for name in ["events.jsonl","events.previous.jsonl"] {
                    let file = folder.appendingPathComponent(name)
                    guard fm.fileExists(atPath:file.path) else { continue }
                    let values = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey])
                    guard values.isRegularFile == true,values.isSymbolicLink != true else { continue }
                    let size = values.fileSize ?? 0
                    total += size
                    if folder.lastPathComponent != session.lastPathComponent { oldLogs.append((file,values.contentModificationDate ?? .distantPast,size)) }
                }
            }
            for file in oldLogs.sorted(by:{$0.date < $1.date}) {
                if now.timeIntervalSince(file.date) > retention || total > totalLogBytes {
                    try fm.removeItem(at:file.url);total -= file.size
                    let folder = file.url.deletingLastPathComponent()
                    if try fm.contentsOfDirectory(atPath:folder.path).isEmpty { try fm.removeItem(at:folder) }
                }
            }
            cleanupError = nil
        } catch { cleanupError = "Could not clean up old diagnostic logs: \(error.localizedDescription)" }
    }
    func report(note: String, category: String, state: [String:Any]) throws -> URL {
        let id = "problem-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4))"
        event("problem_marked",["id":id,"category":category,"note":note])
        let report: [String:Any] = ["schemaVersion":1,"build":"0.5.2-preview","time":Self.timestamp(),"category":category,"note":note,"state":state,"recentEvents":recent,"audioPolicy":"No automatic recording. Any explicitly recorded clip is a separate local CAF file.","sessionPath":session.path]
        let url = session.appendingPathComponent(id+".json")
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
        return url
    }
}

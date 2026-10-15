import Foundation
final class Diagnostics {
    let root: URL
    let session: URL
    private var log: FileHandle?
    private var bytes = 0
    private(set) var lastError: String?
    private(set) var recent: [[String:Any]] = []
    init() throws {
        let base = Bundle.main.object(forInfoDictionaryKey:"VBReportsPath") as? String
        root = base.map { URL(fileURLWithPath:$0) } ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VoiceBridge/Reports")
        session = root.appendingPathComponent("session-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at:session,withIntermediateDirectories:true)
        let file = session.appendingPathComponent("events.jsonl")
        guard FileManager.default.createFile(atPath:file.path,contents:nil) else { throw CocoaError(.fileWriteUnknown) }
        log = try FileHandle(forWritingTo:file)
    }
    deinit { try? log?.close() }
    static func timestamp() -> String { ISO8601DateFormatter().string(from:Date()) }
    func event(_ type: String, _ data: [String:Any] = [:]) {
        var record = data;record["event"] = type;record["time"] = Self.timestamp();record["unixTime"] = Date().timeIntervalSince1970
        recent.append(record);if recent.count > 180 { recent.removeFirst(recent.count-180) }
        guard bytes < 8*1024*1024 else { lastError = "Session log reached 8 MB; reports still include recent measurements.";return }
        do { var json = try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]);json.append(10);try log?.write(contentsOf:json);bytes += json.count }
        catch { lastError = "Could not write diagnostics: \(error.localizedDescription)" }
    }
    func report(note: String, category: String, state: [String:Any]) throws -> URL {
        let id = "problem-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4))"
        event("problem_marked",["id":id,"category":category,"note":note])
        let report: [String:Any] = ["schemaVersion":1,"build":"0.5.1-preview","time":Self.timestamp(),"category":category,"note":note,"state":state,"recentEvents":recent,"audioPolicy":"No automatic recording. Any explicitly recorded clip is a separate local CAF file.","sessionPath":session.path]
        let url = session.appendingPathComponent(id+".json")
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
        return url
    }
}

import Foundation

@main struct DiagnosticsTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("voicebridge-diagnostics-tests-\(UUID())")
        try fm.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:temp) }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain:"DiagnosticsTests",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
        }
        func fixture(_ root:URL, _ name:String, age:TimeInterval, size:Int) throws -> URL {
            let folder = root.appendingPathComponent(name)
            try fm.createDirectory(at:folder,withIntermediateDirectories:true)
            let log = folder.appendingPathComponent("events.jsonl")
            try Data(repeating:65,count:size).write(to:log)
            try fm.setAttributes([.modificationDate:Date().addingTimeInterval(-age)],ofItemAtPath:log.path)
            return folder
        }

        // Exercise many rollovers and prove logging still reaches the newest event.
        let rolling = try Diagnostics(root:temp.appendingPathComponent("rolling"),maxLogBytes:512,totalLogBytes:128)
        for i in 0..<200 { rolling.event("metrics",["sequence":i]) }
        let current = rolling.session.appendingPathComponent("events.jsonl")
        let previous = rolling.session.appendingPathComponent("events.previous.jsonl")
        let currentData = try Data(contentsOf:current), previousData = try Data(contentsOf:previous)
        try check(currentData.count <= 512 && previousData.count <= 512,"Rotation exceeded its file budget")
        let lines = String(decoding:currentData,as:UTF8.self).split(separator:"\n")
        let last = try JSONSerialization.jsonObject(with:Data(lines.last!.utf8)) as! [String:Any]
        try check(last["sequence"] as? Int == 199,"Logging stopped after rotation")
        try check(rolling.lastError == nil && rolling.recent.count == 180,"Rollover reported an error or lost recent history")
        let report = try rolling.report(note:"Keep my report",category:"General",state:[:])
        let clip = rolling.session.appendingPathComponent("explicit-clip-test.caf")
        try Data([1,2,3]).write(to:clip)
        for i in 200..<220 { rolling.event("metrics",["sequence":i]) }
        try check(fm.fileExists(atPath:report.path) && fm.fileExists(atPath:clip.path),"Rotation removed explicit evidence")
        rolling.event("oversized",["value":String(repeating:"x",count:1000)])
        try check(rolling.lastError != nil,"Oversized event did not report its failure")
        rolling.event("recovered")
        try check(rolling.lastError == nil,"Successful write did not clear stale error")

        // Age cleanup removes logs, not clips, problem reports, or unrelated files.
        let agingRoot = temp.appendingPathComponent("aging")
        let old = try fixture(agingRoot,"session-old",age:8*24*3600,size:64)
        let saved = old.appendingPathComponent("problem-saved.json")
        let savedClip = old.appendingPathComponent("explicit-clip.caf")
        try Data("{}".utf8).write(to:saved)
        try Data([1]).write(to:savedClip)
        let empty = try fixture(agingRoot,"session-empty",age:8*24*3600,size:64)
        let fresh = try fixture(agingRoot,"session-fresh",age:60,size:64)
        let unrelated = try fixture(agingRoot,"unrelated",age:8*24*3600,size:64)
        let link = agingRoot.appendingPathComponent("session-symlink")
        try fm.createSymbolicLink(at:link,withDestinationURL:unrelated)
        let aging = try Diagnostics(root:agingRoot)
        try check(!fm.fileExists(atPath:old.appendingPathComponent("events.jsonl").path),"Expired log remained")
        try check(fm.fileExists(atPath:saved.path) && fm.fileExists(atPath:savedClip.path),"Cleanup deleted explicit evidence")
        try check(!fm.fileExists(atPath:empty.path),"Empty expired session remained")
        try check(fm.fileExists(atPath:fresh.appendingPathComponent("events.jsonl").path),"Fresh log was deleted")
        try check(fm.fileExists(atPath:unrelated.appendingPathComponent("events.jsonl").path),"Cleanup followed a symlink or deleted unrelated files")
        try check(aging.lastError == nil,"Age cleanup failed")

        // Space cleanup prunes the oldest automatic log even before its age limit.
        let quotaRoot = temp.appendingPathComponent("quota")
        let older = try fixture(quotaRoot,"session-older",age:120,size:300)
        let newer = try fixture(quotaRoot,"session-newer",age:60,size:300)
        let quota = try Diagnostics(root:quotaRoot,totalLogBytes:400)
        try check(!fm.fileExists(atPath:older.path),"Quota did not prune oldest log")
        try check(fm.fileExists(atPath:newer.path),"Quota removed more logs than needed")
        quota.event("still-running")
        try check(quota.lastError == nil,"Cleanup affected the current session")
        print("PASS: repeated log rotation, recent history, retention age/budget, explicit evidence preservation, symlink exclusion, and error recovery")
    }
}

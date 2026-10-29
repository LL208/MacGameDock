import Foundation
import Darwin

struct GameProcessArguments {
    var executable: String
    var arguments: [String]
    var winePrefix: String?
    // KERN_PROCARGS2: argc, executable, padding, argv[argc], environment.
    // Retain only WINEPREFIX; never keep or log unrelated environment values.
    static func decode(_ bytes: Data) -> GameProcessArguments? {
        guard bytes.count >= 5 else { return nil }
        let argc = bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 && argc < 4096 else { return nil }
        let buffer = [UInt8](bytes); var cursor = 4
        func string() -> String? {
            guard cursor < buffer.count, let end = buffer[cursor...].firstIndex(of: 0) else { return nil }
            defer { cursor = end + 1 }
            return String(bytes: buffer[cursor..<end], encoding: .utf8)
        }
        guard let executable = string() else { return nil }
        while cursor < buffer.count && buffer[cursor] == 0 { cursor += 1 }
        var args: [String] = []
        for _ in 0..<argc { guard let value = string() else { return nil }; args.append(value) }
        var prefix: String?
        while cursor < buffer.count {
            guard let value = string(), !value.isEmpty else { break }
            if value.hasPrefix("WINEPREFIX=") { prefix = String(value.dropFirst(11)); break }
        }
        return GameProcessArguments(executable: executable, arguments: args, winePrefix: prefix)
    }
    func matches(prefix: String, executable game: String) -> Bool {
        guard let winePrefix, URL(fileURLWithPath: winePrefix).standardizedFileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: prefix).standardizedFileURL.resolvingSymlinksInPath().path else { return false }
        let program = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        guard program.contains("wine"), !program.contains("wineserver") else { return false }
        func normalized(_ value: String) -> String {
            var path = value.replacingOccurrences(of: "\\", with: "/").lowercased()
            if path.hasPrefix("z:/") { path.removeFirst(2) }
            return path
        }
        let path = normalized(game)
        return arguments.contains { value in
            var candidate = normalized(value)
            if candidate.hasPrefix("c:/") { candidate = normalized(URL(fileURLWithPath: prefix).appendingPathComponent("drive_c").path) + "/" + candidate.dropFirst(3) }
            return candidate == path || candidate == URL(fileURLWithPath: game).lastPathComponent.lowercased()
        }
    }
}
struct GameProcessSnapshot {
    var parents: [Int32: Int32] = [:]
    var matchingWine: Set<Int32> = []
    var inspected = 0
}
enum GameProcessDiscovery {
    // Query window owners directly. Wine children may be reparented before the
    // launcher's first poll, so ancestry alone is insufficient.
    static func snapshot(windowOwners: Set<Int32>, prefix: String?, executable: String) -> GameProcessSnapshot {
        var result = GameProcessSnapshot()
        let count = max(1, Int(proc_listallpids(nil, 0))) + 256
        var pids = [Int32](repeating: 0, count: count)
        let used = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        for pid in pids.prefix(max(0, min(Int(used), pids.count))) where pid > 1 {
            var info = proc_bsdinfo()
            let length = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, length) == length, info.pbi_uid == getuid() else { continue }
            result.parents[pid] = Int32(info.pbi_ppid)
            guard let prefix, windowOwners.contains(pid) else { continue }
            // Read arguments only for Wine window owners, never arbitrary apps.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathSize = UInt32(path.count)
            guard proc_pidpath(pid, &path, pathSize) > 0 else { continue }
            let name = URL(fileURLWithPath: String(cString: path)).lastPathComponent.lowercased()
            guard name.contains("wine"), !name.contains("wineserver") else { continue }
            result.inspected += 1
            if let args = arguments(pid), args.matches(prefix: prefix, executable: executable) { result.matchingWine.insert(pid) }
        }
        return result
    }
    private static func arguments(_ pid: Int32) -> GameProcessArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let mibCount = UInt32(mib.count)
        var size = 0
        guard sysctl(&mib, mibCount, nil, &size, nil, 0) == 0, size > 4, size <= 4_194_304 else { return nil }
        var bytes = Data(count: size)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, mibCount, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        return GameProcessArguments.decode(bytes.prefix(size))
    }
}
struct GameFocusStability {
    private var window: Int?
    private var stableSince: TimeInterval?
    mutating func observe(window: Int, isFront: Bool, now: TimeInterval) -> Bool {
        guard isFront else { self.window = nil; stableSince = nil; return false }
        if self.window != window { self.window = window; stableSince = now }
        return now - (stableSince ?? now) >= 2.5
    }
}

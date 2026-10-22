import Foundation

// Inspect the dynamic export trie, not strings or private symbols. This is the
// interface DXMT 0.80 obtains through dlsym when creating its Metal view.
enum RuntimeGraphicsValidator {
    static let legacy: Set<String> = ["_get_win_data", "_release_win_data", "_macdrv_view_create_metal_view", "_macdrv_view_get_metal_layer", "_macdrv_view_release_metal_view"]
    static func validate(_ module: URL) throws {
        let names = try exports(Data(contentsOf: module))
        guard names.contains("_macdrv_functions") || legacy.isSubset(of: names) else {
            throw DockError.message("Il motore Wine non espone le funzioni Metal richieste da DXMT. Il gioco non verrà avviato con questo motore incompatibile.")
        }
    }
    static func exports(_ data: Data) throws -> Set<String> {
        func fail() -> DockError { .message("Modulo grafico Wine non valido: impossibile verificare le funzioni Metal.") }
        func uint(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - 4 else { throw fail() }
            return (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
        }
        guard data.count >= 32, try uint(0) == 0xfeedfacf else { throw fail() }
        let commands = try uint(16), commandBytes = try uint(20)
        guard commands <= 4096, commandBytes <= data.count - 32 else { throw fail() }
        var at = 32, range: Range<Int>?
        for _ in 0..<commands {
            let kind = try uint(at), size = try uint(at + 4)
            guard size >= 8, at + size <= 32 + commandBytes else { throw fail() }
            if kind == 0x80000033, size >= 16 {
                let start = try uint(at + 8), count = try uint(at + 12)
                guard start <= data.count, count <= data.count - start else { throw fail() }
                range = start..<(start + count)
            } else if [0x22, 0x80000022].contains(kind), size >= 48 {
                let start = try uint(at + 40), count = try uint(at + 44)
                guard start <= data.count, count <= data.count - start else { throw fail() }
                if count > 0 { range = start..<(start + count) }
            }
            at += size
        }
        guard let range, !range.isEmpty else { return [] }
        let trie = Array(data[range]); var names = Set<String>(), visited = Set<Int>()
        func uleb(_ cursor: inout Int) throws -> Int {
            var value = 0, shift = 0
            while cursor < trie.count, shift <= 56 {
                let byte = Int(trie[cursor]); cursor += 1
                value |= (byte & 127) << shift
                if byte & 128 == 0 { return value }
                shift += 7
            }
            throw fail()
        }
        func visit(_ offset: Int, _ prefix: String, _ depth: Int) throws {
            guard offset >= 0, offset < trie.count, depth < 256, prefix.utf8.count <= 4096, visited.insert(offset).inserted else { throw fail() }
            var cursor = offset
            let terminal = try uleb(&cursor)
            guard terminal <= trie.count - cursor else { throw fail() }
            let children = cursor + terminal
            if terminal > 0 {
                let flags = try uleb(&cursor)
                if flags & 8 == 0 { names.insert(prefix) } // Do not accept re-exported interfaces.
            }
            cursor = children
            guard cursor < trie.count else { throw fail() }
            let count = Int(trie[cursor]); cursor += 1
            for _ in 0..<count {
                let start = cursor
                while cursor < trie.count, trie[cursor] != 0 { cursor += 1 }
                guard cursor < trie.count, let edge = String(bytes: trie[start..<cursor], encoding: .utf8), !edge.isEmpty else { throw fail() }
                cursor += 1
                let child = try uleb(&cursor)
                try visit(child, prefix + edge, depth + 1)
            }
        }
        try visit(0, "", 0)
        return names
    }
}

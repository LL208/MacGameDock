import Foundation

indirect enum VDFValue {
    case text(String)
    case object([String: VDFValue])
    var string: String? { if case .text(let value) = self { return value }; return nil }
    var fields: [String: VDFValue]? { if case .object(let value) = self { return value }; return nil }
}

/// Small KeyValues parser for Steam's text manifests, not the binary appinfo format.
enum VDF {
    static func parse(_ source: String) throws -> [String: VDFValue] {
        let tokens = try tokenize(source)
        var cursor = 0
        func object(depth: Int, expectsClosingBrace: Bool) throws -> [String: VDFValue] {
            guard depth < 32 else { throw DockError.message("Manifest VDF troppo annidato.") }
            var result: [String: VDFValue] = [:]
            while cursor < tokens.count {
                let key = tokens[cursor]; cursor += 1
                if key == "}" {
                    guard expectsClosingBrace else { throw DockError.message("Manifest VDF non valido.") }
                    return result
                }
                guard key != "{", cursor < tokens.count else { throw DockError.message("Manifest VDF incompleto.") }
                let value = tokens[cursor]; cursor += 1
                if value == "{" { result[key] = .object(try object(depth: depth + 1, expectsClosingBrace: true)) }
                else if value == "}" { throw DockError.message("Valore VDF mancante.") }
                else { result[key] = .text(value) }
            }
            guard !expectsClosingBrace else { throw DockError.message("Manifest VDF incompleto.") }
            return result
        }
        return try object(depth: 0, expectsClosingBrace: false)
    }

    private static func tokenize(_ source: String) throws -> [String] {
        let chars = Array(source)
        var index = 0
        var result: [String] = []
        while index < chars.count {
            guard result.count < 200_000 else { throw DockError.message("Manifest VDF troppo grande.") }
            let char = chars[index]
            if char.isWhitespace || char == "\u{feff}" { index += 1; continue }
            if char == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if char == "{" || char == "}" { result.append(String(char)); index += 1; continue }
            if char == "\"" {
                index += 1
                var value = ""
                var closed = false
                while index < chars.count {
                    let next = chars[index]; index += 1
                    if next == "\"" { closed = true; break }
                    if next == "\\", index < chars.count {
                        let escaped = chars[index]; index += 1
                        switch escaped {
                        case "\\", "\"": value.append(escaped)
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        default: value.append("\\"); value.append(escaped)
                        }
                    } else { value.append(next) }
                }
                guard closed else { throw DockError.message("Stringa VDF incompleta.") }
                result.append(value)
            } else {
                var value = ""
                while index < chars.count, !chars[index].isWhitespace, chars[index] != "{", chars[index] != "}" {
                    value.append(chars[index]); index += 1
                }
                result.append(value)
            }
        }
        return result
    }
}

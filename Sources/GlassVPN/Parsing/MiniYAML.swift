//
// MiniYAML.swift
// GlassVPN
// 只实现 Clash 订阅用得到的 YAML 子集: 块状映射/序列、流式 {} []、引号标量、注释、块标量。
// 为保持体积不引入第三方 YAML 库。标量一律保留为 String, 由调用方按需转换,
// 避免 "0123" 这类密码被误转成数字。
//

import Foundation

enum MiniYAML {

    static func parse(_ text: String) -> Any? {
        Parser(lines: lines(of: text)).parseBlock(minIndent: 0)
    }

    /// 只解析某个顶层键 (如 proxies), 跳过动辄上万行的 rules
    static func topLevel(_ key: String, in text: String) -> Any? {
        let all = lines(of: text)
        guard let start = all.firstIndex(where: { $0.indent == 0 && Parser.splitKey($0.text)?.key == key }) else {
            return nil
        }
        var section = [all[start]]
        var i = start + 1
        // 顶层键下的序列允许与键同为 0 缩进 ("proxies:\n- {...}")
        while i < all.count, all[i].indent > 0 || Parser.isSeqItem(all[i].text) {
            section.append(all[i])
            i += 1
        }
        return (Parser(lines: section).parseBlock(minIndent: 0) as? [String: Any])?[key]
    }

    fileprivate static func lines(of text: String) -> [Line] {
        var result: [Line] = []
        text.enumerateLines { raw, _ in
            let noComment = stripComment(raw)
            var indent = 0
            for ch in noComment {
                if ch == " " || ch == "\t" { indent += 1 } else { break }
            }
            let content = noComment.dropFirst(indent).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, content != "---", content != "..." else { return }
            result.append(Line(indent: indent, text: content))
        }
        return result
    }

    fileprivate static func stripComment(_ s: String) -> String {
        guard s.contains("#") else { return s }
        var quote: Character?
        var prev: Character = " "
        for i in s.indices {
            let ch = s[i]
            if let q = quote {
                if ch == q && !(q == "\"" && prev == "\\") { quote = nil }
            } else if (ch == "\"" || ch == "'") && " \t:[{,-".contains(prev) {
                // 只有出现在标量开头的引号才算引号, 避免 It's 这类撇号吞掉后面的注释判断
                quote = ch
            } else if ch == "#" && (prev == " " || prev == "\t" || i == s.startIndex) {
                return String(s[..<i])
            }
            prev = ch
        }
        return s
    }
}

fileprivate struct Line {
    var indent: Int
    var text: String
}

private final class Parser {
    var lines: [Line]
    var i = 0

    init(lines: [Line]) { self.lines = lines }

    static func isSeqItem(_ t: String) -> Bool {
        t == "-" || t.hasPrefix("- ") || t.hasPrefix("-\t")
    }

    /// 拆出 "key: value", 值可能为空串; 不是映射条目时返回 nil
    static func splitKey(_ t: String) -> (key: String, value: String)? {
        guard let first = t.first, first != "{", first != "[" else { return nil }
        let chars = Array(t)
        let key: String
        var idx: Int
        if first == "\"" || first == "'" {
            var j = 1
            while j < chars.count && chars[j] != first {
                if chars[j] == "\\" && first == "\"" { j += 1 }
                j += 1
            }
            guard j < chars.count else { return nil }
            key = unquote(String(chars[0...j]))
            idx = j + 1
            while idx < chars.count && chars[idx] == " " { idx += 1 }
            guard idx < chars.count, chars[idx] == ":" else { return nil }
        } else {
            // 键里的冒号后面不会紧跟空白, 所以 "http://x" 这类值不会被误拆
            var found: Int?
            var j = 0
            while j < chars.count {
                if chars[j] == ":" && (j + 1 == chars.count || chars[j + 1] == " " || chars[j + 1] == "\t") {
                    found = j
                    break
                }
                j += 1
            }
            guard let f = found else { return nil }
            key = String(chars[0..<f]).trimmingCharacters(in: .whitespaces)
            idx = f
        }
        let value = String(chars[(idx + 1)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    func parseBlock(minIndent: Int) -> Any? {
        guard i < lines.count, lines[i].indent >= minIndent else { return nil }
        let line = lines[i]
        if Parser.isSeqItem(line.text) { return parseSeq(line.indent) }
        if Parser.splitKey(line.text) != nil { return parseMap(line.indent) }
        i += 1
        return value(line.text, indent: line.indent)
    }

    func parseSeq(_ indent: Int) -> [Any] {
        var items: [Any] = []
        while i < lines.count, lines[i].indent >= indent {
            let line = lines[i]
            if line.indent > indent || !Parser.isSeqItem(line.text) {
                // 同级的非序列行属于上一层映射; 更深且无法归属的行直接跳过
                if line.indent == indent { break }
                i += 1
                continue
            }
            let rest = line.text == "-" ? "" : String(line.text.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                i += 1
                items.append(parseBlock(minIndent: indent + 1) ?? NSNull())
            } else if Parser.isSeqItem(rest) || Parser.splitKey(rest) != nil {
                // "- key: v" 视为从 rest 所在列开始的块, 下一行同列的键属于同一个映射
                let column = indent + (line.text.count - rest.count)
                lines[i] = Line(indent: column, text: rest)
                items.append(parseBlock(minIndent: column) ?? NSNull())
            } else {
                i += 1
                items.append(value(rest, indent: indent))
            }
        }
        return items
    }

    func parseMap(_ indent: Int) -> [String: Any] {
        var result: [String: Any] = [:]
        while i < lines.count, lines[i].indent >= indent {
            let line = lines[i]
            if line.indent > indent {
                i += 1
                continue
            }
            if Parser.isSeqItem(line.text) { break }
            guard let kv = Parser.splitKey(line.text) else {
                i += 1
                continue
            }
            i += 1
            var v = kv.value
            if v.hasPrefix("&") {
                // 去掉锚点声明, 别名 (*x) 不展开
                v = v.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            }
            if v.isEmpty {
                if i < lines.count,
                   lines[i].indent > indent || (lines[i].indent == indent && Parser.isSeqItem(lines[i].text)) {
                    result[kv.key] = parseBlock(minIndent: lines[i].indent) ?? NSNull()
                } else {
                    result[kv.key] = NSNull()
                }
            } else if v.hasPrefix("|") || v.hasPrefix(">") {
                result[kv.key] = blockScalar(indent, folded: v.hasPrefix(">"))
            } else {
                result[kv.key] = value(v, indent: indent)
            }
        }
        return result
    }

    func blockScalar(_ indent: Int, folded: Bool) -> String {
        var parts: [String] = []
        while i < lines.count, lines[i].indent > indent {
            parts.append(lines[i].text)
            i += 1
        }
        return parts.joined(separator: folded ? " " : "\n")
    }

    func value(_ v: String, indent: Int) -> Any {
        guard v.first == "{" || v.first == "[" else { return Parser.scalar(v) }
        var text = v
        // 流式集合可能跨多行, 拼接到括号配平为止
        while !Parser.balanced(text), i < lines.count, lines[i].indent > indent {
            text += " " + lines[i].text
            i += 1
        }
        var flow = Flow(Array(text))
        return flow.value()
    }

    static func balanced(_ s: String) -> Bool {
        var depth = 0
        var quote: Character?
        var prev: Character = " "
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil }
            } else if (ch == "\"" || ch == "'") && " \t:[{,".contains(prev) {
                quote = ch
            } else if ch == "{" || ch == "[" {
                depth += 1
            } else if ch == "}" || ch == "]" {
                depth -= 1
            }
            prev = ch
        }
        return depth <= 0
    }

    static func scalar(_ raw: String) -> Any {
        var s = raw
        if s.hasPrefix("!!"), let space = s.firstIndex(of: " ") {
            s = s[space...].trimmingCharacters(in: .whitespaces)
        }
        if let f = s.first, f == "\"" || f == "'" { return unquote(s) }
        if s == "~" || s.lowercased() == "null" { return NSNull() }
        return s
    }

    static func unquote(_ s: String) -> String {
        guard let q = s.first, q == "\"" || q == "'", s.count >= 2 else { return s }
        let chars = Array(s.dropFirst())
        var out = ""
        var j = 0
        while j < chars.count {
            let ch = chars[j]
            if q == "'" {
                if ch == "'" {
                    if j + 1 < chars.count && chars[j + 1] == "'" {
                        out.append("'")
                        j += 2
                        continue
                    }
                    break
                }
            } else {
                if ch == "\"" { break }
                if ch == "\\" && j + 1 < chars.count {
                    let n = chars[j + 1]
                    j += 2
                    switch n {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "u":
                        let hex = String(chars[j..<min(j + 4, chars.count)])
                        if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                            out.append(Character(scalar))
                        }
                        j += 4
                    default: out.append(n)
                    }
                    continue
                }
            }
            out.append(ch)
            j += 1
        }
        return out
    }
}

/// 流式集合 {a: b, c: [d, e]} 的字符级解析
private struct Flow {
    let c: [Character]
    var p = 0

    init(_ c: [Character]) { self.c = c }

    mutating func skip() {
        while p < c.count, c[p] == " " || c[p] == "\t" { p += 1 }
    }

    mutating func value() -> Any {
        skip()
        guard p < c.count else { return "" }
        switch c[p] {
        case "{": return object()
        case "[": return array()
        case "\"", "'": return quoted()
        default: return Parser.scalar(plain(stops: ",}]"))
        }
    }

    mutating func object() -> [String: Any] {
        p += 1
        var result: [String: Any] = [:]
        while p < c.count {
            skip()
            guard p < c.count else { break }
            if c[p] == "}" {
                p += 1
                break
            }
            let before = p
            if c[p] == "," {
                p += 1
                continue
            }
            let key = (c[p] == "\"" || c[p] == "'") ? quoted() : plain(stops: ":,}")
            skip()
            if p < c.count, c[p] == ":" { p += 1 }
            skip()
            if p < c.count, c[p] == "," || c[p] == "}" {
                result[key] = NSNull()
            } else {
                result[key] = value()
            }
            // 遇到畸形输入时保证前进, 防止死循环
            if p == before { p += 1 }
        }
        return result
    }

    mutating func array() -> [Any] {
        p += 1
        var result: [Any] = []
        while p < c.count {
            skip()
            guard p < c.count else { break }
            if c[p] == "]" {
                p += 1
                break
            }
            let before = p
            if c[p] == "," {
                p += 1
                continue
            }
            result.append(value())
            if p == before { p += 1 }
        }
        return result
    }

    mutating func quoted() -> String {
        let q = c[p]
        let start = p
        p += 1
        while p < c.count {
            if c[p] == "\\" && q == "\"" {
                p += 2
                continue
            }
            if c[p] == q {
                if q == "'" && p + 1 < c.count && c[p + 1] == "'" {
                    p += 2
                    continue
                }
                p += 1
                break
            }
            p += 1
        }
        return Parser.unquote(String(c[start..<min(p, c.count)]))
    }

    mutating func plain(stops: String) -> String {
        let start = p
        while p < c.count, !stops.contains(c[p]) { p += 1 }
        return String(c[start..<p]).trimmingCharacters(in: .whitespaces)
    }
}

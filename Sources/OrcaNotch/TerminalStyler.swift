import SwiftUI

/// Orca only hands us the rendered screen as plain text, so colour is recovered from the
/// shape of agent TUIs (Claude Code, Codex, …): bullets, tool output gutters, prompts,
/// menus, spinners, diffs.
enum StyledLine {
    case rule
    case text(AttributedString, indent: CGFloat, highlight: Color?)
}

enum TerminalPalette {
    static let text = Color(white: 0.88)
    static let dim = Color(white: 0.5)
    static let faint = Color(white: 0.34)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let green = Color(red: 0.45, green: 0.85, blue: 0.55)
    static let red = Color(red: 1.0, green: 0.45, blue: 0.45)
    static let blue = Color(red: 0.45, green: 0.66, blue: 1.0)
    static let cyan = Color(red: 0.55, green: 0.82, blue: 0.95)
    static let code = Color(red: 0.95, green: 0.72, blue: 0.5)
}

enum TerminalStyler {
    private typealias P = TerminalPalette

    private static let ruleChars: Set<Character> = ["─", "━", "═", "╌", "┄", "-", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", " "]
    private static let spinnerGlyphs: Set<Character> = ["✻", "✳", "✶", "✢", "✽", "·", "*", "※", "⏺", "◐", "◓", "◑", "◒"]
    private static let toolCall = try! NSRegularExpression(pattern: #"^([A-Z][A-Za-z0-9_]*(?:\([^)]*)?)"#)
    private static let menuOption = try! NSRegularExpression(pattern: #"^(\s*)(❯|›|>)?(\s*)(\d+)\.\s"#)
    private static let diffLine = try! NSRegularExpression(pattern: #"^\s*\d+\s+([+-])\s?"#)
    private static let url = try! NSRegularExpression(pattern: #"https?://[^\s)\]>"']+"#)
    private static let inlineCode = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)

    static func style(_ lines: [String]) -> [StyledLine] {
        var out: [StyledLine] = []
        for raw in lines {
            var line = raw.replacingOccurrences(of: "⧉ ", with: "").replacingOccurrences(of: "\u{a0}", with: " ")

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 8, trimmed.allSatisfy({ ruleChars.contains($0) }) {
                if case .rule? = out.last { continue }
                out.append(.rule)
                continue
            }
            // Strip box borders: "│ text │"
            if trimmed.hasPrefix("│") {
                line = String(trimmed.dropFirst())
                if line.hasSuffix("│") { line = String(line.dropLast()) }
                line = line.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
            }
            if trimmed.isEmpty {
                if case .text(let s, _, _)? = out.last, s.characters.isEmpty { continue }
                out.append(.text(AttributedString(""), indent: 0, highlight: nil))
                continue
            }
            out.append(styleLine(line))
        }
        while case .rule? = out.first { out.removeFirst() }
        return out
    }

    private static func styleLine(_ line: String) -> StyledLine {
        let leading = line.prefix(while: { $0 == " " }).count
        let body = String(line.dropFirst(leading))
        let indent = CGFloat(min(leading, 12)) * 6.3
        let first = body.first!
        let ns = body as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Diff hunks in edit previews: "  12 + foo" / "  12 - foo"
        if let m = diffLine.firstMatch(in: body, range: full) {
            let added = ns.substring(with: m.range(at: 1)) == "+"
            let color = added ? P.green : P.red
            var s = inline(body, base: color)
            s.foregroundColor = color
            return .text(s, indent: indent, highlight: color.opacity(0.12))
        }

        // Numbered menu (permission prompts / questions); "❯ 1." marks the selected row.
        if let m = menuOption.firstMatch(in: body, range: full) {
            let selected = m.range(at: 2).location != NSNotFound
            var s = AttributedString(body)
            s.foregroundColor = selected ? P.cyan : P.text
            if selected { s.font = .system(size: 11, weight: .bold, design: .monospaced) }
            return .text(s, indent: indent, highlight: selected ? P.cyan.opacity(0.12) : nil)
        }

        switch first {
        case "●", "•", "⏺":
            let rest = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
            var bullet = AttributedString("● ")
            let restNS = rest as NSString
            if let m = toolCall.firstMatch(in: rest, range: NSRange(location: 0, length: restNS.length)),
               rest.dropFirst(m.range.length).isEmpty || restNS.substring(with: m.range).contains("(") {
                bullet.foregroundColor = P.green
                let name = restNS.substring(with: m.range)
                let parts = name.split(separator: "(", maxSplits: 1)
                var tool = AttributedString(String(parts[0]))
                tool.foregroundColor = .white
                tool.font = .system(size: 11, weight: .bold, design: .monospaced)
                var args = AttributedString(parts.count > 1 ? "(" + parts[1] : "")
                args.foregroundColor = P.dim
                var tail = inline(restNS.substring(from: m.range.length), base: P.dim)
                tail.foregroundColor = P.dim
                return .text(bullet + tool + args + tail, indent: indent, highlight: nil)
            }
            bullet.foregroundColor = .white
            return .text(bullet + inline(rest, base: P.text), indent: indent, highlight: nil)

        case "⎿", "└":
            var gutter = AttributedString("⎿ ")
            gutter.foregroundColor = P.faint
            let rest = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
            var s = inline(rest, base: P.dim)
            s.foregroundColor = P.dim
            return .text(gutter + s, indent: indent + 6, highlight: nil)

        case "❯", "›", ">":
            var mark = AttributedString("❯ ")
            mark.foregroundColor = P.cyan
            mark.font = .system(size: 11, weight: .bold, design: .monospaced)
            var s = AttributedString(String(body.dropFirst()).trimmingCharacters(in: .whitespaces))
            s.foregroundColor = .white
            s.font = .system(size: 11, weight: .semibold, design: .monospaced)
            return .text(mark + s, indent: indent, highlight: Color.white.opacity(0.05))

        case "⏵", "⏸", "⇅":
            var s = AttributedString(body)
            s.foregroundColor = P.faint
            s.font = .system(size: 10, design: .monospaced)
            return .text(s, indent: indent, highlight: nil)

        default:
            if spinnerGlyphs.contains(first), body.dropFirst().first == " " {
                var glyph = AttributedString(String(first) + " ")
                glyph.foregroundColor = P.claude
                var s = AttributedString(String(body.dropFirst(2)))
                s.foregroundColor = P.dim
                s.font = .system(size: 11, design: .monospaced).italic()
                return .text(glyph + s, indent: indent, highlight: nil)
            }
            let lower = body.lowercased()
            if lower.hasPrefix("error") || lower.contains(" error:") || lower.hasPrefix("fatal:") {
                var s = AttributedString(body)
                s.foregroundColor = P.red
                return .text(s, indent: indent, highlight: nil)
            }
            if lower.contains("do you want to") || lower.hasSuffix("?") && leading > 0 {
                var s = inline(body, base: .white)
                s.font = .system(size: 11, weight: .semibold, design: .monospaced)
                return .text(s, indent: indent, highlight: nil)
            }
            return .text(inline(body, base: P.text), indent: indent, highlight: nil)
        }
    }

    /// URLs and `code` spans.
    private static func inline(_ text: String, base: Color) -> AttributedString {
        var s = AttributedString(text)
        s.foregroundColor = base
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        for m in inlineCode.matches(in: text, range: full) {
            if let r = Range(m.range, in: text), let ar = Range(r, in: s) {
                s[ar].foregroundColor = P.code
            }
        }
        for m in url.matches(in: text, range: full) {
            if let r = Range(m.range, in: text), let ar = Range(r, in: s) {
                s[ar].foregroundColor = P.blue
                s[ar].underlineStyle = .single
                if let link = URL(string: String(text[r])) { s[ar].link = link }
            }
        }
        return s
    }
}

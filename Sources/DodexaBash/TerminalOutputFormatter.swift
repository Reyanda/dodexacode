import Foundation

struct TerminalOutputFormatter {
    let colors: AnsiPalette

    func formatBlockOutput(_ content: String, isError: Bool) -> String {
        format(content, isError: isError, barColor: isError ? colors.statusErr : colors.accent, textColor: isError ? colors.statusErr : "")
    }

    func formatInlineOutput(_ content: String, isError: Bool) -> String {
        format(content, isError: isError, barColor: isError ? colors.statusErr : colors.separator, textColor: isError ? colors.statusErr : colors.hint)
    }

    private func format(_ content: String, isError: Bool, barColor: String, textColor: String) -> String {
        var inCodeBlock = false
        let bar = isError
            ? barColor + "\u{2502}" + colors.reset + " "
            : "  " + barColor + "\u{2502}" + colors.reset + "  "
        var lines = content.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)

        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }

        var result = ""
        for line in lines {
            if line.isEmpty {
                result += bar + "\r\n"
            } else {
                let styled = styleLine(line, textColor: textColor, inCodeBlock: &inCodeBlock)
                result += bar + styled + colors.reset + "\r\n"
            }
        }
        return result
    }

    private func styleLine(_ line: String, textColor: String, inCodeBlock: inout Bool) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") {
            inCodeBlock.toggle()
            if inCodeBlock {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let label = lang.isEmpty ? "\u{2500}\u{2500} code" : "\u{2500}\u{2500} \(lang)"
                return colors.separator + "  \u{256D}" + label + " " + String(repeating: "\u{2500}", count: max(0, 30 - label.count)) + colors.reset
            }
            return colors.separator + "  \u{2570}" + String(repeating: "\u{2500}", count: 34) + colors.reset
        }

        if inCodeBlock {
            return colors.statusOk + "  \u{2502} " + line + colors.reset
        }

        if trimmed.hasPrefix("brain>") {
            let content = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return colors.intentColor + "  \u{25C6} " + content + colors.reset
        }

        if trimmed.hasPrefix(">> running:") {
            let command = String(trimmed.dropFirst(11)).trimmingCharacters(in: .whitespaces)
            return colors.statusLabel + "  \u{25B8} " + colors.statusOk + command + colors.reset
        }
        if trimmed.hasPrefix(">>") {
            let message = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return colors.hint + "  " + message + colors.reset
        }

        if trimmed.hasPrefix("---") && trimmed.hasSuffix("---") {
            return colors.accent + "\u{001B}[1m" + trimmed + colors.reset
        }

        if trimmed.hasPrefix("# ") {
            return colors.accent + "\u{001B}[1m  " + trimmed + colors.reset
        }
        if trimmed.hasPrefix("## ") {
            return colors.prompt + "\u{001B}[1m  " + trimmed + colors.reset
        }
        if trimmed.hasPrefix("### ") || trimmed.hasPrefix("#### ") {
            return colors.path + "  " + trimmed + colors.reset
        }

        if trimmed.hasPrefix("| ") && trimmed.hasSuffix(" |") {
            if trimmed.contains(":---") || trimmed.contains("---:") || (trimmed.contains("---") && !trimmed.contains(where: \.isLetter)) {
                return colors.separator + trimmed + colors.reset
            }
            return colors.status + trimmed + colors.reset
        }

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return colors.status + "  " + trimmed + colors.reset
        }

        if let first = trimmed.first, first.isNumber, trimmed.contains(". ") {
            return colors.status + "  " + trimmed + colors.reset
        }

        if let colonIndex = trimmed.firstIndex(of: ":"), trimmed.distance(from: trimmed.startIndex, to: colonIndex) < 20 {
            let key = trimmed[..<colonIndex]
            if !key.contains(" ") || key.count < 15 {
                let value = trimmed[colonIndex...]
                return colors.statusLabel + "  " + key + colors.reset + colors.status + value + colors.reset
            }
        }

        return textColor + "  " + line + colors.reset
    }
}

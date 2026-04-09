import Foundation

struct TerminalBlockRenderer {
    let colors: AnsiPalette

    func render(_ state: TerminalBlockState) -> String {
        let formatter = TerminalOutputFormatter(colors: colors)
        var result = "\r\n"
        result += colors.accent + "  \u{25B6} " + "\u{001B}[1m" + state.command + colors.reset + "\r\n"

        if !state.stdout.isEmpty {
            result += formatter.formatBlockOutput(state.stdout, isError: false)
        }
        if !state.stderr.isEmpty {
            result += formatter.formatBlockOutput(state.stderr, isError: true)
        }

        if !state.badges.isEmpty {
            let renderedBadges = state.badges.map(renderBadge).joined(separator: " ")
            result += "  " + renderedBadges + "\r\n"
        } else {
            result += "\r\n"
        }

        if let suggestion = state.suggestion, !suggestion.isEmpty {
            result += colors.hint + "  next " + colors.reset
            result += colors.accent + suggestion + colors.reset + "\r\n"
        }

        return result
    }

    private func renderBadge(_ badge: TerminalBadge) -> String {
        let tone: String
        switch badge.tone {
        case .accent:
            tone = colors.accent
        case .success:
            tone = colors.statusOk
        case .warning:
            tone = colors.attentionColor
        case .error:
            tone = colors.statusErr
        case .subtle:
            tone = colors.hint
        }
        return tone + badge.text + colors.reset
    }
}

import Foundation

struct TerminalTimelineRenderer {
    let colors: AnsiPalette

    func render(width: Int, state: TerminalTimelineState) -> [String] {
        var lines: [String] = [
            colors.separator + "recent" + colors.reset + colors.hint + "  " + state.title + colors.reset
        ]

        if state.items.isEmpty {
            lines.append(colors.hint + "  " + state.emptyText + colors.reset)
        } else {
            for item in state.items {
                lines.append(renderItem(width: width, item: item))
            }
        }

        if let selected = state.selectedBlockCommand, !selected.isEmpty {
            let clipped = clip(selected, limit: max(0, width - 18))
            lines.append(colors.hint + "  selected " + colors.reset + colors.accent + clipped + colors.reset)
            if let label = state.selectedBlockPreviewLabel, !label.isEmpty {
                let clippedLabel = clip(label, limit: max(0, width - 12))
                lines.append(colors.hint + "  view " + colors.reset + colors.status + clippedLabel + colors.reset)
            }
            for preview in state.selectedBlockPreview {
                lines.append(renderPreviewLine(width: width, text: preview))
            }
        }

        if let suggestion = state.suggestion, !suggestion.isEmpty {
            let label = "  next "
            let available = max(0, width - label.count - 2)
            let clipped = clip(suggestion, limit: available)
            lines.append(colors.hint + label + colors.reset + colors.accent + clipped + colors.reset)
        }

        return lines
    }

    private func renderItem(width: Int, item: TerminalTimelineItem) -> String {
        let marker = item.isSelected ? "\u{25C6}" : "\u{25B6}"
        let commandStyle = item.isSelected ? colors.accent + "\u{001B}[1m" : colors.status
        let prefixPlain = "  \(marker) " + item.command
        let badgesPlain = item.badges.map(\.text).joined(separator: " ")
        let spacing = badgesPlain.isEmpty ? "" : "  "
        let summaryPrefix = "  "
        let reserved = prefixPlain.count + spacing.count + badgesPlain.count + summaryPrefix.count
        let availableSummary = max(0, width - reserved)
        let clippedSummary = clip(item.summary, limit: availableSummary)

        var line = colors.accent + "  \(marker) " + colors.reset
        line += commandStyle + clip(item.command, limit: max(12, width / 3)) + colors.reset
        if !item.badges.isEmpty {
            line += spacing + item.badges.map(renderBadge).joined(separator: " ")
        }
        if !clippedSummary.isEmpty {
            line += colors.hint + summaryPrefix + clippedSummary + colors.reset
        }
        return line
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

    private func renderPreviewLine(width: Int, text: String) -> String {
        let prefix = "    \u{2502} "
        let available = max(0, width - prefix.count)
        let clipped = clip(text, limit: available)
        return colors.separator + prefix + colors.reset + colors.hint + clipped + colors.reset
    }

    private func clip(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        guard limit > 1 else { return String(text.prefix(limit)) }
        return String(text.prefix(limit - 1)) + "…"
    }
}

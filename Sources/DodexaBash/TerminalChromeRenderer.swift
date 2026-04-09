import Foundation

struct TerminalChromeRenderer {
    let colors: AnsiPalette

    func render(width: Int, state: TerminalScreenState) -> TerminalRenderFrame {
        let topBarLine = renderTopBar(width: width, state: state.topBar)
        let timelineRenderer = TerminalTimelineRenderer(colors: colors)
        let timelineLines = timelineRenderer.render(width: width, state: state.timeline)
        let overlayLines: [String]
        if let palette = state.palette {
            overlayLines = TerminalOverlayRenderer(colors: colors, theme: colors.theme).render(width: width, palette: palette)
        } else {
            overlayLines = []
        }
        return TerminalRenderFrame(
            lines: [topBarLine] + timelineLines + overlayLines + [renderComposer(width: width, state: state.composer)],
            cursorColumn: state.composer.cursorColumn
        )
    }

    private func renderTopBar(width: Int, state: TerminalTopBarState) -> String {
        let separator = " \u{00B7} "
        var parts: [(plain: String, styled: String)] = []

        let titlePlain = state.title
        let titleStyled = colors.accent + "\u{001B}[1m" + titlePlain + colors.reset
        parts.append((titlePlain, titleStyled))

        if !state.context.isEmpty {
            parts.append((state.context, colors.path + state.context + colors.reset))
        }

        for item in state.items {
            parts.append((item.text, style(item)))
        }

        var rendered = ""
        var visibleCount = 0

        for (index, part) in parts.enumerated() {
            let separatorWidth = index == 0 ? 0 : separator.count
            let nextWidth = separatorWidth + part.plain.count
            guard visibleCount + nextWidth <= width else { break }
            if index > 0 {
                rendered += colors.separator + separator + colors.reset
                visibleCount += separatorWidth
            }
            rendered += part.styled
            visibleCount += part.plain.count
        }

        return rendered
    }

    private func renderGhost(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return colors.ghost + text + colors.reset
    }

    private func renderComposer(width: Int, state: TerminalComposerState) -> String {
        var line = state.displayLine + renderGhost(state.ghostText)
        guard let hintText = state.hintText, !hintText.isEmpty else { return line }

        let spacing = width - state.occupiedWidth - hintText.count
        guard spacing >= 4 else { return line }

        line += String(repeating: " ", count: spacing)
        line += colors.hint + hintText + colors.reset
        return line
    }

    private func style(_ item: TerminalBadge) -> String {
        let tone: String
        switch item.tone {
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
        return tone + item.text + colors.reset
    }
}

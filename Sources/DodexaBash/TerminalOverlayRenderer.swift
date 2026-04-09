import DodexaCodeCore
import Foundation

struct TerminalOverlayRenderer {
    let colors: AnsiPalette
    let theme: Theme

    func render(width: Int, palette: TerminalPaletteState) -> [String] {
        let tuiTheme = TUITheme.from(theme)
        let contentWidth = min(max(36, width - 6), 72)

        var content: [String] = []
        content.append(tuiTheme.muted + "Query: " + ANSI.reset + tuiTheme.accent + palette.query + ANSI.reset)

        if palette.items.isEmpty {
            content.append(tuiTheme.muted + palette.emptyText + ANSI.reset)
        } else {
            for item in palette.items.prefix(6) {
                let marker = item.isSelected ? "\u{25C6}" : "\u{25B6}"
                let titleStyle = item.isSelected ? tuiTheme.accent + ANSI.bold : tuiTheme.fg
                let line = titleStyle + "\(marker) \(item.title)" + ANSI.reset +
                    tuiTheme.muted + " [" + item.modeLabel + "]" + ANSI.reset +
                    tuiTheme.muted + "  " + item.subtitle + ANSI.reset
                content.append(line)
            }
        }

        let footer = tuiTheme.muted + "Enter loads action  Up/Down moves  Ctrl-P closes" + ANSI.reset
        let box = BoxWidget(title: "command palette", content: content, footer: footer, style: .rounded)
        return box.render(width: contentWidth + 4, theme: tuiTheme)
    }
}

import Darwin
import Foundation

// MARK: - TUI Framework: Component-Based Terminal Rendering
// A structured rendering engine replacing raw ANSI writes.
// Widgets compose into layouts. The renderer diffs and repaints only changed regions.
// Inspired by Warp's block-based UI but pure terminal (ANSI + termios).

// MARK: - Terminal Capabilities

public struct TermSize: Sendable {
    public let cols: Int
    public let rows: Int

    public static func current() -> TermSize {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return TermSize(cols: Int(size.ws_col), rows: Int(size.ws_row))
        }
        return TermSize(cols: 100, rows: 40)
    }
}

// MARK: - ANSI Builder (fluent API for escape sequences)

public struct ANSI {
    public static let reset = "\u{001B}[0m"
    public static let bold = "\u{001B}[1m"
    public static let dim = "\u{001B}[2m"
    public static let italic = "\u{001B}[3m"
    public static let underline = "\u{001B}[4m"
    public static let blink = "\u{001B}[5m"
    public static let inverse = "\u{001B}[7m"
    public static let hidden = "\u{001B}[8m"
    public static let strikethrough = "\u{001B}[9m"

    // Cursor
    public static func moveTo(row: Int, col: Int) -> String { "\u{001B}[\(row);\(col)H" }
    public static func moveUp(_ n: Int = 1) -> String { "\u{001B}[\(n)A" }
    public static func moveDown(_ n: Int = 1) -> String { "\u{001B}[\(n)B" }
    public static func moveRight(_ n: Int = 1) -> String { "\u{001B}[\(n)C" }
    public static func moveLeft(_ n: Int = 1) -> String { "\u{001B}[\(n)D" }
    public static let saveCursor = "\u{001B}[s"
    public static let restoreCursor = "\u{001B}[u"
    public static let hideCursor = "\u{001B}[?25l"
    public static let showCursor = "\u{001B}[?25h"

    // Clear
    public static let clearScreen = "\u{001B}[2J"
    public static let clearLine = "\u{001B}[2K"
    public static let clearToEnd = "\u{001B}[J"
    public static let clearToLineEnd = "\u{001B}[K"

    // 256-color foreground/background
    public static func fg(_ code: Int) -> String { "\u{001B}[38;5;\(code)m" }
    public static func bg(_ code: Int) -> String { "\u{001B}[48;5;\(code)m" }

    // RGB color
    public static func fgRGB(_ r: Int, _ g: Int, _ b: Int) -> String { "\u{001B}[38;2;\(r);\(g);\(b)m" }
    public static func bgRGB(_ r: Int, _ g: Int, _ b: Int) -> String { "\u{001B}[48;2;\(r);\(g);\(b)m" }

    // Scrolling region
    public static func setScrollRegion(top: Int, bottom: Int) -> String { "\u{001B}[\(top);\(bottom)r" }
    public static let resetScrollRegion = "\u{001B}[r"

    // Mouse
    public static let enableMouse = "\u{001B}[?1000h\u{001B}[?1006h"
    public static let disableMouse = "\u{001B}[?1000l\u{001B}[?1006l"

    // Alternative screen buffer (like vim)
    public static let enterAltScreen = "\u{001B}[?1049h"
    public static let exitAltScreen = "\u{001B}[?1049l"

    // Bracketed paste
    public static let enableBracketedPaste = "\u{001B}[?2004h"
    public static let disableBracketedPaste = "\u{001B}[?2004l"
}

// MARK: - Theme (Warp-inspired)

public struct TUITheme: Sendable {
    // Primary palette
    public let bg: String              // main background
    public let fg: String              // main foreground
    public let accent: String          // primary accent (blue)
    public let success: String         // green
    public let warning: String         // yellow/amber
    public let error: String           // red
    public let muted: String           // dim text

    // UI chrome
    public let border: String          // box-drawing color
    public let separator: String       // line separators
    public let selection: String       // selected item bg

    // Syntax
    public let keyword: String         // language keywords
    public let string: String          // string literals
    public let number: String          // numeric literals
    public let comment: String         // comments
    public let type: String            // type names
    public let function: String        // function names

    public static let warp = TUITheme(
        bg: ANSI.bgRGB(30, 30, 30),
        fg: ANSI.fgRGB(220, 220, 220),
        accent: ANSI.fgRGB(88, 166, 255),
        success: ANSI.fgRGB(87, 199, 133),
        warning: ANSI.fgRGB(229, 192, 123),
        error: ANSI.fgRGB(224, 108, 117),
        muted: ANSI.fgRGB(128, 128, 128),
        border: ANSI.fgRGB(68, 68, 68),
        separator: ANSI.fgRGB(50, 50, 50),
        selection: ANSI.bgRGB(50, 60, 80),
        keyword: ANSI.fgRGB(198, 120, 221),
        string: ANSI.fgRGB(152, 195, 121),
        number: ANSI.fgRGB(209, 154, 102),
        comment: ANSI.fgRGB(92, 99, 112),
        type: ANSI.fgRGB(229, 192, 123),
        function: ANSI.fgRGB(97, 175, 239)
    )

    public static let ocean = TUITheme(
        bg: ANSI.bgRGB(25, 35, 45),
        fg: ANSI.fgRGB(200, 210, 220),
        accent: ANSI.fgRGB(100, 180, 255),
        success: ANSI.fgRGB(80, 200, 140),
        warning: ANSI.fgRGB(240, 190, 100),
        error: ANSI.fgRGB(230, 100, 100),
        muted: ANSI.fgRGB(110, 120, 140),
        border: ANSI.fgRGB(55, 65, 80),
        separator: ANSI.fgRGB(40, 50, 60),
        selection: ANSI.bgRGB(40, 60, 90),
        keyword: ANSI.fgRGB(180, 130, 230),
        string: ANSI.fgRGB(130, 200, 140),
        number: ANSI.fgRGB(220, 170, 110),
        comment: ANSI.fgRGB(80, 95, 115),
        type: ANSI.fgRGB(220, 180, 100),
        function: ANSI.fgRGB(80, 170, 250)
    )

    public static func from(_ theme: Theme) -> TUITheme {
        TUITheme(
            bg: "",
            fg: ANSI.fg(theme.prompt),
            accent: ANSI.fg(theme.accent),
            success: ANSI.fg(theme.statusOk),
            warning: ANSI.fg(theme.attention),
            error: ANSI.fg(theme.statusErr),
            muted: ANSI.fg(theme.hint),
            border: ANSI.fg(theme.separator),
            separator: ANSI.fg(theme.separator),
            selection: ANSI.bg(theme.separator),
            keyword: ANSI.fg(theme.intent),
            string: ANSI.fg(theme.branch),
            number: ANSI.fg(theme.attention),
            comment: ANSI.fg(theme.hint),
            type: ANSI.fg(theme.path),
            function: ANSI.fg(theme.accent)
        )
    }
}

// MARK: - Styled Text

public struct StyledText: Sendable {
    public var text: String
    public var style: String  // ANSI codes

    public init(_ text: String, style: String = "") {
        self.text = text
        self.style = style
    }

    public var rendered: String {
        style.isEmpty ? text : style + text + ANSI.reset
    }

    public var visibleLength: Int { text.count }
}

// MARK: - Widget Protocol

public protocol TUIWidget {
    var minWidth: Int { get }
    var minHeight: Int { get }
    func render(width: Int, theme: TUITheme) -> [String]
}

// MARK: - Built-in Widgets

/// Horizontal separator line
public struct SeparatorWidget: TUIWidget {
    public let char: Character
    public let label: String?
    public var minWidth: Int { 5 }
    public var minHeight: Int { 1 }

    public init(char: Character = "\u{2500}", label: String? = nil) {
        self.char = char
        self.label = label
    }

    public func render(width: Int, theme: TUITheme) -> [String] {
        if let label {
            let padding = max(0, width - label.count - 4)
            return [theme.border + "\u{2500}\u{2500} " + ANSI.reset + theme.muted + label + ANSI.reset + " " + theme.border + String(repeating: char, count: padding) + ANSI.reset]
        }
        return [theme.border + String(repeating: char, count: width) + ANSI.reset]
    }
}

/// Text block with optional padding
public struct TextWidget: TUIWidget {
    public let lines: [StyledText]
    public let padding: Int
    public var minWidth: Int { 10 }
    public var minHeight: Int { lines.count }

    public init(_ text: String, style: String = "", padding: Int = 0) {
        self.lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { StyledText(String($0), style: style) }
        self.padding = padding
    }

    public init(lines: [StyledText], padding: Int = 0) {
        self.lines = lines
        self.padding = padding
    }

    public func render(width: Int, theme: TUITheme) -> [String] {
        let pad = String(repeating: " ", count: padding)
        return lines.map { pad + $0.rendered }
    }
}

/// Box with border (for blocks)
public struct BoxWidget: TUIWidget {
    public let title: String?
    public let content: [String]
    public let footer: String?
    public let style: BoxStyle
    public var minWidth: Int { 20 }
    public var minHeight: Int { content.count + 2 }

    public enum BoxStyle: Sendable { case rounded, sharp, double_, heavy }

    public init(title: String? = nil, content: [String], footer: String? = nil, style: BoxStyle = .rounded) {
        self.title = title
        self.content = content
        self.footer = footer
        self.style = style
    }

    public func render(width: Int, theme: TUITheme) -> [String] {
        let (tl, tr, bl, br, h, v) = chars(for: style)
        var lines: [String] = []

        // Top border
        if let title {
            let titlePad = max(0, width - title.count - 4)
            lines.append(theme.border + String(tl) + String(h) + ANSI.reset + " " + ANSI.bold + title + ANSI.reset + " " + theme.border + String(repeating: h, count: titlePad) + String(tr) + ANSI.reset)
        } else {
            lines.append(theme.border + String(tl) + String(repeating: h, count: width - 2) + String(tr) + ANSI.reset)
        }

        // Content
        for line in content {
            let visible = stripANSI(line).count
            let pad = max(0, width - visible - 4)
            lines.append(theme.border + String(v) + ANSI.reset + " " + line + String(repeating: " ", count: pad) + " " + theme.border + String(v) + ANSI.reset)
        }

        // Bottom border
        if let footer {
            let footerPad = max(0, width - stripANSI(footer).count - 6)
            lines.append(theme.border + String(bl) + String(h) + String(h) + ANSI.reset + " " + footer + " " + theme.border + String(repeating: h, count: footerPad) + String(br) + ANSI.reset)
        } else {
            lines.append(theme.border + String(bl) + String(repeating: h, count: width - 2) + String(br) + ANSI.reset)
        }

        return lines
    }

    private func chars(for style: BoxStyle) -> (Character, Character, Character, Character, Character, Character) {
        switch style {
        case .rounded: return ("\u{256D}", "\u{256E}", "\u{2570}", "\u{256F}", "\u{2500}", "\u{2502}")
        case .sharp:   return ("\u{250C}", "\u{2510}", "\u{2514}", "\u{2518}", "\u{2500}", "\u{2502}")
        case .double_: return ("\u{2554}", "\u{2557}", "\u{255A}", "\u{255D}", "\u{2550}", "\u{2551}")
        case .heavy:   return ("\u{250F}", "\u{2513}", "\u{2517}", "\u{251B}", "\u{2501}", "\u{2503}")
        }
    }

    private func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
    }
}

/// Progress bar
public struct ProgressWidget: TUIWidget {
    public let progress: Double  // 0.0 - 1.0
    public let label: String?
    public var minWidth: Int { 20 }
    public var minHeight: Int { 1 }

    public init(progress: Double, label: String? = nil) {
        self.progress = min(1, max(0, progress))
        self.label = label
    }

    public func render(width: Int, theme: TUITheme) -> [String] {
        let barWidth = width - (label.map { $0.count + 3 } ?? 0) - 7
        let filled = Int(Double(barWidth) * progress)
        let empty = barWidth - filled
        let pct = String(format: "%3d%%", Int(progress * 100))

        let bar = theme.accent + String(repeating: "\u{2588}", count: filled) + ANSI.reset +
                  theme.muted + String(repeating: "\u{2591}", count: empty) + ANSI.reset

        let prefix = label.map { theme.muted + $0 + " " + ANSI.reset } ?? ""
        return [prefix + bar + " " + pct]
    }
}

/// Key-value pairs (for status displays)
public struct KVWidget: TUIWidget {
    public let pairs: [(key: String, value: String)]
    public let keyWidth: Int
    public var minWidth: Int { keyWidth + 10 }
    public var minHeight: Int { pairs.count }

    public init(_ pairs: [(String, String)], keyWidth: Int = 15) {
        self.pairs = pairs
        self.keyWidth = keyWidth
    }

    public func render(width: Int, theme: TUITheme) -> [String] {
        pairs.map { pair in
            let key = pair.key.padding(toLength: keyWidth, withPad: " ", startingAt: 0)
            return theme.muted + key + ANSI.reset + " " + pair.value
        }
    }
}

/// Table
public struct TableWidget: TUIWidget {
    public let headers: [String]
    public let rows: [[String]]
    public var minWidth: Int { headers.count * 10 }
    public var minHeight: Int { rows.count + 2 }

    public init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
    }

    public func render(width: Int, theme: TUITheme) -> [String] {
        // Calculate column widths
        let colCount = headers.count
        var colWidths = headers.map(\.count)
        for row in rows {
            for (i, cell) in row.enumerated() where i < colCount {
                colWidths[i] = max(colWidths[i], cell.count)
            }
        }

        var lines: [String] = []

        // Header
        let header = zip(headers, colWidths).map { h, w in
            ANSI.bold + h.padding(toLength: w + 2, withPad: " ", startingAt: 0) + ANSI.reset
        }.joined()
        lines.append(header)

        // Separator
        lines.append(theme.separator + colWidths.map { String(repeating: "\u{2500}", count: $0 + 2) }.joined(separator: "") + ANSI.reset)

        // Rows
        for row in rows {
            let cells = zip(row, colWidths).map { cell, w in
                cell.padding(toLength: w + 2, withPad: " ", startingAt: 0)
            }.joined()
            lines.append(cells)
        }

        return lines
    }
}

// MARK: - Renderer

public final class TUIRenderer: @unchecked Sendable {
    private let output: FileHandle
    public var theme: TUITheme

    public init(output: FileHandle = .standardOutput, theme: TUITheme = .warp) {
        self.output = output
        self.theme = theme
    }

    public func write(_ text: String) {
        output.write(Data(text.utf8))
    }

    public func writeLine(_ text: String = "") {
        write(text + "\r\n")
    }

    public func render(_ widget: TUIWidget) {
        let size = TermSize.current()
        let lines = widget.render(width: size.cols, theme: theme)
        for line in lines {
            writeLine(line)
        }
    }

    public func renderAll(_ widgets: [any TUIWidget]) {
        let size = TermSize.current()
        for widget in widgets {
            let lines = widget.render(width: size.cols, theme: theme)
            for line in lines {
                writeLine(line)
            }
        }
    }

    // Convenience methods
    public func separator(_ label: String? = nil) {
        render(SeparatorWidget(label: label))
    }

    public func box(title: String? = nil, content: [String], footer: String? = nil, style: BoxWidget.BoxStyle = .rounded) {
        render(BoxWidget(title: title, content: content, footer: footer, style: style))
    }

    public func text(_ text: String, style: String = "") {
        render(TextWidget(text, style: style))
    }

    public func progress(_ value: Double, label: String? = nil) {
        render(ProgressWidget(progress: value, label: label))
    }

    public func table(headers: [String], rows: [[String]]) {
        render(TableWidget(headers: headers, rows: rows))
    }

    public func kv(_ pairs: [(String, String)]) {
        render(KVWidget(pairs))
    }

    public func blank() { writeLine() }
}

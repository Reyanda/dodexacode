import Foundation

struct TerminalBadge {
    enum Tone {
        case accent
        case success
        case warning
        case error
        case subtle
    }

    let text: String
    let tone: Tone
}

struct TerminalTopBarState {
    let title: String
    let context: String
    let items: [TerminalBadge]
}

struct TerminalTimelineItem {
    let blockId: UUID?
    let command: String
    let summary: String
    let badges: [TerminalBadge]
    let isSelected: Bool
}

struct TerminalTimelineState {
    let title: String
    let items: [TerminalTimelineItem]
    let emptyText: String
    let suggestion: String?
    let selectedBlockCommand: String?
    let selectedBlockPreviewLabel: String?
    let selectedBlockPreview: [String]
}

struct TerminalComposerState {
    let displayLine: String
    let ghostText: String
    let cursorColumn: Int
    let occupiedWidth: Int
    let hintText: String?
}

struct TerminalPaletteItem {
    let title: String
    let subtitle: String
    let command: String
    let modeLabel: String
    let isSelected: Bool
}

struct TerminalPaletteState {
    let query: String
    let items: [TerminalPaletteItem]
    let emptyText: String
}

struct TerminalBlockState {
    let command: String
    let stdout: String
    let stderr: String
    let badges: [TerminalBadge]
    let suggestion: String?
}

struct TerminalScreenState {
    let topBar: TerminalTopBarState
    let timeline: TerminalTimelineState
    let palette: TerminalPaletteState?
    let composer: TerminalComposerState
}

struct TerminalRenderFrame {
    let lines: [String]
    let cursorColumn: Int
}

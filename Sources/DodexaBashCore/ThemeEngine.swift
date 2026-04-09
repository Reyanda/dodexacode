import Foundation

// MARK: - Theme Definition

public struct Theme: Codable, Sendable {
    public let name: String
    public let prompt: Int        // 256-color index
    public let path: Int
    public let accent: Int
    public let separator: Int
    public let hint: Int
    public let statusOk: Int
    public let statusErr: Int
    public let intent: Int
    public let lease: Int
    public let attention: Int
    public let proof: Int
    public let branch: Int
    public let ghost: Int

    public static let ocean = Theme(name: "ocean", prompt: 75, path: 110, accent: 75, separator: 238, hint: 245, statusOk: 108, statusErr: 167, intent: 141, lease: 73, attention: 209, proof: 108, branch: 180, ghost: 240)
    public static let forest = Theme(name: "forest", prompt: 71, path: 108, accent: 71, separator: 236, hint: 243, statusOk: 71, statusErr: 131, intent: 139, lease: 66, attention: 173, proof: 71, branch: 143, ghost: 239)
    public static let ember = Theme(name: "ember", prompt: 209, path: 180, accent: 209, separator: 237, hint: 244, statusOk: 107, statusErr: 167, intent: 175, lease: 209, attention: 209, proof: 107, branch: 180, ghost: 240)
    public static let mono = Theme(name: "mono", prompt: 252, path: 248, accent: 252, separator: 238, hint: 243, statusOk: 252, statusErr: 248, intent: 252, lease: 248, attention: 252, proof: 252, branch: 248, ghost: 240)
    public static let nord = Theme(name: "nord", prompt: 110, path: 109, accent: 110, separator: 237, hint: 244, statusOk: 108, statusErr: 131, intent: 139, lease: 109, attention: 173, proof: 108, branch: 180, ghost: 239)
    public static let dracula = Theme(name: "dracula", prompt: 141, path: 84, accent: 212, separator: 237, hint: 244, statusOk: 84, statusErr: 210, intent: 141, lease: 117, attention: 215, proof: 84, branch: 215, ghost: 239)
    public static let solarized = Theme(name: "solarized", prompt: 33, path: 37, accent: 136, separator: 236, hint: 244, statusOk: 64, statusErr: 160, intent: 61, lease: 37, attention: 166, proof: 64, branch: 136, ghost: 240)

    public static let all: [Theme] = [ocean, forest, ember, mono, nord, dracula, solarized]
}

// MARK: - Theme Store

public final class ThemeStore {
    private let configURL: URL
    public private(set) var current: Theme

    public init(directory: URL) {
        self.configURL = directory.appendingPathComponent("theme.json")
        if let data = try? Data(contentsOf: configURL),
           let saved = try? JSONDecoder().decode(Theme.self, from: data) {
            self.current = saved
        } else {
            self.current = .ocean
        }
    }

    public func set(_ theme: Theme) {
        current = theme
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(theme) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    public func set(byName name: String) -> Bool {
        guard let theme = Theme.all.first(where: { $0.name == name }) else { return false }
        set(theme)
        return true
    }
}

// MARK: - Tips

public enum Tips {
    private static let tips: [String] = [
        // AI features
        "Type # followed by natural language to generate commands: # find large files",
        "Use 'ask' to query the brain: ask what is the meaning of life",
        "brain do <task> runs multi-step tasks autonomously",
        "skill run debug-loop lets the brain follow a debugging workflow",
        "The brain speaks any language — try Dutch, French, or Japanese",

        // Shell power
        "alias deploy='git push origin main' creates a shortcut",
        "function greet echo hello $1 defines a reusable function",
        "source ~/.dodexabashrc loads your custom aliases and functions",
        "ll, .., gs, gd, gl are built-in aliases for common commands",

        // Future-shell primitives
        "intent set 'fix the build' tracks what you're working on",
        "simulate rm -rf / shows predicted effects without executing",
        "lease grant read:repo . 60 creates a time-limited permission",
        "prove last shows the evidence chain from the last command",
        "uncertainty show reveals what the shell knows vs guesses",
        "repair last suggests fixes after a command fails",
        "world show builds a graph of your workspace",

        // Navigation
        "Tab completes commands and file paths",
        "Up/Down arrows browse command history",
        "Ctrl-A jumps to start of line, Ctrl-E to end",
        "Ctrl-L or 'clear' redraws the screen",

        // Files
        "Type a filename directly to open it: README.md",
        "create index.html scaffolds a web page with boilerplate",
        "open file.txt shows file contents inline",
        "tree -L2 shows directory structure",
        "md README.md parses markdown structure",

        // Themes
        "theme list shows available color themes",
        "theme set dracula switches to Dracula colors",
        "Available themes: ocean, forest, ember, mono, nord, dracula, solarized",

        // Blocks
        "Every command creates a Block with provenance metadata",
        "Block footers show duration, exit code, proof, and intent indicators",

        // Brain management
        "brain models lists available Ollama models",
        "brain set gemma4 switches the AI model",
        "brain tune creates a fine-tuned model for shell tasks",
        "brain clear resets conversation memory",

        // Skills
        "skill list shows available workflow skills",
        "skill create my-skill 'description' 'step1' 'step2' makes a custom skill",
        "skill run explore-repo lets the brain understand a new codebase",

        // MCP
        "dodexabash exposes 33 tools over MCP via --mcp mode",
        "External AI agents can call dodexabash tools through JSON-RPC",

        // Meta
        "cards shows the built-in workflow cards",
        "status gives a quick overview of shell state",
        "graph shows the workspace as a node graph",
    ]

    public static func random() -> String {
        tips[Int.random(in: 0..<tips.count)]
    }

    public static func ofTheDay() -> String {
        let day = Calendar.current.component(.day, from: Date())
        return tips[day % tips.count]
    }
}

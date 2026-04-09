import Foundation

public struct ShellFunction: Codable, Sendable {
    public let name: String
    public let body: String // shell source to execute when called
    public let params: [String] // parameter names for positional args
}

public final class ShellContext {
    public var environment: [String: String]
    public var lastStatus: Int32
    public var shouldExit: Bool
    public var requestedExitStatus: Int32
    public var aliases: [String: String] = [:]
    public var functions: [String: ShellFunction] = [:]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        lastStatus: Int32 = 0,
        shouldExit: Bool = false,
        requestedExitStatus: Int32 = 0
    ) {
        self.environment = environment
        self.lastStatus = lastStatus
        self.shouldExit = shouldExit
        self.requestedExitStatus = requestedExitStatus
        // Default aliases
        aliases["ll"] = "ls -la"
        aliases["la"] = "ls -a"
        aliases[".."] = "cd .."
        aliases["..."] = "cd ../.."
        aliases["gs"] = "git status"
        aliases["gd"] = "git diff"
        aliases["gl"] = "git log --oneline -10"
    }

    public var currentDirectory: String {
        FileManager.default.currentDirectoryPath
    }

    public func resolve(_ word: Word) -> String {
        let raw = word.segments.map { segment -> String in
            switch segment {
            case .literal(let literal):
                return literal
            case .variable(let name):
                return environment[name] ?? ""
            case .lastExitStatus:
                return String(lastStatus)
            case .commandSubstitution(let source):
                return "$(\(source))"
            }
        }.joined()

        guard let first = word.segments.first else {
            return raw
        }

        guard case .literal(let literal) = first, literal.hasPrefix("~") else {
            return raw
        }

        guard let home = environment["HOME"] else {
            return raw
        }

        if raw == "~" {
            return home
        }

        if raw.hasPrefix("~/") {
            return home + String(raw.dropFirst())
        }

        return raw
    }
}

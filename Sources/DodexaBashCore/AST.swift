import Foundation

public struct Script: Equatable, Sendable {
    public let statements: [CommandNode]

    public init(statements: [CommandNode]) {
        self.statements = statements
    }
}

public indirect enum CommandNode: Equatable, Sendable {
    case simple(SimpleCommand)
    case pipeline([SimpleCommand])
    case conditional(lhs: CommandNode, op: ConditionalOperator, rhs: CommandNode)
}

public enum ConditionalOperator: Equatable, Sendable {
    case and
    case or
}

public struct SimpleCommand: Equatable, Sendable {
    public let words: [Word]
    public let redirections: [Redirection]

    public init(words: [Word], redirections: [Redirection]) {
        self.words = words
        self.redirections = redirections
    }
}

public struct Word: Equatable, Sendable {
    public let segments: [WordSegment]

    public init(segments: [WordSegment]) {
        self.segments = segments
    }
}

public enum WordSegment: Equatable, Sendable {
    case literal(String)
    case variable(String)
    case lastExitStatus
    case commandSubstitution(String)
}

public enum Redirection: Equatable, Sendable {
    case input(Word)
    case output(Word, append: Bool)
}

extension Word: CustomStringConvertible {
    public var description: String {
        segments.map { segment in
            switch segment {
            case .literal(let value):
                return value
            case .variable(let name):
                return "$\(name)"
            case .lastExitStatus:
                return "$?"
            case .commandSubstitution(let source):
                return "$(\(source))"
            }
        }.joined()
    }
}

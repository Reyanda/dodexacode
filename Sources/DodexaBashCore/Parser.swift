import Foundation

public enum ParserError: Error, CustomStringConvertible {
    case expectedCommand
    case missingRedirectionTarget
    case unexpectedToken(Token)

    public var description: String {
        switch self {
        case .expectedCommand:
            return "expected command"
        case .missingRedirectionTarget:
            return "missing redirection target"
        case .unexpectedToken(let token):
            return "unexpected token: \(token)"
        }
    }
}

public struct Parser {
    private let tokens: [Token]
    private var index: Int = 0

    public init(tokens: [Token]) {
        self.tokens = tokens
    }

    public mutating func parseScript() throws -> Script {
        var statements: [CommandNode] = []

        while !check(.eof) {
            if match(.semicolon) {
                continue
            }

            statements.append(try parseConditional())
            _ = match(.semicolon)
        }

        return Script(statements: statements)
    }

    private mutating func parseConditional() throws -> CommandNode {
        var node = try parsePipeline()

        while true {
            if match(.andIf) {
                let rhs = try parsePipeline()
                node = .conditional(lhs: node, op: .and, rhs: rhs)
            } else if match(.orIf) {
                let rhs = try parsePipeline()
                node = .conditional(lhs: node, op: .or, rhs: rhs)
            } else {
                break
            }
        }

        return node
    }

    private mutating func parsePipeline() throws -> CommandNode {
        var commands = [try parseSimpleCommand()]
        while match(.pipe) {
            commands.append(try parseSimpleCommand())
        }

        if commands.count == 1 {
            return .simple(commands[0])
        }

        return .pipeline(commands)
    }

    private mutating func parseSimpleCommand() throws -> SimpleCommand {
        var words: [Word] = []
        var redirections: [Redirection] = []

        while true {
            switch peek() {
            case .word(let word):
                advance()
                words.append(word)
            case .inputRedirect:
                advance()
                guard case .word(let target) = peek() else {
                    throw ParserError.missingRedirectionTarget
                }
                advance()
                redirections.append(.input(target))
            case .outputRedirect(let append):
                advance()
                guard case .word(let target) = peek() else {
                    throw ParserError.missingRedirectionTarget
                }
                advance()
                redirections.append(.output(target, append: append))
            default:
                if words.isEmpty, redirections.isEmpty {
                    throw ParserError.expectedCommand
                }
                return SimpleCommand(words: words, redirections: redirections)
            }
        }
    }

    private func peek() -> Token {
        tokens[index]
    }

    @discardableResult
    private mutating func advance() -> Token {
        defer { index += 1 }
        return tokens[index]
    }

    private func check(_ token: Token) -> Bool {
        peek() == token
    }

    private mutating func match(_ token: Token) -> Bool {
        guard check(token) else {
            return false
        }

        advance()
        return true
    }
}

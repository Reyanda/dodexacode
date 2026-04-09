import Foundation

public enum LexerError: Error, CustomStringConvertible {
    case unterminatedSingleQuote
    case unterminatedDoubleQuote
    case unterminatedCommandSubstitution
    case danglingEscape
    case missingVariableName

    public var description: String {
        switch self {
        case .unterminatedSingleQuote:
            return "unterminated single-quoted string"
        case .unterminatedDoubleQuote:
            return "unterminated double-quoted string"
        case .unterminatedCommandSubstitution:
            return "unterminated command substitution"
        case .danglingEscape:
            return "dangling escape at end of line"
        case .missingVariableName:
            return "missing variable name after '$'"
        }
    }
}

public enum Token: Equatable, Sendable {
    case word(Word)
    case pipe
    case andIf
    case orIf
    case semicolon
    case inputRedirect
    case outputRedirect(append: Bool)
    case eof
}

public struct Lexer {
    private let characters: [Character]
    private var index: Int = 0

    public init(source: String) {
        self.characters = Array(source)
    }

    public mutating func tokenize() throws -> [Token] {
        var tokens: [Token] = []

        while true {
            skipWhitespaceAndComments()
            guard !isAtEnd else {
                tokens.append(.eof)
                return tokens
            }

            let character = peek()
            switch character {
            case ";":
                advance()
                tokens.append(.semicolon)
            case "|":
                advance()
                if match("|") {
                    tokens.append(.orIf)
                } else {
                    tokens.append(.pipe)
                }
            case "&":
                advance()
                if match("&") {
                    tokens.append(.andIf)
                } else {
                    tokens.append(.word(Word(segments: [.literal("&")])))
                }
            case "<":
                advance()
                tokens.append(.inputRedirect)
            case ">":
                advance()
                tokens.append(.outputRedirect(append: match(">")))
            default:
                tokens.append(.word(try readWord()))
            }
        }
    }

    private var isAtEnd: Bool {
        index >= characters.count
    }

    private func peek() -> Character {
        characters[index]
    }

    @discardableResult
    private mutating func advance() -> Character {
        defer { index += 1 }
        return characters[index]
    }

    private mutating func match(_ expected: Character) -> Bool {
        guard !isAtEnd, characters[index] == expected else {
            return false
        }

        index += 1
        return true
    }

    private mutating func skipWhitespaceAndComments() {
        while !isAtEnd {
            let character = peek()
            if character.isWhitespace {
                advance()
                continue
            }

            if character == "#" {
                while !isAtEnd, peek() != "\n" {
                    advance()
                }
                continue
            }

            break
        }
    }

    private mutating func readWord() throws -> Word {
        var segments: [WordSegment] = []
        var literalBuffer = ""

        func flushLiteral() {
            guard !literalBuffer.isEmpty else { return }
            segments.append(.literal(literalBuffer))
            literalBuffer.removeAll(keepingCapacity: true)
        }

        while !isAtEnd {
            let character = peek()
            if character.isWhitespace || ";|&<>".contains(character) {
                break
            }

            switch character {
            case "'":
                advance()
                while !isAtEnd, peek() != "'" {
                    literalBuffer.append(advance())
                }
                guard !isAtEnd else {
                    throw LexerError.unterminatedSingleQuote
                }
                advance()
            case "\"":
                advance()
                while !isAtEnd, peek() != "\"" {
                    let inner = advance()
                    if inner == "\\" {
                        guard !isAtEnd else {
                            throw LexerError.danglingEscape
                        }
                        let escaped = advance()
                        if "\"\\$".contains(escaped) {
                            literalBuffer.append(escaped)
                        } else {
                            literalBuffer.append("\\")
                            literalBuffer.append(escaped)
                        }
                    } else if inner == "$" {
                        flushLiteral()
                        segments.append(try readVariableExpansion())
                    } else {
                        literalBuffer.append(inner)
                    }
                }
                guard !isAtEnd else {
                    throw LexerError.unterminatedDoubleQuote
                }
                advance()
            case "\\":
                advance()
                guard !isAtEnd else {
                    throw LexerError.danglingEscape
                }
                literalBuffer.append(advance())
            case "$":
                advance()
                flushLiteral()
                if match("(") {
                    segments.append(try readCommandSubstitution())
                } else {
                    segments.append(try readVariableExpansion(afterDollarConsumed: true))
                }
            default:
                literalBuffer.append(advance())
            }
        }

        flushLiteral()
        return Word(segments: segments)
    }

    private mutating func readVariableExpansion(afterDollarConsumed: Bool = false) throws -> WordSegment {
        if !afterDollarConsumed {
            guard !isAtEnd, advance() == "$" else {
                throw LexerError.missingVariableName
            }
        }

        guard !isAtEnd else {
            throw LexerError.missingVariableName
        }

        if match("?") {
            return .lastExitStatus
        }

        if match("{") {
            var name = ""
            while !isAtEnd, peek() != "}" {
                name.append(advance())
            }
            guard match("}") else {
                throw LexerError.missingVariableName
            }
            guard !name.isEmpty else {
                throw LexerError.missingVariableName
            }
            return .variable(name)
        }

        var name = ""
        while !isAtEnd {
            let character = peek()
            if character.isLetter || character.isNumber || character == "_" {
                name.append(advance())
            } else {
                break
            }
        }

        guard !name.isEmpty else {
            throw LexerError.missingVariableName
        }

        return .variable(name)
    }

    private mutating func readCommandSubstitution() throws -> WordSegment {
        var source = ""
        var depth = 1
        var inSingleQuote = false
        var inDoubleQuote = false

        while !isAtEnd {
            let character = advance()

            if character == "\\" {
                source.append(character)
                guard !isAtEnd else {
                    throw LexerError.danglingEscape
                }
                source.append(advance())
                continue
            }

            if !inDoubleQuote && character == "'" {
                inSingleQuote.toggle()
                source.append(character)
                continue
            }

            if !inSingleQuote && character == "\"" {
                inDoubleQuote.toggle()
                source.append(character)
                continue
            }

            if !inSingleQuote && character == "$" && !isAtEnd && peek() == "(" {
                depth += 1
                source.append(character)
                source.append(advance())
                continue
            }

            if !inSingleQuote && !inDoubleQuote && character == ")" {
                depth -= 1
                if depth == 0 {
                    return .commandSubstitution(source)
                }
            }

            source.append(character)
        }

        throw LexerError.unterminatedCommandSubstitution
    }
}

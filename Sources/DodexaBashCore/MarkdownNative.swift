import Foundation

public enum MarkdownNativeError: Error, CustomStringConvertible {
    case unreadableFile(String)

    public var description: String {
        switch self {
        case .unreadableFile(let path):
            return "could not read markdown file at \(path)"
        }
    }
}

public struct MarkdownCodeBlock: Codable, Sendable, Equatable {
    public let language: String?
    public let content: String
    public let lineStart: Int
    public let lineEnd: Int
}

public struct MarkdownSection: Codable, Sendable, Equatable {
    public let level: Int
    public let heading: String
    public let slug: String
    public let path: [String]
    public let lineStart: Int
    public let lineEnd: Int
    public let body: String
    public let bullets: [String]
    public let codeBlocks: [MarkdownCodeBlock]
}

public struct MarkdownDocument: Codable, Sendable, Equatable {
    public let path: String?
    public let title: String
    public let preamble: String
    public let sections: [MarkdownSection]
    public let wordCount: Int
    public let bulletCount: Int
    public let codeBlockCount: Int
}

public enum MarkdownNative {
    public static func load(from path: String, cwd: String? = nil) throws -> MarkdownDocument {
        let resolvedPath = resolve(path: path, cwd: cwd)
        guard let source = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
            throw MarkdownNativeError.unreadableFile(resolvedPath)
        }
        return parse(source, path: resolvedPath)
    }

    public static func parse(_ source: String, path: String? = nil) -> MarkdownDocument {
        let lines = source.components(separatedBy: .newlines)
        var sections: [MarkdownSection] = []
        var preambleLines: [String] = []
        var headingStack: [String] = []

        struct PendingSection {
            var level: Int
            var heading: String
            var path: [String]
            var lineStart: Int
            var bodyLines: [String]
        }

        var pending: PendingSection?

        func flushSection(endLine: Int) {
            guard let current = pending else { return }
            let analysis = analyze(bodyLines: current.bodyLines)
            let body = trimTrailingBlankLines(current.bodyLines).joined(separator: "\n")
            sections.append(
                MarkdownSection(
                    level: current.level,
                    heading: current.heading,
                    slug: slugify(current.path.joined(separator: "/")),
                    path: current.path,
                    lineStart: current.lineStart,
                    lineEnd: max(current.lineStart, endLine),
                    body: body,
                    bullets: analysis.bullets,
                    codeBlocks: analysis.codeBlocks
                )
            )
            pending = nil
        }

        for (index, line) in lines.enumerated() {
            if let heading = parseHeading(from: line) {
                flushSection(endLine: index)
                while headingStack.count >= heading.level {
                    headingStack.removeLast()
                }
                headingStack.append(heading.text)
                pending = PendingSection(
                    level: heading.level,
                    heading: heading.text,
                    path: headingStack,
                    lineStart: index + 1,
                    bodyLines: []
                )
                continue
            }

            if pending != nil {
                pending?.bodyLines.append(line)
            } else {
                preambleLines.append(line)
            }
        }

        flushSection(endLine: lines.count)

        if sections.isEmpty {
            let fallbackTitle = titleFromPath(path) ?? "Document"
            let analysis = analyze(bodyLines: lines)
            sections = [
                MarkdownSection(
                    level: 1,
                    heading: fallbackTitle,
                    slug: slugify(fallbackTitle),
                    path: [fallbackTitle],
                    lineStart: 1,
                    lineEnd: max(1, lines.count),
                    body: trimTrailingBlankLines(lines).joined(separator: "\n"),
                    bullets: analysis.bullets,
                    codeBlocks: analysis.codeBlocks
                )
            ]
        }

        let preamble = trimTrailingBlankLines(preambleLines).joined(separator: "\n")
        let title = sections.first(where: { $0.level == 1 })?.heading
            ?? sections.first?.heading
            ?? titleFromPath(path)
            ?? "Document"

        return MarkdownDocument(
            path: path,
            title: title,
            preamble: preamble,
            sections: sections,
            wordCount: wordCount(in: source),
            bulletCount: sections.reduce(0) { $0 + $1.bullets.count },
            codeBlockCount: sections.reduce(0) { $0 + $1.codeBlocks.count }
        )
    }

    public static func findSection(in document: MarkdownDocument, matching query: String) -> MarkdownSection? {
        let normalized = normalize(query)
        guard !normalized.isEmpty else { return nil }

        if let exact = document.sections.first(where: { sectionLookupKeys($0).contains(normalized) }) {
            return exact
        }

        return document.sections.first { section in
            sectionLookupKeys(section).contains { $0.contains(normalized) }
        }
    }

    public static func resolve(path: String, cwd: String?) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let base = cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
    }

    private static func sectionLookupKeys(_ section: MarkdownSection) -> [String] {
        let pathSlash = section.path.joined(separator: "/")
        let pathChevron = section.path.joined(separator: " > ")
        return [
            normalize(section.heading),
            normalize(section.slug),
            normalize(pathSlash),
            normalize(pathChevron)
        ]
    }

    private static func parseHeading(from line: String) -> (level: Int, text: String)? {
        let stripped = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard stripped.hasPrefix("#") else {
            return nil
        }

        let hashes = stripped.prefix(while: { $0 == "#" })
        let level = hashes.count
        guard (1...6).contains(level) else {
            return nil
        }

        let rest = stripped.dropFirst(level)
        guard rest.first == " " || rest.first == "\t" else {
            return nil
        }

        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? nil : (level, text)
    }

    private static func analyze(bodyLines: [String]) -> (bullets: [String], codeBlocks: [MarkdownCodeBlock]) {
        var bullets: [String] = []
        var codeBlocks: [MarkdownCodeBlock] = []
        var fenceLanguage: String?
        var fenceStartLine: Int?
        var fenceLines: [String] = []

        for (index, line) in bodyLines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let startLine = fenceStartLine {
                    codeBlocks.append(
                        MarkdownCodeBlock(
                            language: fenceLanguage,
                            content: fenceLines.joined(separator: "\n"),
                            lineStart: startLine,
                            lineEnd: index + 1
                        )
                    )
                    fenceLanguage = nil
                    fenceStartLine = nil
                    fenceLines.removeAll(keepingCapacity: true)
                } else {
                    let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    fenceLanguage = language.isEmpty ? nil : language
                    fenceStartLine = index + 1
                }
                continue
            }

            if fenceStartLine != nil {
                fenceLines.append(line)
                continue
            }

            if let bullet = bulletText(from: trimmed) {
                bullets.append(bullet)
            }
        }

        if let startLine = fenceStartLine {
            codeBlocks.append(
                MarkdownCodeBlock(
                    language: fenceLanguage,
                    content: fenceLines.joined(separator: "\n"),
                    lineStart: startLine,
                    lineEnd: bodyLines.count
                )
            )
        }

        return (bullets, codeBlocks)
    }

    private static func bulletText(from trimmed: String) -> String? {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else {
            return nil
        }

        let remainder = trimmed.dropFirst(digits.count)
        guard let marker = remainder.first, marker == "." || marker == ")" else {
            return nil
        }

        let body = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    private static func wordCount(in source: String) -> Int {
        source.split { $0.isWhitespace || $0.isNewline }.count
    }

    private static func trimTrailingBlankLines(_ lines: [String]) -> [String] {
        var output = lines
        while let last = output.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            output.removeLast()
        }
        return output
    }

    private static func titleFromPath(_ path: String?) -> String? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private static func slugify(_ value: String) -> String {
        let lowered = value.lowercased()
        let mapped = lowered.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }

        var slug = String(mapped)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "  ", with: " ")
    }
}

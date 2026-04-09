import Foundation

// MARK: - Codebase Index: Local Symbol Index for AI Context
// Indexes git-tracked files to extract symbols (functions, types, imports)
// and feed them to the brain for context-aware AI.
// Persists to .dodexabash/index.json. Incrementally updates on file changes.

// MARK: - Symbol Types

public enum SymbolKind: String, Codable, Sendable {
    case function
    case method
    case classDecl      = "class"
    case structDecl     = "struct"
    case enumDecl       = "enum"
    case protocolDecl   = "protocol"
    case interfaceDecl  = "interface"
    case typeAlias      = "typealias"
    case variable
    case constant
    case importDecl     = "import"
    case module
}

public struct IndexedSymbol: Codable, Sendable {
    public let name: String
    public let kind: SymbolKind
    public let file: String       // relative path
    public let line: Int
    public let signature: String? // e.g. "func foo(bar: Int) -> String"
    public let scope: String?     // e.g. "Shell" for methods inside Shell class
}

public struct IndexedFile: Codable, Sendable {
    public let path: String
    public let language: String
    public let lines: Int
    public let size: Int
    public let lastModified: Date
    public let contentHash: UInt64
    public let imports: [String]
    public let symbols: [IndexedSymbol]
    public let summary: String    // first-line doc comment or top-level description
}

public struct CodebaseSnapshot: Codable, Sendable {
    public var version: Int = 1
    public var indexedAt: Date = Date()
    public var rootPath: String = ""
    public var files: [IndexedFile] = []
    public var totalSymbols: Int = 0
    public var totalFiles: Int = 0
    public var totalLines: Int = 0
}

// MARK: - Codebase Indexer

public final class CodebaseIndexer: @unchecked Sendable {
    private let persistURL: URL
    private var snapshot: CodebaseSnapshot
    private let maxFileSize = 512_000  // 500KB max per file
    private let maxFiles = 8000

    private let indexableExtensions: Set<String> = [
        "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "c", "cpp", "h", "hpp",
        "java", "rb", "kt", "scala", "cs", "m", "mm", "sh", "bash", "zsh",
        "lua", "zig", "hs", "ex", "exs", "erl", "ml", "mli", "dart", "r", "jl",
        "php", "vue", "svelte"
    ]

    private let ignoreNames: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "__pycache__", "DerivedData",
        "dist", "build", "vendor", "Pods", ".cache", ".next", "coverage", "tmp",
        "dump_ground", ".dodexabash", ".DS_Store", "target"
    ]

    public init(directory: URL) {
        self.persistURL = directory.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: persistURL),
           let saved = try? JSONDecoder().decode(CodebaseSnapshot.self, from: data) {
            self.snapshot = saved
        } else {
            self.snapshot = CodebaseSnapshot()
        }
    }

    // MARK: - Index

    public func index(at rootPath: String, incremental: Bool = true) -> CodebaseSnapshot {
        let root = URL(fileURLWithPath: rootPath)
        let fm = FileManager.default

        // Build existing file hash map for incremental
        let existingHashes: [String: UInt64]
        if incremental && snapshot.rootPath == rootPath {
            existingHashes = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0.contentHash) })
        } else {
            existingHashes = [:]
        }

        var files: [IndexedFile] = []
        var totalSymbols = 0
        var totalLines = 0

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return snapshot
        }

        while let url = enumerator.nextObject() as? URL, files.count < maxFiles {
            let name = url.lastPathComponent
            if ignoreNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            guard indexableExtensions.contains(ext) else { continue }

            let size = values.fileSize ?? 0
            guard size <= maxFileSize, size > 0 else { continue }

            let relativePath = makeRelative(url.path, root: root.path)
            let modified = values.contentModificationDate ?? Date()

            // Read file content
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let hash = fnvHash(content)

            // Skip unchanged files in incremental mode
            if let existingHash = existingHashes[relativePath], existingHash == hash {
                if let existingFile = snapshot.files.first(where: { $0.path == relativePath }) {
                    files.append(existingFile)
                    totalSymbols += existingFile.symbols.count
                    totalLines += existingFile.lines
                    continue
                }
            }

            let language = languageName(ext)
            let lines = content.components(separatedBy: "\n")
            let lineCount = lines.count

            // Extract symbols based on language
            let extractor = symbolExtractor(for: ext)
            let symbols = extractor(content, relativePath)
            let imports = extractImports(content, language: ext)
            let summary = extractSummary(lines)

            let indexed = IndexedFile(
                path: relativePath,
                language: language,
                lines: lineCount,
                size: size,
                lastModified: modified,
                contentHash: hash,
                imports: imports,
                symbols: symbols,
                summary: summary
            )

            files.append(indexed)
            totalSymbols += symbols.count
            totalLines += lineCount
        }

        snapshot = CodebaseSnapshot(
            version: 1,
            indexedAt: Date(),
            rootPath: rootPath,
            files: files.sorted { $0.path < $1.path },
            totalSymbols: totalSymbols,
            totalFiles: files.count,
            totalLines: totalLines
        )

        persist()
        return snapshot
    }

    // MARK: - Query

    public var current: CodebaseSnapshot { snapshot }

    public func searchSymbols(query: String, limit: Int = 20) -> [IndexedSymbol] {
        let lowered = query.lowercased()
        var results: [IndexedSymbol] = []
        for file in snapshot.files {
            for symbol in file.symbols {
                if symbol.name.lowercased().contains(lowered) ||
                   (symbol.signature?.lowercased().contains(lowered) ?? false) {
                    results.append(symbol)
                    if results.count >= limit { return results }
                }
            }
        }
        return results
    }

    public func symbolsInFile(_ path: String) -> [IndexedSymbol] {
        snapshot.files.first { $0.path == path }?.symbols ?? []
    }

    public func filesImporting(_ module: String) -> [String] {
        snapshot.files.filter { $0.imports.contains(module) }.map(\.path)
    }

    public func filesByLanguage(_ language: String) -> [IndexedFile] {
        snapshot.files.filter { $0.language.lowercased() == language.lowercased() }
    }

    /// Compact context string for AI brain — most important symbols and structure
    public func contextForBrain(limit: Int = 2000) -> String {
        guard !snapshot.files.isEmpty else { return "" }

        var parts: [String] = []
        parts.append("Indexed: \(snapshot.totalFiles) files, \(snapshot.totalSymbols) symbols, \(snapshot.totalLines) lines")

        // Top-level types and their methods
        var typeMap: [String: [String]] = [:]  // type -> methods
        var topFunctions: [String] = []

        for file in snapshot.files {
            for symbol in file.symbols {
                switch symbol.kind {
                case .classDecl, .structDecl, .enumDecl, .protocolDecl, .interfaceDecl:
                    typeMap[symbol.name] = []
                case .method, .function:
                    if let scope = symbol.scope {
                        typeMap[scope, default: []].append(symbol.name)
                    } else {
                        topFunctions.append(symbol.signature ?? symbol.name)
                    }
                default:
                    break
                }
            }
        }

        // Types with their methods (most useful for AI context)
        let sortedTypes = typeMap.sorted { $0.value.count > $1.value.count }
        for (type, methods) in sortedTypes.prefix(15) {
            if methods.isEmpty {
                parts.append("  \(type)")
            } else {
                let methodList = methods.prefix(8).joined(separator: ", ")
                let more = methods.count > 8 ? " +\(methods.count - 8)" : ""
                parts.append("  \(type): \(methodList)\(more)")
            }
        }

        // Top free functions
        if !topFunctions.isEmpty {
            let funcList = topFunctions.prefix(10).joined(separator: "; ")
            parts.append("  Functions: \(funcList)")
        }

        // Import graph (most imported modules)
        var importCounts: [String: Int] = [:]
        for file in snapshot.files {
            for imp in file.imports {
                importCounts[imp, default: 0] += 1
            }
        }
        let topImports = importCounts.sorted { $0.value > $1.value }.prefix(10)
        if !topImports.isEmpty {
            parts.append("  Imports: " + topImports.map { "\($0.key)(\($0.value))" }.joined(separator: ", "))
        }

        var result = parts.joined(separator: "\n")
        if result.count > limit {
            result = String(result.prefix(limit)) + "..."
        }
        return result
    }

    // MARK: - Symbol Extractors (per language)

    private func symbolExtractor(for ext: String) -> (String, String) -> [IndexedSymbol] {
        switch ext {
        case "swift": return extractSwiftSymbols
        case "py": return extractPythonSymbols
        case "js", "jsx", "ts", "tsx", "vue", "svelte": return extractJSSymbols
        case "go": return extractGoSymbols
        case "rs": return extractRustSymbols
        case "c", "cpp", "h", "hpp", "m", "mm": return extractCSymbols
        case "java", "kt", "scala", "cs": return extractJavaLikeSymbols
        case "rb": return extractRubySymbols
        default: return extractGenericSymbols
        }
    }

    // MARK: Swift

    private func extractSwiftSymbols(_ content: String, _ file: String) -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []
        var currentScope: String?
        var braceDepth = 0
        var scopeDepth = 0

        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") { continue }

            // Track brace depth for scope
            braceDepth += trimmed.filter({ $0 == "{" }).count
            braceDepth -= trimmed.filter({ $0 == "}" }).count
            if braceDepth <= scopeDepth { currentScope = nil }

            // Classes, structs, enums, protocols
            if let match = matchDecl(trimmed, keywords: ["class", "struct", "enum", "protocol", "actor"]) {
                let kind: SymbolKind
                if trimmed.contains("class ") { kind = .classDecl }
                else if trimmed.contains("struct ") { kind = .structDecl }
                else if trimmed.contains("enum ") { kind = .enumDecl }
                else if trimmed.contains("protocol ") { kind = .protocolDecl }
                else { kind = .classDecl }

                currentScope = match
                scopeDepth = braceDepth - 1
                symbols.append(IndexedSymbol(name: match, kind: kind, file: file, line: i + 1,
                                            signature: extractSignature(trimmed), scope: nil))
            }
            // Functions
            else if trimmed.contains("func "), let name = extractFuncName(trimmed, keyword: "func") {
                let kind: SymbolKind = currentScope != nil ? .method : .function
                symbols.append(IndexedSymbol(name: name, kind: kind, file: file, line: i + 1,
                                            signature: extractSignature(trimmed), scope: currentScope))
            }
            // Typealiases
            else if trimmed.hasPrefix("typealias ") || trimmed.hasPrefix("public typealias ") {
                if let name = extractWordAfter(trimmed, keyword: "typealias") {
                    symbols.append(IndexedSymbol(name: name, kind: .typeAlias, file: file, line: i + 1,
                                                signature: extractSignature(trimmed), scope: currentScope))
                }
            }
        }
        return symbols
    }

    // MARK: Python

    private func extractPythonSymbols(_ content: String, _ file: String) -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []
        var currentClass: String?

        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("class ") {
                if let name = extractWordAfter(trimmed, keyword: "class") {
                    currentClass = name
                    symbols.append(IndexedSymbol(name: name, kind: .classDecl, file: file, line: i + 1,
                                                signature: extractSignature(trimmed), scope: nil))
                }
            } else if trimmed.hasPrefix("def ") || trimmed.hasPrefix("async def ") {
                let keyword = trimmed.hasPrefix("async") ? "def" : "def"
                if let name = extractFuncName(trimmed, keyword: keyword) {
                    let isMethod = line.hasPrefix("    ") && currentClass != nil
                    symbols.append(IndexedSymbol(name: name, kind: isMethod ? .method : .function, file: file, line: i + 1,
                                                signature: extractSignature(trimmed), scope: isMethod ? currentClass : nil))
                }
            }
            // Reset class scope on unindented non-empty line
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty && !trimmed.hasPrefix("class ") {
                currentClass = nil
            }
        }
        return symbols
    }

    // MARK: JavaScript / TypeScript

    private func extractJSSymbols(_ content: String, _ file: String) -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []

        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") { continue }

            if trimmed.contains("class ") {
                if let name = extractWordAfter(trimmed, keyword: "class") {
                    symbols.append(IndexedSymbol(name: name, kind: .classDecl, file: file, line: i + 1,
                                                signature: extractSignature(trimmed), scope: nil))
                }
            }
            if trimmed.contains("interface ") {
                if let name = extractWordAfter(trimmed, keyword: "interface") {
                    symbols.append(IndexedSymbol(name: name, kind: .interfaceDecl, file: file, line: i + 1,
                                                signature: extractSignature(trimmed), scope: nil))
                }
            }
            if trimmed.hasPrefix("function ") || trimmed.hasPrefix("async function ") || trimmed.hasPrefix("export function ") || trimmed.hasPrefix("export async function ") {
                if let name = extractFuncName(trimmed, keyword: "function") {
                    symbols.append(IndexedSymbol(name: name, kind: .function, file: file, line: i + 1,
                                                signature: extractSignature(trimmed), scope: nil))
                }
            }
            // Arrow functions: const name = (...) =>
            if (trimmed.hasPrefix("const ") || trimmed.hasPrefix("export const ")) && trimmed.contains("=>") {
                if let name = extractWordAfter(trimmed, keyword: "const") {
                    symbols.append(IndexedSymbol(name: name, kind: .function, file: file, line: i + 1,
                                                signature: extractSignature(trimmed), scope: nil))
                }
            }
            // Type aliases
            if trimmed.hasPrefix("type ") || trimmed.hasPrefix("export type ") {
                if let name = extractWordAfter(trimmed, keyword: "type") {
                    symbols.append(IndexedSymbol(name: name, kind: .typeAlias, file: file, line: i + 1,
                                                signature: nil, scope: nil))
                }
            }
        }
        return symbols
    }

    // MARK: Go

    private func extractGoSymbols(_ content: String, _ file: String) -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []
        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }

            if trimmed.hasPrefix("func ") {
                // Method: func (r *Receiver) Name(...)
                // Function: func Name(...)
                if trimmed.contains("(") && trimmed.dropFirst(5).first == "(" {
                    // Method
                    if let name = extractGoMethodName(trimmed) {
                        symbols.append(IndexedSymbol(name: name, kind: .method, file: file, line: i + 1,
                                                    signature: extractSignature(trimmed), scope: nil))
                    }
                } else if let name = extractFuncName(trimmed, keyword: "func") {
                    symbols.append(IndexedSymbol(name: name, kind: .function, file: file, line: i + 1,
                                                signature: extractSignature(trimmed), scope: nil))
                }
            }
            if trimmed.hasPrefix("type ") {
                if let name = extractWordAfter(trimmed, keyword: "type") {
                    let kind: SymbolKind = trimmed.contains("struct") ? .structDecl :
                                          trimmed.contains("interface") ? .interfaceDecl : .typeAlias
                    symbols.append(IndexedSymbol(name: name, kind: kind, file: file, line: i + 1,
                                                signature: nil, scope: nil))
                }
            }
        }
        return symbols
    }

    // MARK: Rust

    private func extractRustSymbols(_ content: String, _ file: String) -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []
        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }

            if trimmed.contains("fn ") {
                if let name = extractFuncName(trimmed, keyword: "fn") {
                    symbols.append(IndexedSymbol(name: name, kind: .function, file: file, line: i + 1,
                                                signature: extractSignature(trimmed), scope: nil))
                }
            }
            for keyword in ["struct", "enum", "trait"] {
                if trimmed.hasPrefix("pub \(keyword) ") || trimmed.hasPrefix("\(keyword) ") {
                    if let name = extractWordAfter(trimmed, keyword: keyword) {
                        let kind: SymbolKind = keyword == "struct" ? .structDecl :
                                              keyword == "enum" ? .enumDecl : .protocolDecl
                        symbols.append(IndexedSymbol(name: name, kind: kind, file: file, line: i + 1,
                                                    signature: nil, scope: nil))
                    }
                }
            }
        }
        return symbols
    }

    // MARK: C/C++/Obj-C

    private func extractCSymbols(_ content: String, _ file: String) -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []
        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("#") { continue }

            // Class/struct
            for keyword in ["class", "struct"] {
                if trimmed.hasPrefix("\(keyword) ") {
                    if let name = extractWordAfter(trimmed, keyword: keyword) {
                        symbols.append(IndexedSymbol(name: name, kind: keyword == "class" ? .classDecl : .structDecl,
                                                    file: file, line: i + 1, signature: nil, scope: nil))
                    }
                }
            }
            // Function: type name(...) {
            if trimmed.contains("(") && !trimmed.hasPrefix("if") && !trimmed.hasPrefix("for") &&
               !trimmed.hasPrefix("while") && !trimmed.hasPrefix("switch") && !trimmed.hasPrefix("return") {
                if let name = extractCFunctionName(trimmed) {
                    symbols.append(IndexedSymbol(name: name, kind: .function, file: file, line: i + 1,
                                                signature: extractSignature(trimmed), scope: nil))
                }
            }
        }
        return symbols
    }

    // MARK: Java-like (Java, Kotlin, Scala, C#)

    private func extractJavaLikeSymbols(_ content: String, _ file: String) -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []
        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") { continue }

            for keyword in ["class", "interface", "enum"] {
                if trimmed.contains("\(keyword) ") {
                    if let name = extractWordAfter(trimmed, keyword: keyword) {
                        let kind: SymbolKind = keyword == "class" ? .classDecl :
                                              keyword == "interface" ? .interfaceDecl : .enumDecl
                        symbols.append(IndexedSymbol(name: name, kind: kind, file: file, line: i + 1,
                                                    signature: nil, scope: nil))
                    }
                }
            }
        }
        return symbols
    }

    // MARK: Ruby

    private func extractRubySymbols(_ content: String, _ file: String) -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []
        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("class ") {
                if let name = extractWordAfter(trimmed, keyword: "class") {
                    symbols.append(IndexedSymbol(name: name, kind: .classDecl, file: file, line: i + 1,
                                                signature: nil, scope: nil))
                }
            }
            if trimmed.hasPrefix("module ") {
                if let name = extractWordAfter(trimmed, keyword: "module") {
                    symbols.append(IndexedSymbol(name: name, kind: .module, file: file, line: i + 1,
                                                signature: nil, scope: nil))
                }
            }
            if trimmed.hasPrefix("def ") {
                if let name = extractFuncName(trimmed, keyword: "def") {
                    symbols.append(IndexedSymbol(name: name, kind: .method, file: file, line: i + 1,
                                                signature: extractSignature(trimmed), scope: nil))
                }
            }
        }
        return symbols
    }

    // MARK: Generic fallback

    private func extractGenericSymbols(_ content: String, _ file: String) -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []
        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for keyword in ["func ", "function ", "def ", "fn ", "class ", "struct "] {
                if trimmed.contains(keyword) {
                    let kw = keyword.trimmingCharacters(in: .whitespaces)
                    if let name = extractWordAfter(trimmed, keyword: kw) {
                        let kind: SymbolKind = ["class", "struct"].contains(kw) ? .classDecl : .function
                        symbols.append(IndexedSymbol(name: name, kind: kind, file: file, line: i + 1,
                                                    signature: extractSignature(trimmed), scope: nil))
                    }
                }
            }
        }
        return symbols
    }

    // MARK: - Import Extraction

    private func extractImports(_ content: String, language ext: String) -> [String] {
        var imports: [String] = []
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            switch ext {
            case "swift":
                if trimmed.hasPrefix("import ") {
                    imports.append(String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
                }
            case "py":
                if trimmed.hasPrefix("import ") {
                    imports.append(String(trimmed.dropFirst(7)).components(separatedBy: " ").first ?? "")
                } else if trimmed.hasPrefix("from ") {
                    let parts = trimmed.components(separatedBy: " ")
                    if parts.count >= 2 { imports.append(parts[1]) }
                }
            case "js", "jsx", "ts", "tsx":
                if trimmed.contains("require(") || trimmed.contains("from '") || trimmed.contains("from \"") {
                    if let quoted = extractQuotedString(trimmed) { imports.append(quoted) }
                }
            case "go":
                if trimmed.hasPrefix("import ") || (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) {
                    if let quoted = extractQuotedString(trimmed) { imports.append(quoted) }
                }
            case "rs":
                if trimmed.hasPrefix("use ") {
                    let mod = String(trimmed.dropFirst(4)).components(separatedBy: ":").first?.trimmingCharacters(in: .init(charactersIn: ";")) ?? ""
                    imports.append(mod)
                }
            case "java", "kt", "scala":
                if trimmed.hasPrefix("import ") {
                    imports.append(String(trimmed.dropFirst(7)).trimmingCharacters(in: .init(charactersIn: ";")))
                }
            default:
                break
            }
        }
        return imports.filter { !$0.isEmpty }
    }

    // MARK: - Helpers

    private func matchDecl(_ line: String, keywords: [String]) -> String? {
        for keyword in keywords {
            if let name = extractWordAfter(line, keyword: keyword) {
                // Verify it's a declaration, not just usage
                let stripped = line.replacingOccurrences(of: "public ", with: "")
                    .replacingOccurrences(of: "private ", with: "")
                    .replacingOccurrences(of: "internal ", with: "")
                    .replacingOccurrences(of: "final ", with: "")
                    .replacingOccurrences(of: "open ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if stripped.hasPrefix(keyword + " ") { return name }
            }
        }
        return nil
    }

    private func extractWordAfter(_ line: String, keyword: String) -> String? {
        guard let range = line.range(of: keyword + " ") else { return nil }
        let after = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let name = after.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
        return name.isEmpty ? nil : String(name)
    }

    private func extractFuncName(_ line: String, keyword: String) -> String? {
        guard let range = line.range(of: keyword + " ") else { return nil }
        let after = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        let name = after.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
        return name.isEmpty ? nil : String(name)
    }

    private func extractGoMethodName(_ line: String) -> String? {
        // func (r *Type) Name(...)
        guard let closeIdx = line.firstIndex(of: ")") else { return nil }
        let afterReceiver = String(line[line.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)
        let name = afterReceiver.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
        return name.isEmpty ? nil : String(name)
    }

    private func extractCFunctionName(_ line: String) -> String? {
        guard let parenIdx = line.firstIndex(of: "(") else { return nil }
        let beforeParen = String(line[..<parenIdx]).trimmingCharacters(in: .whitespaces)
        let words = beforeParen.split(separator: " ")
        guard let last = words.last else { return nil }
        let name = last.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "*" })
            .trimmingCharacters(in: .init(charactersIn: "*"))
        return name.isEmpty ? nil : name
    }

    private func extractSignature(_ line: String) -> String {
        var sig = line.trimmingCharacters(in: .whitespaces)
        // Remove body
        if let braceIdx = sig.firstIndex(of: "{") {
            sig = String(sig[..<braceIdx]).trimmingCharacters(in: .whitespaces)
        }
        // Truncate long signatures
        if sig.count > 120 { sig = String(sig.prefix(120)) + "..." }
        return sig
    }

    private func extractSummary(_ lines: [String]) -> String {
        // First doc comment or non-empty line
        for line in lines.prefix(10) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("///") || trimmed.hasPrefix("/**") || trimmed.hasPrefix("# ") {
                return String(trimmed.drop(while: { $0 == "/" || $0 == "*" || $0 == "#" || $0 == " " }))
                    .trimmingCharacters(in: .whitespaces)
            }
            if trimmed.hasPrefix("\"\"\"") { continue }
            if !trimmed.isEmpty && !trimmed.hasPrefix("//") && !trimmed.hasPrefix("import") && !trimmed.hasPrefix("#") {
                return String(trimmed.prefix(80))
            }
        }
        return ""
    }

    private func extractQuotedString(_ line: String) -> String? {
        for quote in ["'", "\""] as [Character] {
            if let start = line.firstIndex(of: quote) {
                let after = line[line.index(after: start)...]
                if let end = after.firstIndex(of: quote) {
                    return String(after[..<end])
                }
            }
        }
        return nil
    }

    private func makeRelative(_ path: String, root: String) -> String {
        let rootSlash = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(rootSlash) { return String(path.dropFirst(rootSlash.count)) }
        return path
    }

    private func languageName(_ ext: String) -> String {
        switch ext {
        case "swift": return "Swift"
        case "py": return "Python"
        case "js": return "JavaScript"
        case "ts": return "TypeScript"
        case "tsx": return "TSX"
        case "jsx": return "JSX"
        case "go": return "Go"
        case "rs": return "Rust"
        case "c", "h": return "C"
        case "cpp", "hpp": return "C++"
        case "m", "mm": return "Objective-C"
        case "java": return "Java"
        case "kt": return "Kotlin"
        case "rb": return "Ruby"
        case "sh", "bash", "zsh": return "Shell"
        case "lua": return "Lua"
        case "zig": return "Zig"
        case "dart": return "Dart"
        case "cs": return "C#"
        case "scala": return "Scala"
        case "vue": return "Vue"
        case "svelte": return "Svelte"
        default: return ext.uppercased()
        }
    }

    private func fnvHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: persistURL, options: .atomic)
    }
}

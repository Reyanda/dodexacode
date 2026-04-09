import Foundation

public struct WorkspaceBrief: Codable, Sendable {
    public struct SymbolCounts: Codable, Sendable {
        public let classes: Int
        public let functions: Int
        public let types: Int
    }

    public let workspace: String
    public let totalFiles: Int
    public let totalLines: Int
    public let languageBreakdown: [String: Int]
    public let rootBreakdown: [String: Int]
    public let keyFiles: [String]
    public let recentFiles: [String]
    public let symbolCounts: SymbolCounts
    public let compactText: String
    public let fingerprint: String
}

public final class WorkspaceBriefer {
    private let ignoreNames: Set<String> = [
        // Build / package artifacts
        ".git", ".build", ".swiftpm", "node_modules", "__pycache__", "BuildData", "dist", "DerivedData",
        "dump_ground", "vendor", "Pods", "build", ".cache", ".next", ".nuxt", "coverage", "tmp",
        // macOS system / personal directories
        "Library", "Movies", "Music", "Pictures", "Public", "Applications",
        "Desktop", "Downloads", "Receipts", "Zotero", "Archives",
        ".Trash", ".local", ".npm", ".cargo", ".rustup", ".gem",
        "OneDrive", "OneDrive - Queen Mary, University of London",
        // Broad project containers (scan the project itself, not from ~)
        "Documents", "Projects", "Benovolence", "reyanda", "outlook-mcp",
        ".docker", ".kube", ".ssh", ".gnupg", ".config", ".ollama"
    ]
    private let includeExtensions: Set<String> = [
        "swift", "py", "js", "ts", "tsx", "jsx", "md", "json", "yaml", "yml", "toml", "sh", "c", "cpp", "h", "hpp", "go", "rs", "java", "rb", "html", "css"
    ]
    private let maxFiles = 5000

    public init() {}

    public func generate(atPath path: String) -> WorkspaceBrief {
        let rootURL = URL(fileURLWithPath: path)
        var totalFiles = 0
        var totalLines = 0
        var languageBreakdown: [String: Int] = [:]
        var rootBreakdown: [String: Int] = [:]
        var recentCandidates: [(path: String, date: Date)] = []
        var keyFiles: [String] = []
        var classCount = 0
        var functionCount = 0
        var typeCount = 0

        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL, totalFiles < maxFiles {
            let pathComponents = fileURL.pathComponents
            if pathComponents.contains(where: { ignoreNames.contains($0) }) {
                enumerator?.skipDescendants()
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            if !includeExtensions.contains(ext) {
                continue
            }

            totalFiles += 1
            let relativePath = safeRelativePath(fileURL, root: rootURL)
            if let first = relativePath.split(separator: "/").first {
                rootBreakdown[String(first), default: 0] += 1
            } else {
                rootBreakdown["."] = 1
            }

            let language = languageName(forExtension: ext)
            languageBreakdown[language, default: 0] += 1

            if isKeyFile(fileURL.lastPathComponent) {
                keyFiles.append(relativePath)
            }

            if let date = values.contentModificationDate {
                recentCandidates.append((relativePath, date))
            }

            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            totalLines += text.split(separator: "\n", omittingEmptySubsequences: false).count
            let symbolCounts = countSymbols(in: text)
            classCount += symbolCounts.classes
            functionCount += symbolCounts.functions
            typeCount += symbolCounts.types
        }

        let topLanguages = languageBreakdown.sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
        let topRoots = rootBreakdown.sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
        let recentFiles = recentCandidates
            .sorted { $0.date > $1.date }
            .prefix(6)
            .map(\.path)
        let summary = WorkspaceBrief(
            workspace: rootURL.path,
            totalFiles: totalFiles,
            totalLines: totalLines,
            languageBreakdown: Dictionary(uniqueKeysWithValues: topLanguages.prefix(8).map { ($0.key, $0.value) }),
            rootBreakdown: Dictionary(uniqueKeysWithValues: topRoots.prefix(8).map { ($0.key, $0.value) }),
            keyFiles: Array(keyFiles.prefix(8)),
            recentFiles: recentFiles,
            symbolCounts: .init(classes: classCount, functions: functionCount, types: typeCount),
            compactText: "",
            fingerprint: ""
        )
        let compact = render(summary)

        return WorkspaceBrief(
            workspace: summary.workspace,
            totalFiles: summary.totalFiles,
            totalLines: summary.totalLines,
            languageBreakdown: summary.languageBreakdown,
            rootBreakdown: summary.rootBreakdown,
            keyFiles: summary.keyFiles,
            recentFiles: summary.recentFiles,
            symbolCounts: summary.symbolCounts,
            compactText: compact,
            fingerprint: stableFingerprint(compact)
        )
    }

    private func safeRelativePath(_ fileURL: URL, root: URL) -> String {
        let filePath = fileURL.path
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if filePath.hasPrefix(rootPath) {
            return String(filePath.dropFirst(rootPath.count))
        }
        return fileURL.lastPathComponent
    }

    private func languageName(forExtension ext: String) -> String {
        switch ext {
        case "swift": return "Swift"
        case "py": return "Python"
        case "js": return "JavaScript"
        case "ts": return "TypeScript"
        case "tsx": return "TSX"
        case "jsx": return "JSX"
        case "md": return "Markdown"
        case "json": return "JSON"
        case "yaml", "yml": return "YAML"
        case "toml": return "TOML"
        case "sh": return "Shell"
        case "c": return "C"
        case "cpp", "hpp", "h": return "C++"
        case "go": return "Go"
        case "rs": return "Rust"
        case "java": return "Java"
        case "rb": return "Ruby"
        case "html": return "HTML"
        case "css": return "CSS"
        default: return ext.uppercased()
        }
    }

    private func isKeyFile(_ name: String) -> Bool {
        ["README.md", "Package.swift", "package.json", "pyproject.toml", ".mcp.json"].contains(name)
    }

    private static let classRegex = try? NSRegularExpression(pattern: #"^\s*(?:class|struct)\s+[A-Za-z_]"#, options: [.anchorsMatchLines])
    private static let functionRegex = try? NSRegularExpression(pattern: #"^\s*(?:def|func|fn|function|async\s+function)\s+[A-Za-z_]"#, options: [.anchorsMatchLines])
    private static let typeRegex = try? NSRegularExpression(pattern: #"^\s*(?:protocol|enum|typealias|interface|type)\s+[A-Za-z_]"#, options: [.anchorsMatchLines])

    private func countSymbols(in text: String) -> WorkspaceBrief.SymbolCounts {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        return .init(
            classes: Self.classRegex?.numberOfMatches(in: text, range: fullRange) ?? 0,
            functions: Self.functionRegex?.numberOfMatches(in: text, range: fullRange) ?? 0,
            types: Self.typeRegex?.numberOfMatches(in: text, range: fullRange) ?? 0
        )
    }

    private func render(_ brief: WorkspaceBrief) -> String {
        var lines: [String] = []
        lines.append("Workspace: \(brief.workspace)")
        lines.append("Files: \(brief.totalFiles)  Lines: \(brief.totalLines)")
        if !brief.languageBreakdown.isEmpty {
            lines.append(
                "Languages: " + brief.languageBreakdown
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: ", ")
            )
        }
        if !brief.rootBreakdown.isEmpty {
            lines.append(
                "Roots: " + brief.rootBreakdown
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: ", ")
            )
        }
        lines.append(
            "Symbols: \(brief.symbolCounts.classes) classes, \(brief.symbolCounts.functions) functions, \(brief.symbolCounts.types) types"
        )
        if !brief.keyFiles.isEmpty {
            lines.append("Key files: " + brief.keyFiles.joined(separator: ", "))
        }
        if !brief.recentFiles.isEmpty {
            lines.append("Recent: " + brief.recentFiles.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private func stableFingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%012llx", hash & 0xFFFFFFFFFFFF)
    }
}

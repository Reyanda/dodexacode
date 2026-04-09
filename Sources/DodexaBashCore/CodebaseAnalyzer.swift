import Foundation

// MARK: - Codebase Analyzer: Specialized Domain Intelligence
// Analyzes codebases for specific domain patterns (Web, Stat/Data, Security)
// to provide high-level architectural insights matching expert AI capabilities.

public enum AnalyzerDomain: String {
    case web
    case stat
    case sec
    case arch
}

public struct AnalysisReport: Codable, Sendable {
    public let domain: String
    public let rootPath: String
    public let primaryLanguages: [String]
    public let frameworks: [String]
    public let entryPoints: [String]
    public let insights: [String]
    public let riskFactors: [String]?
    public let dependencies: [String]
}

public final class CodebaseAnalyzer: @unchecked Sendable {
    private let indexer: CodebaseIndexer
    
    public init(indexer: CodebaseIndexer) {
        self.indexer = indexer
    }
    
    public func analyze(domain: AnalyzerDomain, cwd: String) -> AnalysisReport {
        let snapshot = indexer.index(at: cwd, incremental: true)
        
        switch domain {
        case .web:
            return analyzeWeb(snapshot: snapshot, cwd: cwd)
        case .stat:
            return analyzeStatistical(snapshot: snapshot, cwd: cwd)
        case .sec:
            return analyzeSecurity(snapshot: snapshot, cwd: cwd)
        case .arch:
            return analyzeArchitecture(snapshot: snapshot, cwd: cwd)
        }
    }
    
    // MARK: - Web Development Analysis
    
    private func analyzeWeb(snapshot: CodebaseSnapshot, cwd: String) -> AnalysisReport {
        var frameworks = Set<String>()
        var entryPoints: [String] = []
        var components = 0
        var routes = 0
        var stateLibs = Set<String>()
        var dependencies: [String] = []
        
        // 1. Check Package/Dependencies
        let packageJsonPath = cwd + "/package.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: packageJsonPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let deps = json["dependencies"] as? [String: Any] {
                dependencies.append(contentsOf: deps.keys)
                if deps["react"] != nil { frameworks.insert("React") }
                if deps["next"] != nil { frameworks.insert("Next.js") }
                if deps["vue"] != nil { frameworks.insert("Vue") }
                if deps["svelte"] != nil { frameworks.insert("Svelte") }
                if deps["redux"] != nil { stateLibs.insert("Redux") }
                if deps["zustand"] != nil { stateLibs.insert("Zustand") }
            }
        }
        
        // 2. Scan files
        for file in snapshot.files {
            let p = file.path.lowercased()
            if p.contains("pages/") || p.contains("app/") && (p.hasSuffix(".tsx") || p.hasSuffix(".jsx")) {
                routes += 1
                if p.contains("index") || p.contains("page") { entryPoints.append(file.path) }
            }
            if p.contains("components/") || p.hasSuffix(".tsx") || p.hasSuffix(".vue") {
                components += 1
            }
            if p.contains("index.js") || p.contains("main.ts") || p.contains("App.tsx") {
                entryPoints.append(file.path)
            }
        }
        
        var insights: [String] = []
        insights.append("Detected \(components) UI components and \(routes) distinct routes/pages.")
        if !stateLibs.isEmpty { insights.append("State Management: \(stateLibs.joined(separator: ", "))") }
        if frameworks.isEmpty { frameworks.insert("Vanilla JS/DOM or Unknown") }
        
        return AnalysisReport(
            domain: "Web Development",
            rootPath: cwd,
            primaryLanguages: ["TypeScript", "JavaScript", "HTML", "CSS"],
            frameworks: Array(frameworks),
            entryPoints: Array(Set(entryPoints)),
            insights: insights,
            riskFactors: ["Check for missing CSP headers", "Validate XSS boundaries in generic components"],
            dependencies: dependencies
        )
    }
    
    // MARK: - Statistical / Data Science Analysis
    
    private func analyzeStatistical(snapshot: CodebaseSnapshot, cwd: String) -> AnalysisReport {
        var frameworks = Set<String>()
        var entryPoints: [String] = []
        var dataPipelines = 0
        var models = 0
        var dependencies: [String] = []
        
        let reqPath = cwd + "/requirements.txt"
        
        if FileManager.default.fileExists(atPath: reqPath) {
            if let content = try? String(contentsOfFile: reqPath, encoding: .utf8) {
                dependencies = content.split(separator: "\n").map(String.init)
                if content.contains("pandas") { frameworks.insert("Pandas") }
                if content.contains("scikit-learn") { frameworks.insert("Scikit-Learn") }
                if content.contains("torch") { frameworks.insert("PyTorch") }
                if content.contains("tensorflow") { frameworks.insert("TensorFlow") }
            }
        }
        
        for file in snapshot.files {
            let p = file.path.lowercased()
            if p.hasSuffix(".ipynb") { models += 1 }
            if p.contains("data") || p.contains("pipeline") || p.contains("etl") { dataPipelines += 1 }
            if p.contains("train") || p.contains("model") || p.contains("predict") { models += 1 }
            if p.hasSuffix("main.py") || p.hasSuffix("run.py") || p.hasSuffix("app.R") { entryPoints.append(file.path) }
            if file.imports.contains(where: { $0.contains("sklearn") || $0.contains("torch") }) { frameworks.insert("ML-Frameworks") }
        }
        
        var insights: [String] = []
        insights.append("Detected \(models) model/notebook files and \(dataPipelines) data processing nodes.")
        insights.append("Data Pipeline Volume: \(dataPipelines > 5 ? "High" : "Low")")
        
        return AnalysisReport(
            domain: "Statistical / Data Science",
            rootPath: cwd,
            primaryLanguages: ["Python", "R", "Jupyter"],
            frameworks: Array(frameworks),
            entryPoints: Array(Set(entryPoints)),
            insights: insights,
            riskFactors: ["Data leakage in train/test splits", "Hardcoded model hyperparameters", "Unpinned dependency versions"],
            dependencies: dependencies
        )
    }
    
    // MARK: - Security Analysis
    
    private func analyzeSecurity(snapshot: CodebaseSnapshot, cwd: String) -> AnalysisReport {
        var frameworks = Set<String>()
        var entryPoints: [String] = []
        var authLayers = 0
        var cryptoUsage = 0
        var unsafeCalls = 0
        var dependencies: [String] = []
        
        for file in snapshot.files {
            let p = file.path.lowercased()
            if p.contains("auth") || p.contains("login") || p.contains("session") || p.contains("jwt") || p.contains("oauth") { authLayers += 1 }
            if p.contains("crypto") || p.contains("hash") || p.contains("encrypt") || p.contains("cipher") { cryptoUsage += 1 }
            if p.hasSuffix("main.swift") || p.hasSuffix("main.go") || p.hasSuffix("index.js") { entryPoints.append(file.path) }
            
            // Simple heuristic for unsafe patterns (requires reading file in a deeper analysis, but we rely on symbols here)
            for sym in file.symbols {
                let name = sym.name.lowercased()
                if name.contains("eval") || name.contains("exec") || name.contains("unsafe") || name.contains("system") {
                    unsafeCalls += 1
                }
            }
        }
        
        var insights: [String] = []
        insights.append("Detected \(authLayers) authentication/session layers.")
        insights.append("Detected \(cryptoUsage) cryptographic implementations.")
        if unsafeCalls > 0 { insights.append("WARNING: Found \(unsafeCalls) potentially unsafe function/symbol names (e.g., eval, exec).") }
        
        return AnalysisReport(
            domain: "Security / Systems",
            rootPath: cwd,
            primaryLanguages: Array(Set(snapshot.files.map(\.language))),
            frameworks: Array(frameworks),
            entryPoints: Array(Set(entryPoints)),
            insights: insights,
            riskFactors: [
                "Custom cryptography implementations", 
                "Missing CSRF tokens in auth layer",
                "Unsafe memory access or shell execution"
            ],
            dependencies: dependencies
        )
    }
    
    // MARK: - General Architecture
    
    private func analyzeArchitecture(snapshot: CodebaseSnapshot, cwd: String) -> AnalysisReport {
        var modules = Set<String>()
        var entryPoints: [String] = []
        var totalClasses = 0
        var totalFuncs = 0
        
        for file in snapshot.files {
            let parts = file.path.split(separator: "/")
            if parts.count > 1 { modules.insert(String(parts[0])) }
            
            if file.path.lowercased().contains("main") || file.path.lowercased().contains("index") {
                entryPoints.append(file.path)
            }
            
            for sym in file.symbols {
                if sym.kind == .classDecl || sym.kind == .structDecl { totalClasses += 1 }
                if sym.kind == .function || sym.kind == .method { totalFuncs += 1 }
            }
        }
        
        var insights: [String] = []
        insights.append("Total Files: \(snapshot.totalFiles)")
        insights.append("Total Symbols: \(totalClasses) objects, \(totalFuncs) functions/methods.")
        insights.append("Top-Level Modules: \(modules.prefix(5).joined(separator: ", "))")
        
        return AnalysisReport(
            domain: "General Architecture",
            rootPath: cwd,
            primaryLanguages: Array(Set(snapshot.files.map(\.language))),
            frameworks: [],
            entryPoints: Array(Set(entryPoints)),
            insights: insights,
            riskFactors: nil,
            dependencies: []
        )
    }
}

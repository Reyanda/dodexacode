import Foundation

// MARK: - Design Engine: DESIGN.md Integration (Google Stitch Paradigm)
// Orchestrates design-aware development by treating DESIGN.md as the
// visual source of truth for the AI agent.

public struct DesignSystem: Codable, Sendable {
    public let theme: String
    public let colors: [String: String]
    public let typography: [String: String]
    public let spacing: [String: String]
    public let components: [String: String]
    public let rationale: [String: String]
}

public final class DesignEngine: @unchecked Sendable {
    private let fm = FileManager.default
    
    public init() {}
    
    /// Loads and parses DESIGN.md from the workspace root.
    public func loadDesign(cwd: String) -> String? {
        let path = cwd + "/DESIGN.md"
        guard fm.fileExists(atPath: path) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
    
    /// Generates a standard DESIGN.md template based on best practices.
    public func generateTemplate() -> String {
        return """
        # DESIGN.md - Visual Source of Truth
        
        ## 1. Visual Theme
        Philosophy: Clean, professional, high-density, development-focused.
        Density: High
        Mood: Focused
        
        ## 2. Color Palette
        - Primary: #0369a1 (Muted Blue)
        - Surface: #ffffff (White)
        - Background: #f8fafc (Light Gray)
        - Text: #1e293b (Dark Slate)
        - Error: #ef4444 (Red)
        - Success: #22c55e (Green)
        - Warning: #f59e0b (Amber)
        
        ## 3. Typography
        - Base Font: Inter, system-ui, sans-serif
        - Scale: 1.25 (Major Third)
        - H1: 2rem / 2.5rem line-height / 700 weight
        - Body: 1rem / 1.5rem line-height / 400 weight
        - Monospace: Fira Code, JetBrains Mono, SF Mono
        
        ## 4. Layout & Spacing
        - Base Unit: 4px
        - Container: 1200px max-width
        - White Space: Generous (16px, 24px, 32px increments)
        
        ## 5. Component Styles
        ### Buttons
        - Border Radius: 6px
        - Padding: 8px 16px
        - Shadow: 0 1px 2px rgba(0,0,0,0.05)
        
        ### Cards
        - Background: Surface
        - Border: 1px solid #e2e8f0
        - Padding: 24px
        
        ## 6. Do's and Don'ts
        - DO use middle-dot separators for status lines.
        - DO use soft ANSI colors for terminal output.
        - DON'T use heavy gradients or drop shadows.
        - DON'T use vague terms like "modern" in UI descriptions.
        
        ## 7. Rationale
        - We use a 4px grid to maintain consistent visual rhythm across all screen sizes.
        - Muted blue is used for primary actions to reduce eye strain during long coding sessions.
        """
    }
    
    /// Injects the design context into a system prompt.
    public func wrapWithDesign(prompt: String, cwd: String) -> String {
        guard let design = loadDesign(cwd: cwd) else { return prompt }
        return """
        \(prompt)
        
        CRITICAL: Adhere strictly to the design system defined in DESIGN.md:
        
        --- START DESIGN.md ---
        \(design)
        --- END DESIGN.md ---
        
        Ensure all UI components, colors, and layouts match these specifications precisely.
        """
    }
}

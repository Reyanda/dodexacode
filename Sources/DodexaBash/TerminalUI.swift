import DodexaCodeCore
import Darwin
import Foundation

final class TerminalUI {
    private let shell: Shell
    private var history: [String]
    private var historyIndex: Int?
    private var draftBuffer = ""
    private var buffer: [Character] = []
    private var cursorIndex = 0
    private var didRender = false
    private var lastRenderLineCount = 1
    private var colors: AnsiPalette
    private var gitCache = GitBranchCache()
    private var paletteActive = false
    private var paletteQuery = ""
    private var paletteSelectionIndex = 0
    private var selectedBlockPreviewOffset = 0

    /// Active AI: last suggestion from block analysis (shown as ghost after output)
    private var activeAISuggestion: String?
    private var activeAIEnabled = true
    private let spinnerState = SpinnerState()

    init(shell: Shell) {
        self.shell = shell
        self.history = shell.sessionStore.commandHistory(limit: 200)
        let useColor = TerminalUI.shouldUseColor(environment: shell.context.environment)
        self.colors = AnsiPalette(enabled: useColor, theme: shell.themeStore.current)
    }

    func run() {
        guard isatty(STDIN_FILENO) == 1, let rawMode = RawTerminalMode.activate() else {
            runPlainRepl()
            return
        }
        defer { rawMode.restore() }

        // Wire up Active AI — fires after every block is created
        shell.onBlockCreated = { [weak self] block in
            self?.handleActiveAI(block: block)
        }

        showWelcome()

        while true {
            render()
            guard let key = readKey() else {
                clearRenderBlock()
                writeOut("\n")
                return
            }

            switch key {
            case .character(let character):
                if paletteActive {
                    paletteInsert(character)
                } else {
                    insert(character)
                }
            case .enter:
                if paletteActive {
                    acceptPaletteSelection()
                } else {
                    submit()
                }
                if shell.context.shouldExit {
                    return
                }
            case .backspace:
                if paletteActive {
                    paletteBackspace()
                } else {
                    backspace()
                }
            case .delete:
                if !paletteActive {
                    deleteForward()
                }
            case .left:
                if paletteActive {
                    break
                }
                if shell.blockStore.currentSelection != nil {
                    self.pageSelectedBlockPreview(forward: false)
                } else {
                    cursorIndex = max(0, cursorIndex - 1)
                }
            case .right:
                if paletteActive {
                    break
                }
                if shell.blockStore.currentSelection != nil {
                    self.pageSelectedBlockPreview(forward: true)
                } else {
                    cursorIndex = min(buffer.count, cursorIndex + 1)
                }
            case .up:
                if paletteActive {
                    movePaletteSelection(older: true)
                } else {
                    navigateHistory(older: true)
                }
            case .down:
                if paletteActive {
                    movePaletteSelection(older: false)
                } else {
                    navigateHistory(older: false)
                }
            case .tab:
                if paletteActive {
                    acceptPaletteSelection()
                } else {
                    acceptSuggestion()
                }
            case .ctrlB:
                if !paletteActive {
                    toggleBlockSelection()
                }
            case .ctrlA:
                if !paletteActive {
                    cursorIndex = 0
                }
            case .ctrlE:
                if !paletteActive {
                    cursorIndex = buffer.count
                }
            case .ctrlL:
                refreshScreen()
            case .ctrlP:
                togglePalette()
            case .ctrlC:
                if paletteActive {
                    closePalette()
                } else if shell.blockStore.currentSelection != nil {
                    shell.blockStore.clearSelection()
                    selectedBlockPreviewOffset = 0
                } else {
                    interrupt()
                }
            case .mouseClick(let col):
                // Position cursor in the buffer based on click column
                let promptLen = compactDirectory(shell.context.currentDirectory).count + 3 // " > "
                let bufferCol = max(0, col - promptLen)
                cursorIndex = min(buffer.count, bufferCol)
            case .ctrlD:
                if buffer.isEmpty {
                    clearRenderBlock()
                    writeOut("\n")
                    return
                }
            case .unknown:
                continue
            }
        }
    }

    private func runPlainRepl() {
        while true {
            writeOut(promptString())
            guard let line = readLine() else {
                writeOut("\n")
                return
            }
            let result = shell.run(source: line)
            emit(result)
            if result.shouldExit {
                return
            }
        }
    }

    private func showWelcome() {
        let width = max(40, terminalWidth())
        let tuiTheme = TUITheme.from(shell.themeStore.current)
        let contentWidth = min(max(36, width - 6), 72)

        let brainStatusText: String
        let brainStatusStyle: String
        if shell.brain.config.enabled {
            let connected = shell.brain.isAvailable()
            brainStatusText = connected ? shell.brain.config.model : "offline"
            brainStatusStyle = connected ? tuiTheme.success : tuiTheme.error
        } else {
            brainStatusText = "off"
            brainStatusStyle = tuiTheme.muted
        }

        let statusLines = KVWidget(
            [
                ("brain", brainStatusStyle + brainStatusText + ANSI.reset),
                ("theme", tuiTheme.accent + shell.themeStore.current.name + ANSI.reset),
                ("cwd", tuiTheme.type + compactDirectory(shell.context.currentDirectory) + ANSI.reset)
            ],
            keyWidth: 8
        ).render(width: contentWidth, theme: tuiTheme)

        let tipLines = TextWidget(
            lines: [
                StyledText("AI-native shell", style: tuiTheme.muted),
                StyledText(Tips.random(), style: tuiTheme.fg)
            ]
        ).render(width: contentWidth, theme: tuiTheme)

        writeOut("\r\n")
        writeRenderedWidget(SeparatorWidget(label: "session"), width: contentWidth + 4, theme: tuiTheme)
        writeRenderedWidget(
            BoxWidget(
                title: "dodexabash",
                content: tipLines,
                footer: tuiTheme.muted + "dependency-free Swift shell" + ANSI.reset,
                style: .rounded
            ),
            width: contentWidth + 4,
            theme: tuiTheme
        )
        writeRenderedWidget(
            BoxWidget(
                title: "status",
                content: statusLines,
                style: .rounded
            ),
            width: contentWidth + 4,
            theme: tuiTheme
        )
        writeOut("\r\n")
    }

    private func writeRenderedWidget(_ widget: any TUIWidget, width: Int, theme: TUITheme) {
        for line in widget.render(width: width, theme: theme) {
            writeOut(line + "\r\n")
        }
    }

    private func submit() {
        if let selection = selectedBlock() {
            setBuffer(selection.command)
            shell.blockStore.clearSelection()
            selectedBlockPreviewOffset = 0
            return
        }

        let line = String(buffer)
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        clearRenderBlock()

        guard !trimmed.isEmpty else {
            resetInput()
            return
        }

        // Handle # prefix — natural language command generation
        if trimmed.hasPrefix("#") {
            let query = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                handleNaturalLanguageGeneration(query)
                return
            }
        }

        // Handle / prefix — slash commands: /help, /theme set nord, /brain status
        if trimmed.hasPrefix("/") && trimmed.count > 1 {
            let stripped = String(trimmed.dropFirst())
            buffer = Array(stripped)
            cursorIndex = buffer.count
        }

        // Re-read after possible / stripping
        let effectiveLine = String(buffer)
        let effectiveTrimmed = effectiveLine.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle clear directly — bypass output formatting + reload theme
        if effectiveTrimmed == "clear" || effectiveTrimmed == "cls" {
            _ = shell.run(source: effectiveLine)
            // Reload theme in case it changed
            let useColor = TerminalUI.shouldUseColor(environment: shell.context.environment)
            colors = AnsiPalette(enabled: useColor, theme: shell.themeStore.current)
            writeOut("\u{001B}[2J\u{001B}[H")
            didRender = false
            showWelcome()
            history = shell.sessionStore.commandHistory(limit: 200)
            resetInput()
            return
        }

        // Animated spinner while command runs
        showThinking()
        let result = shell.run(source: effectiveLine)
        clearThinking()

        // Active AI: suggest next action
        generateActiveSuggestion(command: effectiveTrimmed, result: result)
        renderExecutedBlock(command: effectiveLine, result: result)

        // Clear any stale content below output + force cursor to column 0
        writeOut("\r\u{001B}[J")
        history = shell.sessionStore.commandHistory(limit: 200)
        resetInput()
    }

    // MARK: - Block Rendering

    private func renderExecutedBlock(command: String, result: ShellRunResult) {
        let renderer = TerminalBlockRenderer(colors: colors)
        writeOut(renderer.render(buildBlockState(command: command, result: result)))
    }

    private func buildBlockState(command: String, result: ShellRunResult) -> TerminalBlockState {
        let latestBlock = shell.blockStore.latest
        return TerminalBlockState(
            command: command,
            stdout: rawToTerminal(result.stdout),
            stderr: rawToTerminal(result.stderr),
            badges: blockBadges(for: latestBlock, fallbackStatus: result.status),
            suggestion: activeAISuggestion
        )
    }

    private func blockBadges(for block: Block?, fallbackStatus: Int32) -> [TerminalBadge] {
        guard let block else {
            if fallbackStatus == 0 {
                return [TerminalBadge(text: "\u{2713}", tone: .success)]
            }
            return [TerminalBadge(text: "exit \(fallbackStatus)", tone: .error)]
        }

        var badges: [TerminalBadge] = []
        let ms = Int(block.duration * 1000)
        if ms >= 100 {
            let label = ms >= 1000 ? String(format: "%.1fs", block.duration) : "\(ms)ms"
            badges.append(TerminalBadge(text: label, tone: .subtle))
        }
        if block.exitCode == 0 {
            badges.append(TerminalBadge(text: "\u{2713}", tone: .success))
        } else {
            badges.append(TerminalBadge(text: "exit \(block.exitCode)", tone: .error))
        }
        if block.proofId != nil {
            badges.append(TerminalBadge(text: "\u{2234}", tone: .success))
        }
        if block.intentId != nil {
            badges.append(TerminalBadge(text: "\u{25C7}", tone: .warning))
        }
        if let unc = block.uncertaintyLevel, unc != .known {
            badges.append(TerminalBadge(text: "~" + unc.rawValue, tone: .warning))
        }
        if block.repairId != nil {
            badges.append(TerminalBadge(text: "\u{2692}", tone: .error))
        }
        return badges
    }

    // MARK: - Active AI (proactive suggestions after every command)

    private func handleActiveAI(block: Block) {
        guard activeAIEnabled else {
            activeAISuggestion = nil
            return
        }

        // On failure: suggest repair or fix
        if block.exitCode != 0 {
            if let repairId = block.repairId,
               let plan = shell.runtimeStore.repairPlan(byId: repairId),
               let firstOption = plan.repairOptions.first,
               let cmd = firstOption.command {
                activeAISuggestion = cmd
                return
            }
            // Use brain for failure analysis if available
            if shell.brain.config.enabled, shell.brain.isAvailable() {
                if let analysis = shell.brain.analyzeFailure(
                    command: block.command,
                    exitStatus: block.exitCode,
                    stderr: block.output.stderr,
                    cwd: block.workingDirectory
                ) {
                    // Extract FIX line
                    for line in analysis.split(separator: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.uppercased().hasPrefix("FIX:") {
                            let fix = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                            if !fix.isEmpty {
                                activeAISuggestion = fix
                                return
                            }
                        }
                    }
                }
            }
        }

        // On success: use Markov prediction
        if let prediction = shell.sessionStore.predictions(seedCommand: block.command, limit: 1).first,
           prediction.confidence >= 0.5 {
            activeAISuggestion = prediction.command
            return
        }

        activeAISuggestion = nil
    }

    // MARK: - Natural Language Command Generation (#)

    private func handleNaturalLanguageGeneration(_ query: String) {
        writeOut(colors.intentColor + "  \u{25C6} " + colors.reset +
                 colors.hint + query + colors.reset + "\r\n")

        guard shell.brain.config.enabled, shell.brain.isAvailable() else {
            writeOut(colors.statusErr + "  brain offline — run 'brain on' first" + colors.reset + "\r\n")
            resetInput()
            return
        }

        showThinking()

        let recentHistory = shell.sessionStore.commandHistory(limit: 5)
        guard let response = shell.brain.translateToCommand(
            naturalLanguage: query,
            cwd: shell.context.currentDirectory,
            recentHistory: recentHistory
        ) else {
            clearThinking()
            writeOut(colors.statusErr + "  could not generate command" + colors.reset + "\r\n")
            resetInput()
            return
        }

        clearThinking()

        // Show the generated command with accept/reject prompt
        writeOut(colors.statusOk + "  \u{25B8} " + colors.reset +
                 colors.accent + "\u{001B}[1m" + response.command + colors.reset + "\r\n")

        if !response.explanation.isEmpty {
            writeOut(colors.hint + "    " + response.explanation + colors.reset + "\r\n")
        }

        // Show simulation if available
        let simulation = shell.runtimeStore.simulate(command: response.command)
        if simulation.riskAssessment != .low {
            writeOut(colors.attentionColor + "    risk: " + simulation.riskAssessment.rawValue + colors.reset)
            for effect in simulation.predictedEffects.prefix(3) {
                writeOut(colors.hint + "    \u{2022} " + effect.description + colors.reset + "\r\n")
            }
        }

        writeOut(colors.hint + "  [Enter] run  [Tab] edit  [Esc] cancel" + colors.reset + "\r\n")

        // Wait for user decision
        while true {
            guard let key = readKey() else {
                resetInput()
                return
            }
            switch key {
            case .enter:
                // Execute the generated command
                setBuffer(response.command)
                submit()
                return
            case .tab:
                // Put command into buffer for editing
                setBuffer(response.command)
                resetInput()
                buffer = Array(response.command)
                cursorIndex = buffer.count
                return
            case .ctrlC, .unknown:
                writeOut(colors.hint + "  cancelled" + colors.reset + "\r\n")
                resetInput()
                return
            default:
                // Esc or any other key cancels
                if case .character(let ch) = key, ch == "\u{1B}" {
                    writeOut(colors.hint + "  cancelled" + colors.reset + "\r\n")
                    resetInput()
                    return
                }
                continue
            }
        }
    }

    private var spinnerThread: Thread?

    private func showThinking() {
        let command = String(buffer).trimmingCharacters(in: .whitespaces)
        let verb = spinnerVerb(for: command)
        spinnerState.running = true

        let frames = ["\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}"]
        let col = colors
        let state = spinnerState

        spinnerThread = Thread {
            var i = 0
            while state.running {
                let frame = frames[i % frames.count]
                let text = col.intentColor + "  " + frame + " " + col.hint + verb + col.reset
                FileHandle.standardOutput.write(Data(("\r\u{001B}[2K" + text).utf8))
                i += 1
                Thread.sleep(forTimeInterval: 0.08)
            }
        }
        spinnerThread?.start()
    }

    private func clearThinking() {
        spinnerState.running = false
        spinnerThread = nil
        Thread.sleep(forTimeInterval: 0.05)
        writeOut("\r\u{001B}[2K")
    }

    // MARK: - Active AI

    private func generateActiveSuggestion(command: String, result: ShellRunResult) {
        activeAISuggestion = nil
        guard activeAIEnabled else { return }

        // Quick heuristic suggestions (no brain call — instant)
        if result.status != 0 {
            // Failed command — suggest repair
            if let plan = shell.runtimeStore.lastRepairPlan(),
               let firstOption = plan.repairOptions.first,
               let cmd = firstOption.command {
                activeAISuggestion = cmd
                return
            }
            // Generic failure suggestions
            activeAISuggestion = "repair last"
            return
        }

        // Success — suggest logical next step based on what just ran
        let lowered = command.lowercased()
        let first = lowered.split(separator: " ").first.map(String.init) ?? ""

        switch first {
        case "cd":
            activeAISuggestion = "brief"
        case "git":
            if lowered.contains("clone") { activeAISuggestion = "brief" }
            else if lowered.contains("add") { activeAISuggestion = "git commit" }
            else if lowered.contains("commit") { activeAISuggestion = "git push" }
            else if lowered.contains("pull") { activeAISuggestion = "git log --oneline -5" }
            else if lowered.contains("status") && result.stdout.contains("modified") { activeAISuggestion = "git diff" }
        case "swift":
            if lowered.contains("build") { activeAISuggestion = "swift test" }
            else if lowered.contains("test") { activeAISuggestion = "git status" }
        case "npm", "yarn", "pnpm":
            if lowered.contains("install") { activeAISuggestion = "npm run dev" }
        case "pip", "pip3":
            if lowered.contains("install") { activeAISuggestion = "python3 -c 'import sys; print(sys.version)'" }
        case "create":
            // After creating a file, suggest opening it
            let parts = command.split(separator: " ")
            if parts.count >= 2 {
                activeAISuggestion = "open \(parts[1])"
            }
        case "brief":
            activeAISuggestion = "tree -L2"
        case "tree":
            activeAISuggestion = nil // tree is usually the end of exploration
        case "intent":
            if lowered.contains("set") { activeAISuggestion = "brief" }
        default:
            // Use session predictions as fallback
            if let prediction = shell.sessionStore.predictions(seedCommand: command, limit: 1).first,
               prediction.confidence > 0.6 {
                activeAISuggestion = prediction.command
            }
        }
    }

    private func spinnerVerb(for command: String) -> String {
        let lowered = command.lowercased()
        let first = lowered.split(separator: " ").first.map(String.init) ?? ""

        // Brain / AI
        if lowered.hasPrefix("#") { return "Generating command..." }
        if first == "ask" { return "Thinking..." }
        if first == "brain" && lowered.contains("do") { return "Planning task..." }

        // File operations
        if first == "open" || first == "cat" || first == "show" { return "Reading file..." }
        if first == "tree" { return "Scanning directory..." }
        if first == "brief" { return "Analyzing workspace..." }
        if first == "create" || first == "touch" || first == "mkdir" { return "Creating..." }

        // Search
        if first == "grep" || first == "rg" || first == "find" { return "Searching..." }
        if lowered.contains("search") || lowered.contains("find") { return "Searching..." }

        // Build / test
        if first == "swift" && lowered.contains("build") { return "Building..." }
        if first == "swift" && lowered.contains("test") { return "Running tests..." }
        if first == "make" || first == "cmake" { return "Building..." }
        if first == "npm" || first == "yarn" || first == "pnpm" { return "Installing packages..." }
        if first == "pip" || first == "pip3" { return "Installing packages..." }

        // Git
        if first == "git" {
            if lowered.contains("pull") { return "Pulling changes..." }
            if lowered.contains("push") { return "Pushing changes..." }
            if lowered.contains("clone") { return "Cloning repository..." }
            if lowered.contains("fetch") { return "Fetching..." }
            if lowered.contains("commit") { return "Committing..." }
            if lowered.contains("diff") { return "Computing diff..." }
            if lowered.contains("log") { return "Reading history..." }
            if lowered.contains("status") { return "Checking status..." }
            return "Running git..."
        }

        // Network
        if first == "curl" || first == "wget" { return "Fetching URL..." }
        if first == "ssh" { return "Connecting..." }

        // Runtime primitives
        if first == "simulate" { return "Simulating..." }
        if first == "prove" { return "Verifying proof..." }
        if first == "world" { return "Building world graph..." }
        if first == "uncertainty" { return "Assessing uncertainty..." }
        if first == "repair" { return "Analyzing failure..." }
        if first == "skill" && lowered.contains("run") { return "Running skill..." }

        // NL phrases (brain routing)
        if lowered.contains("what") || lowered.contains("who") || lowered.contains("how") { return "Thinking..." }
        if lowered.contains("list") || lowered.contains("show") { return "Gathering info..." }
        if lowered.contains("create") || lowered.contains("make") { return "Creating..." }
        if lowered.contains("explain") || lowered.contains("describe") { return "Reasoning..." }

        // Default
        return "Running..."
    }

    private func interrupt() {
        clearRenderBlock()
        writeOut("^C\r\n")
        resetInput()
    }

    private func resetInput() {
        buffer = []
        cursorIndex = 0
        historyIndex = nil
        draftBuffer = ""
    }

    private func insert(_ character: Character) {
        buffer.insert(character, at: cursorIndex)
        cursorIndex += 1
    }

    private func backspace() {
        guard cursorIndex > 0 else {
            return
        }
        cursorIndex -= 1
        buffer.remove(at: cursorIndex)
    }

    private func deleteForward() {
        guard cursorIndex < buffer.count else {
            return
        }
        buffer.remove(at: cursorIndex)
    }

    private func navigateHistory(older: Bool) {
        if shell.blockStore.currentSelection != nil {
            if older {
                _ = shell.blockStore.selectPrevious()
            } else {
                _ = shell.blockStore.selectNext()
            }
            selectedBlockPreviewOffset = 0
            return
        }

        guard !history.isEmpty else {
            return
        }

        if older {
            if historyIndex == nil {
                draftBuffer = String(buffer)
                historyIndex = 0
            } else {
                historyIndex = min((historyIndex ?? 0) + 1, history.count - 1)
            }
        } else {
            guard let currentIndex = historyIndex else {
                return
            }
            if currentIndex == 0 {
                historyIndex = nil
                setBuffer(draftBuffer)
                return
            }
            historyIndex = currentIndex - 1
        }

        if let historyIndex {
            setBuffer(history[historyIndex])
        }
    }

    private func acceptSuggestion() {
        // 1. Ghost suggestion from history
        if let suggestion = ghostSuggestion().command {
            setBuffer(suggestion)
            return
        }
        // 2. Filesystem / command tab completion
        if let completed = tabComplete() {
            setBuffer(completed)
        }
    }

    private func setBuffer(_ value: String) {
        buffer = Array(value)
        cursorIndex = buffer.count
    }

    private func toggleBlockSelection() {
        if shell.blockStore.currentSelection == nil {
            _ = shell.blockStore.selectPrevious()
            selectedBlockPreviewOffset = 0
        } else {
            shell.blockStore.clearSelection()
            selectedBlockPreviewOffset = 0
        }
    }

    private func pageSelectedBlockPreview(forward: Bool) {
        let total = selectedBlockOutputLines().count
        guard total > selectedBlockPreviewPageSize else { return }

        if forward {
            selectedBlockPreviewOffset = min(max(0, total - selectedBlockPreviewPageSize), selectedBlockPreviewOffset + selectedBlockPreviewPageSize)
        } else {
            selectedBlockPreviewOffset = max(0, selectedBlockPreviewOffset - selectedBlockPreviewPageSize)
        }
    }

    private func togglePalette() {
        if paletteActive {
            closePalette()
            return
        }
        paletteActive = true
        paletteQuery = ""
        paletteSelectionIndex = 0
        shell.blockStore.clearSelection()
    }

    private func closePalette() {
        paletteActive = false
        paletteQuery = ""
        paletteSelectionIndex = 0
    }

    private func paletteInsert(_ character: Character) {
        paletteQuery.append(character)
        paletteSelectionIndex = 0
    }

    private func paletteBackspace() {
        guard !paletteQuery.isEmpty else { return }
        paletteQuery.removeLast()
        paletteSelectionIndex = 0
    }

    private func movePaletteSelection(older: Bool) {
        let actions = filteredPaletteActions()
        guard !actions.isEmpty else { return }
        if older {
            paletteSelectionIndex = max(0, paletteSelectionIndex - 1)
        } else {
            paletteSelectionIndex = min(actions.count - 1, paletteSelectionIndex + 1)
        }
    }

    private func acceptPaletteSelection() {
        guard let action = selectedPaletteAction() else {
            closePalette()
            return
        }
        switch action.mode {
        case .load:
            setBuffer(action.command)
            closePalette()
        case .run:
            closePalette()
            setBuffer(action.command)
            submit()
        }
    }

    private func selectedBlock() -> Block? {
        guard let index = shell.blockStore.currentSelection else { return nil }
        return shell.blockStore.block(at: index)
    }

    private func render() {
        let width = max(40, terminalWidth())
        if didRender {
            clearRenderBlock()
        }

        let ghost = ghostSuggestion()
        let screenState = buildScreenState(width: width, ghostCommand: ghost.command)
        let chromeRenderer = TerminalChromeRenderer(colors: colors)
        let frame = chromeRenderer.render(width: width, state: screenState)

        lastRenderLineCount = frame.lines.count
        for (index, line) in frame.lines.enumerated() {
            writeOut(line)
            if index < frame.lines.count - 1 {
                writeOut("\r\n")
            }
        }

        // Position cursor: return to column 0, then advance to exact column
        writeOut("\r")
        if frame.cursorColumn > 0 {
            writeOut("\u{001B}[\(frame.cursorColumn)C")
        }
        didRender = true
    }

    private func clearRenderBlock() {
        guard didRender else {
            return
        }

        writeOut("\r\u{001B}[2K")
        for _ in 1..<lastRenderLineCount {
            writeOut("\u{001B}[1A\r\u{001B}[2K")
        }
        writeOut("\r")
        didRender = false
    }

    private func refreshScreen() {
        writeOut("\u{001B}[2J\u{001B}[H")
        didRender = false
        showWelcome()
    }

    private func buildScreenState(width: Int, ghostCommand: String?) -> TerminalScreenState {
        let promptRender = paletteActive
            ? buildPalettePromptRender(width: width)
            : buildPromptRender(width: width, ghostCommand: ghostCommand)
        return TerminalScreenState(
            topBar: buildTopBarState(),
            timeline: buildTimelineState(),
            palette: buildPaletteState(),
            composer: TerminalComposerState(
                displayLine: promptRender.displayLine,
                ghostText: promptRender.ghostSuffix,
                cursorColumn: promptRender.cursorColumn,
                occupiedWidth: promptRender.occupiedWidth,
                hintText: composerHintText()
            )
        )
    }

    private func buildTimelineState() -> TerminalTimelineState {
        let selectedId = selectedBlock()?.id
        let blocksToRender = timelineBlocks(selectedId: selectedId)
        let items = blocksToRender.map { block in
            TerminalTimelineItem(
                blockId: block.id,
                command: block.command,
                summary: timelineSummary(for: block),
                badges: Array(blockBadges(for: block, fallbackStatus: block.exitCode).prefix(3)),
                isSelected: block.id == selectedId
            )
        }

        return TerminalTimelineState(
            title: selectedId == nil ? "latest blocks" : "block navigator",
            items: items,
            emptyText: "No commands yet. Type a command or start with # for natural language.",
            suggestion: buffer.isEmpty && selectedId == nil && !paletteActive ? activeAISuggestion : nil,
            selectedBlockCommand: selectedBlock()?.command,
            selectedBlockPreviewLabel: selectedBlockPreviewLabel(),
            selectedBlockPreview: buildSelectedBlockPreview()
        )
    }

    private func selectedBlockPreviewLabel() -> String? {
        guard let block = selectedBlock() else { return nil }
        let stream = !block.output.stdout.isEmpty ? "stdout" : (!block.output.stderr.isEmpty ? "stderr" : "output")
        let allLines = selectedBlockOutputLines()
        guard !allLines.isEmpty else { return stream }

        let start = min(selectedBlockPreviewOffset, max(0, allLines.count - 1))
        let end = min(allLines.count, start + selectedBlockPreviewPageSize)
        return "\(stream)  lines \(start + 1)-\(end) of \(allLines.count)  \u{2190}/\u{2192} page"
    }

    private func buildSelectedBlockPreview() -> [String] {
        let allLines = selectedBlockOutputLines()
        if allLines.isEmpty {
            return ["Output was empty or whitespace only."]
        }

        let start = min(selectedBlockPreviewOffset, max(0, allLines.count - 1))
        let end = min(allLines.count, start + selectedBlockPreviewPageSize)
        return Array(allLines[start..<end])
    }

    private var selectedBlockPreviewPageSize: Int { 4 }

    private func selectedBlockOutputLines() -> [String] {
        guard let block = selectedBlock() else { return [] }

        let source: String
        if !block.output.stdout.isEmpty {
            source = block.output.stdout
        } else if !block.output.stderr.isEmpty {
            source = block.output.stderr
        } else {
            return []
        }

        return source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func buildPaletteState() -> TerminalPaletteState? {
        guard paletteActive else { return nil }
        let actions = filteredPaletteActions()
        let selectedIndex = min(paletteSelectionIndex, max(0, actions.count - 1))

        return TerminalPaletteState(
            query: paletteQuery,
            items: actions.enumerated().map { index, action in
                TerminalPaletteItem(
                    title: action.title,
                    subtitle: action.subtitle,
                    command: action.command,
                    modeLabel: action.mode == .run ? "run" : "load",
                    isSelected: index == selectedIndex
                )
            },
            emptyText: "No matching actions."
        )
    }

    private func timelineBlocks(selectedId: UUID?) -> [Block] {
        let allBlocks = shell.blockStore.all
        guard !allBlocks.isEmpty else { return [] }

        if let selectedId, let selectedIndex = allBlocks.firstIndex(where: { $0.id == selectedId }) {
            let start = max(0, selectedIndex - 2)
            let end = min(allBlocks.count, selectedIndex + 3)
            return Array(allBlocks[start..<end]).reversed()
        }

        return Array(allBlocks.suffix(3)).reversed()
    }

    private func timelineSummary(for block: Block) -> String {
        let preview = block.output.preview(limit: 120)
        if !preview.isEmpty {
            return preview
        }
        if block.exitCode == 0 {
            return "completed with no output"
        }
        return "failed with no output"
    }

    private func buildTopBarState() -> TerminalTopBarState {
        let branch = gitCache.branch(for: shell.context.currentDirectory)
        var items: [TerminalBadge] = []

        if let branch, !branch.isEmpty {
            items.append(.init(text: branch, tone: .accent))
        }

        if shell.context.lastStatus != 0 {
            items.append(.init(text: "exit \(shell.context.lastStatus)", tone: .error))
        }

        let runtime = shell.runtimeStore
        if let intent = runtime.activeIntent, intent.status == .active {
            let label = intent.statement.count > 30
                ? String(intent.statement.prefix(30)) + ".."
                : intent.statement
            items.append(.init(text: "intent: \(label)", tone: .warning))
        }
        let leaseCount = runtime.activeLeases().count
        if leaseCount > 0 {
            items.append(.init(text: "leases: \(leaseCount)", tone: .subtle))
        }
        let attnCount = runtime.pendingAttention().count
        if attnCount > 0 {
            items.append(.init(text: "attn: \(attnCount)", tone: .warning))
        }

        if shell.jobTable.count > 0 {
            items.append(.init(text: "jobs: \(shell.jobTable.count)", tone: .subtle))
        }
        items.append(.init(text: "theme: \(shell.themeStore.current.name)", tone: .subtle))
        if paletteActive {
            items.append(.init(text: "mode: palette", tone: .accent))
        }

        let brainItem: TerminalBadge
        if shell.brain.config.enabled {
            if shell.brain.isAvailable() {
                brainItem = .init(text: "brain: \(shell.brain.config.model)", tone: .success)
            } else {
                brainItem = .init(text: "brain: offline", tone: .error)
            }
        } else {
            brainItem = .init(text: "brain: off", tone: .subtle)
        }
        items.insert(brainItem, at: min(1, items.count))

        return TerminalTopBarState(
            title: "dodexabash",
            context: compactDirectory(shell.context.currentDirectory),
            items: items
        )
    }

    private func promptString() -> String {
        let cwd = compactDirectory(shell.context.currentDirectory)
        return colors.path + cwd + colors.reset +
               colors.prompt + " \u{276F} " + colors.reset
    }

    private func buildPromptRender(width: Int, ghostCommand: String?) -> PromptRender {
        let promptVisible = compactDirectory(shell.context.currentDirectory) + " \u{276F} "
        let promptDisplay = promptString()
        let promptLen = promptVisible.count
        let bufferString = String(buffer)

        // Ghost suffix
        let ghostSuffix: String
        if let ghostCommand, cursorIndex == buffer.count, ghostCommand.hasPrefix(bufferString.lowercased()) {
            let start = ghostCommand.index(ghostCommand.startIndex, offsetBy: bufferString.count)
            ghostSuffix = String(ghostCommand[start...])
        } else {
            ghostSuffix = ""
        }

        // Viewport (plain text, for width math)
        let available = max(8, width - promptLen)
        let viewport = viewportForBuffer(available: available)
        let visiblePlain = viewport.prefix + viewport.visible

        // Syntax-highlighted version of visible buffer
        let visibleHighlighted = viewport.prefix + highlightVisible(
            visible: viewport.visible,
            offsetInBuffer: viewport.startOffset
        )

        let displayLine = promptDisplay + visibleHighlighted
        let maxGhost = max(0, width - promptLen - visiblePlain.count)
        let clippedGhost = ghostSuffix.isEmpty ? "" : String(ghostSuffix.prefix(maxGhost))
        let cursorCol = promptLen + viewport.cursorOffset

        return PromptRender(
            displayLine: displayLine,
            ghostSuffix: clippedGhost,
            cursorColumn: cursorCol,
            occupiedWidth: promptLen + visiblePlain.count + clippedGhost.count
        )
    }

    private func buildPalettePromptRender(width: Int) -> PromptRender {
        let promptVisible = "palette \u{276F} "
        let promptDisplay = colors.intentColor + "palette" + colors.reset +
            colors.prompt + " \u{276F} " + colors.reset
        let available = max(8, width - promptVisible.count)

        let visibleQuery: String
        if paletteQuery.count <= available {
            visibleQuery = paletteQuery
        } else {
            let suffixLength = max(1, available - 3)
            visibleQuery = "..." + String(paletteQuery.suffix(suffixLength))
        }

        return PromptRender(
            displayLine: promptDisplay + colors.accent + visibleQuery + colors.reset,
            ghostSuffix: "",
            cursorColumn: promptVisible.count + visibleQuery.count,
            occupiedWidth: promptVisible.count + visibleQuery.count
        )
    }

    private func composerHintText() -> String {
        if paletteActive {
            return "Enter run/load \u{00B7} Up/Down move \u{00B7} Ctrl-P close"
        }
        if shell.blockStore.currentSelection != nil {
            return "Enter load command \u{00B7} Up/Down block \u{00B7} \u{2190}/\u{2192} page"
        }
        if buffer.isEmpty {
            return "# ask \u{00B7} Ctrl-B blocks \u{00B7} Tab complete"
        }
        return "Tab accept \u{00B7} Ctrl-A/E move \u{00B7} Ctrl-C cancel"
    }

    private func filteredPaletteActions() -> [PaletteAction] {
        let query = paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = availablePaletteActions()
        guard !query.isEmpty else { return actions }
        return actions.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
    }

    private func selectedPaletteAction() -> PaletteAction? {
        let actions = filteredPaletteActions()
        guard !actions.isEmpty else { return nil }
        let index = min(paletteSelectionIndex, actions.count - 1)
        return actions[index]
    }

    private func availablePaletteActions() -> [PaletteAction] {
        var actions: [PaletteAction] = [
            PaletteAction(title: "Help", subtitle: "Show builtins and keys", command: "help", mode: .run),
            PaletteAction(title: "Status", subtitle: "Show runtime overview", command: "status", mode: .run),
            PaletteAction(title: "Brief", subtitle: "Analyze current workspace", command: "brief", mode: .run),
            PaletteAction(title: "History 10", subtitle: "Recent session commands", command: "history 10", mode: .run),
            PaletteAction(title: "Predict", subtitle: "Show likely next commands", command: "predict", mode: .run),
            PaletteAction(title: "Cards", subtitle: "List workflow cards", command: "cards", mode: .run),
            PaletteAction(title: "Repair Last", subtitle: "Show suggested fix path", command: "repair last", mode: .run),
            PaletteAction(title: "Prove Last", subtitle: "Show last proof envelope", command: "prove last", mode: .run),
            PaletteAction(title: "Brain Status", subtitle: "Show local brain state", command: "brain status", mode: .run),
            PaletteAction(title: "Theme List", subtitle: "List available themes", command: "theme list", mode: .run),
            PaletteAction(title: "Blocks List", subtitle: "Show recent block summaries", command: "blocks list", mode: .run),
            PaletteAction(title: "Block Failures", subtitle: "Show failed blocks", command: "blocks failures", mode: .run)
        ]

        for theme in Theme.all {
            actions.append(
                PaletteAction(
                    title: "Theme: \(theme.name)",
                    subtitle: "Switch active shell palette",
                    command: "theme set \(theme.name)",
                    mode: .run
                )
            )
        }

        for workflow in shell.workflowLibrary.listCards() {
            actions.append(
                PaletteAction(
                    title: "Workflow: \(workflow.name)",
                    subtitle: workflow.summary,
                    command: "workflow show \(workflow.slug)",
                    mode: .run
                )
            )
        }

        for block in shell.blockStore.recent(5).reversed() {
            actions.append(
                PaletteAction(
                    title: "Recent block",
                    subtitle: block.command,
                    command: block.command,
                    mode: .load
                )
            )
        }

        if let selected = selectedBlock() {
            let quoted = shellQuoted(selected.command)
            actions.insert(
                PaletteAction(
                    title: "Selected: inspect block",
                    subtitle: selected.id.uuidString,
                    command: "blocks show \(selected.id.uuidString)",
                    mode: .run
                ),
                at: 0
            )
            actions.insert(
                PaletteAction(
                    title: "Selected: load command",
                    subtitle: selected.command,
                    command: selected.command,
                    mode: .load
                ),
                at: 1
            )
            actions.insert(
                PaletteAction(
                    title: "Selected: simulate command",
                    subtitle: "Preview effects without executing",
                    command: "simulate \(quoted)",
                    mode: .run
                ),
                at: 2
            )
            actions.insert(
                PaletteAction(
                    title: "Selected: workflow match",
                    subtitle: "Route the command through workflow cards",
                    command: "workflow match \(quoted)",
                    mode: .run
                ),
                at: 3
            )
            actions.insert(
                PaletteAction(
                    title: "Selected: search blocks",
                    subtitle: "Find similar commands in block history",
                    command: "blocks search \(quoted)",
                    mode: .run
                ),
                at: 4
            )
        }

        return actions
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func viewportForBuffer(available: Int) -> (prefix: String, visible: String, cursorOffset: Int, startOffset: Int) {
        let bufferString = String(buffer)
        guard bufferString.count > available else {
            return ("", bufferString, cursorIndex, 0)
        }

        let prefixWidth = 3
        let payload = max(1, available - prefixWidth)
        let start = max(0, min(cursorIndex, buffer.count) - payload)
        let end = min(buffer.count, start + payload)
        let slice = String(buffer[start..<end])
        return ("...", slice, min(cursorIndex - start + prefixWidth, available), start)
    }

    // MARK: - Syntax Highlighting

    private static let builtinNames: Set<String> = [
        "cd", "pwd", "echo", "env", "export", "unset", "set",
        "brief", "history", "predict", "workflow", "help", "exit",
        "artifact", "intent", "lease", "simulate", "prove",
        "entity", "attention", "policy", "world", "uncertainty",
        "repair", "delegate", "replay", "diff"
    ]

    private func highlightVisible(visible: String, offsetInBuffer: Int) -> String {
        guard colors.enabled, !visible.isEmpty else { return visible }

        // Get the full buffer to know the first word
        let fullText = String(buffer)
        let parts = fullText.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let firstWord = parts.first.map(String.init) ?? ""

        // If the viewport starts at 0, we're seeing the command name
        if offsetInBuffer == 0 {
            return highlightLine(visible, firstWord: firstWord)
        }

        // Mid-buffer viewport: highlight arguments only
        return highlightArguments(visible)
    }

    private func highlightLine(_ text: String, firstWord: String) -> String {
        guard let spaceIdx = text.firstIndex(of: " ") else {
            // Single word — color as command
            return colorForCommand(text) + text + colors.reset
        }

        let cmd = String(text[..<spaceIdx])
        let rest = String(text[spaceIdx...])
        return colorForCommand(cmd) + cmd + colors.reset + highlightArguments(rest)
    }

    private func colorForCommand(_ cmd: String) -> String {
        if Self.builtinNames.contains(cmd) {
            return colors.prompt           // blue for builtins
        }
        // Check if it resolves in PATH
        let pathEntries = (shell.context.environment["PATH"] ?? "").split(separator: ":")
        for entry in pathEntries {
            let candidate = String(entry) + "/" + cmd
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return colors.statusOk     // green for valid external commands
            }
        }
        return colors.statusErr            // red for unknown commands
    }

    private func highlightArguments(_ text: String) -> String {
        var result = ""
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]

            // Operators: | ; && ||
            if ch == "|" || ch == ";" {
                result += colors.separator + String(ch) + colors.reset
                i = text.index(after: i)
                // Check for ||
                if ch == "|" && i < text.endIndex && text[i] == "|" {
                    result += colors.separator + "|" + colors.reset
                    i = text.index(after: i)
                }
                continue
            }

            if ch == "&" && i < text.endIndex {
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "&" {
                    result += colors.separator + "&&" + colors.reset
                    i = text.index(next, offsetBy: 1)
                    continue
                }
            }

            // Redirections: < > >>
            if ch == "<" || ch == ">" {
                result += colors.separator + String(ch) + colors.reset
                i = text.index(after: i)
                if ch == ">" && i < text.endIndex && text[i] == ">" {
                    result += colors.separator + ">" + colors.reset
                    i = text.index(after: i)
                }
                continue
            }

            // Variables: $VAR or ${VAR}
            if ch == "$" {
                let varStart = i
                i = text.index(after: i)
                if i < text.endIndex && text[i] == "{" {
                    // ${...}
                    if let close = text[i...].firstIndex(of: "}") {
                        let end = text.index(after: close)
                        result += colors.accent + String(text[varStart..<end]) + colors.reset
                        i = end
                    } else {
                        result += colors.accent + String(text[varStart...]) + colors.reset
                        i = text.endIndex
                    }
                } else {
                    // $VAR
                    var end = i
                    while end < text.endIndex && (text[end].isLetter || text[end].isNumber || text[end] == "_") {
                        end = text.index(after: end)
                    }
                    result += colors.accent + String(text[varStart..<end]) + colors.reset
                    i = end
                }
                continue
            }

            // Quoted strings
            if ch == "\"" || ch == "'" {
                let quote = ch
                let start = i
                i = text.index(after: i)
                while i < text.endIndex && text[i] != quote {
                    if text[i] == "\\" && quote == "\"" {
                        i = text.index(after: i)  // skip escaped char
                    }
                    if i < text.endIndex { i = text.index(after: i) }
                }
                if i < text.endIndex { i = text.index(after: i) } // closing quote
                result += colors.branch + String(text[start..<i]) + colors.reset
                continue
            }

            // Tilde
            if ch == "~" {
                result += colors.path + "~" + colors.reset
                i = text.index(after: i)
                continue
            }

            // Default character
            result += String(ch)
            i = text.index(after: i)
        }

        return result
    }

    // MARK: - Tab Completion

    private func tabComplete() -> String? {
        let current = String(buffer)
        guard !current.isEmpty else { return nil }

        let parts = current.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        // First word: complete command names
        if parts.count <= 1 {
            return completeCommandName(prefix: current)
        }

        // Subsequent words: complete file paths
        let lastPart = parts.last ?? ""
        guard let completed = completeFilePath(prefix: lastPart) else { return nil }
        var newParts = parts
        newParts[newParts.count - 1] = completed
        return newParts.joined(separator: " ")
    }

    private func completeCommandName(prefix: String) -> String? {
        let lowered = prefix.lowercased()

        // Builtins first
        let builtinMatches = Self.builtinNames.filter { $0.hasPrefix(lowered) }.sorted()
        if let match = builtinMatches.first { return match }

        // PATH executables
        let pathEntries = (shell.context.environment["PATH"] ?? "").split(separator: ":")
        var candidates: [String] = []
        let fm = FileManager.default
        for entry in pathEntries {
            let dir = String(entry)
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasPrefix(prefix) {
                if fm.isExecutableFile(atPath: dir + "/" + file) {
                    candidates.append(file)
                }
            }
            if candidates.count > 20 { break }
        }

        return candidates.sorted().first
    }

    private func completeFilePath(prefix: String) -> String? {
        let fm = FileManager.default
        let home = shell.context.environment["HOME"] ?? ""

        // Expand the prefix to an absolute path for lookup
        let expanded: String
        if prefix.hasPrefix("~/") {
            expanded = home + String(prefix.dropFirst())
        } else if prefix.hasPrefix("/") {
            expanded = prefix
        } else {
            expanded = shell.context.currentDirectory + "/" + prefix
        }

        // Split into directory and partial filename
        let dir: String
        let partial: String
        if let lastSlash = expanded.lastIndex(of: "/") {
            dir = String(expanded[...lastSlash])
            partial = String(expanded[expanded.index(after: lastSlash)...])
        } else {
            dir = shell.context.currentDirectory + "/"
            partial = expanded
        }

        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let matches = entries.filter { $0.hasPrefix(partial) }.sorted()
        guard let match = matches.first else { return nil }

        let fullPath = dir + match
        var isDir: ObjCBool = false
        fm.fileExists(atPath: fullPath, isDirectory: &isDir)
        let suffix = isDir.boolValue ? "/" : ""

        // Return in the same style as the prefix
        if prefix.hasPrefix("~/") {
            let relStart = prefix.startIndex
            let lastSlash = prefix.lastIndex(of: "/") ?? relStart
            return String(prefix[...lastSlash]) + match + suffix
        } else if prefix.hasPrefix("/") {
            if let lastSlash = prefix.lastIndex(of: "/") {
                return String(prefix[...lastSlash]) + match + suffix
            }
            return "/" + match + suffix
        } else if prefix.contains("/") {
            if let lastSlash = prefix.lastIndex(of: "/") {
                return String(prefix[...lastSlash]) + match + suffix
            }
        }

        return match + suffix
    }

    private func ghostSuggestion() -> (command: String?, metadata: String?) {
        let current = String(buffer)
        if !current.isEmpty {
            if let completion = shell.sessionStore.completion(prefix: current, limit: 1).first {
                return (completion, "complete> Tab accepts '\(completion)' from local history")
            }
            return (nil, nil)
        }

        // Active AI suggestion takes priority when buffer is empty
        if let aiSuggestion = activeAISuggestion {
            return (aiSuggestion, "ai> \(aiSuggestion)")
        }

        if let prediction = shell.sessionStore.predictions(seedCommand: nil, limit: 1).first {
            return (prediction.command, "next> \(prediction.command) | \(prediction.rationale)")
        }
        return (nil, nil)
    }

    private func compactDirectory(_ cwd: String) -> String {
        let home = shell.context.environment["HOME"] ?? ""
        if cwd == home {
            return "~"
        }
        if cwd.hasPrefix(home + "/") {
            return "~" + String(cwd.dropFirst(home.count))
        }
        return cwd
    }

    private func terminalWidth() -> Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return Int(size.ws_col)
        }
        return 100
    }

    private func truncated(_ text: String, width: Int) -> String {
        guard text.count > width else {
            return text
        }
        guard width > 3 else {
            return String(text.prefix(width))
        }
        return String(text.prefix(width - 3)) + "..."
    }

    private func emit(_ result: ShellRunResult) {
        let formatter = TerminalOutputFormatter(colors: colors)
        if !result.stdout.isEmpty {
            let content = rawToTerminal(result.stdout)
            writeOut(formatter.formatInlineOutput(content, isError: false))
        }
        if !result.stderr.isEmpty {
            let content = rawToTerminal(result.stderr)
            writeErr(formatter.formatInlineOutput(content, isError: true))
        }
    }

    // In raw terminal mode, bare \n doesn't return the cursor to column 0.
    // Translate \n to \r\n so output renders correctly.
    private func rawToTerminal(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    private func writeOut(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private func writeErr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    private func readKey() -> Key? {
        var byte: UInt8 = 0
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        guard count == 1 else {
            return nil
        }

        switch byte {
        case 2:
            return .ctrlB
        case 3:
            return .ctrlC
        case 4:
            return .ctrlD
        case 9:
            return .tab
        case 10, 13:
            return .enter
        case 12:
            return .ctrlL
        case 16:
            return .ctrlP
        case 1:
            return .ctrlA
        case 5:
            return .ctrlE
        case 127:
            return .backspace
        case 27:
            return parseEscapeSequence()
        case 32...126:
            return .character(Character(UnicodeScalar(byte)))
        default:
            return .unknown
        }
    }

    private func parseEscapeSequence() -> Key {
        var byte: UInt8 = 0
        guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else {
            return .unknown
        }
        guard byte == 91 else {
            return .unknown
        }
        guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else {
            return .unknown
        }

        switch byte {
        case 65:
            return .up
        case 66:
            return .down
        case 67:
            return .right
        case 68:
            return .left
        case 51:
            var trailing: UInt8 = 0
            _ = Darwin.read(STDIN_FILENO, &trailing, 1)
            return .delete
        case 60: // '<' — SGR mouse event: \033[<btn;col;rowM or m
            return parseSGRMouse()
        default:
            return .unknown
        }
    }

    // Parse SGR extended mouse: \033[<btn;col;rowM (press) or \033[<btn;col;rowm (release)
    // We already consumed \033[< — now read "btn;col;row" and the trailing M/m
    private func parseSGRMouse() -> Key {
        var chars: [Character] = []
        while true {
            var byte: UInt8 = 0
            guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { return .unknown }
            let ch = Character(UnicodeScalar(byte))
            if ch == "M" || ch == "m" {
                break
            }
            chars.append(ch)
            if chars.count > 20 { return .unknown } // safety
        }
        // Parse "btn;col;row"
        let parts = String(chars).split(separator: ";").compactMap { Int($0) }
        guard parts.count == 3 else { return .unknown }
        let button = parts[0]
        let col = parts[1] // 1-based
        // Only handle left-click press (button 0)
        if button == 0 {
            return .mouseClick(col: col - 1) // convert to 0-based
        }
        return .unknown
    }

    private static func shouldUseColor(environment: [String: String]) -> Bool {
        if environment["NO_COLOR"] != nil {
            return false
        }
        if environment["TERM"] == "dumb" {
            return false
        }
        return isatty(STDOUT_FILENO) == 1
    }
}

private struct PromptRender {
    let displayLine: String      // prompt + highlighted buffer (may contain ANSI codes)
    let ghostSuffix: String      // ghost completion text (no ANSI)
    let cursorColumn: Int        // visible column for cursor (0-based)
    let occupiedWidth: Int       // visible width consumed by prompt + buffer + ghost
}

private struct PaletteAction {
    enum Mode {
        case load
        case run
    }

    let title: String
    let subtitle: String
    let command: String
    let mode: Mode

    var searchText: String {
        [title, subtitle, command].joined(separator: " ")
    }
}

private enum Key {
    case character(Character)
    case enter
    case backspace
    case delete
    case left
    case right
    case up
    case down
    case tab
    case ctrlA
    case ctrlB
    case ctrlC
    case ctrlD
    case ctrlE
    case ctrlL
    case ctrlP
    case mouseClick(col: Int)
    case unknown
}

// CotEditor-inspired ANSI palette
// Warm, subdued tones. Clear hierarchy. Minimal chrome.
struct AnsiPalette {
    let enabled: Bool
    private let t: Theme

    init(enabled: Bool, theme: Theme = .ocean) {
        self.enabled = enabled
        self.t = theme
    }

    private func c(_ n: Int) -> String { enabled ? "\u{001B}[38;5;\(n)m" : "" }

    var reset: String { enabled ? "\u{001B}[0m" : "" }

    var prompt: String { c(t.prompt) }
    var path: String { c(t.path) }
    var separator: String { c(t.separator) }
    var status: String { enabled ? "\u{001B}[38;5;250m" : "" }
    var statusLabel: String { c(t.hint) }
    var branch: String { c(t.branch) }
    var statusOk: String { c(t.statusOk) }
    var statusErr: String { c(t.statusErr) }
    var intentColor: String { c(t.intent) }
    var leaseColor: String { c(t.lease) }
    var attentionColor: String { c(t.attention) }
    var proofColor: String { c(t.proof) }
    var hint: String { c(t.hint) }
    var ghost: String { c(t.ghost) }
    var accent: String { c(t.accent) }
    var dim: String { enabled ? "\u{001B}[2m" : "" }
    var theme: Theme { t }
}

private final class RawTerminalMode {
    private var original: termios

    private init(original: termios) {
        self.original = original
    }

    static func activate() -> RawTerminalMode? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return nil
        }

        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
            return nil
        }
        return RawTerminalMode(original: original)
    }

    func restore() {
        var state = original
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &state)
    }
}

private final class SpinnerState: @unchecked Sendable {
    var running = false
}

private struct GitBranchCache {
    private var cachedDirectory = ""
    private var cachedBranch: String?

    mutating func branch(for directory: String) -> String? {
        guard directory != cachedDirectory else {
            return cachedBranch
        }
        cachedDirectory = directory
        cachedBranch = resolveBranch(for: directory)
        return cachedBranch
    }

    private func resolveBranch(for directory: String) -> String? {
        let fm = FileManager.default
        var currentURL = URL(fileURLWithPath: directory)
        while true {
            let gitURL = currentURL.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return branchFromGitDirectory(gitURL)
                }
                if let contents = try? String(contentsOf: gitURL, encoding: .utf8),
                   let prefixRange = contents.range(of: "gitdir: ") {
                    let rawPath = contents[prefixRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolved = URL(fileURLWithPath: rawPath, relativeTo: currentURL).standardizedFileURL
                    return branchFromGitDirectory(resolved)
                }
            }

            let parent = currentURL.deletingLastPathComponent()
            if parent.path == currentURL.path {
                return nil
            }
            currentURL = parent
        }
    }

    private func branchFromGitDirectory(_ gitDirectory: URL) -> String? {
        let headURL = gitDirectory.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else {
            return nil
        }

        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return String(trimmed.prefix(7))
    }
}

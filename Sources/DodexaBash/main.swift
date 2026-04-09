import DodexaCodeCore
import Foundation

let shell = Shell()
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--mcp") {
    DodexaMcpServer(shell: shell).serve()
    Foundation.exit(0)
}

if let commandIndex = arguments.firstIndex(of: "-c"), arguments.indices.contains(arguments.index(after: commandIndex)) {
    let source = arguments[arguments.index(after: commandIndex)]
    let result = shell.run(source: source)
    emit(result)
    Foundation.exit(result.shouldExit ? Int32(result.status) : result.status)
}

if let scriptPath = arguments.first {
    do {
        let source = try String(contentsOfFile: scriptPath, encoding: .utf8)
        let result = shell.run(source: source)
        emit(result)
        Foundation.exit(result.shouldExit ? Int32(result.status) : result.status)
    } catch {
        FileHandle.standardError.write(Data("dodexabash: \(error.localizedDescription)\n".utf8))
        Foundation.exit(1)
    }
}

TerminalUI(shell: shell).run()

private func emit(_ result: ShellRunResult) {
    if !result.stdout.isEmpty {
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
    }
    if !result.stderr.isEmpty {
        FileHandle.standardError.write(Data(result.stderr.utf8))
    }
}

import XCTest
@testable import DodexaBashCore

final class ShellTests: XCTestCase {

    private func makeShell() -> Shell {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dodexabash-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return Shell(stateRoot: tmp)
    }

    // MARK: - Core Execution

    func testEchoBasic() {
        let shell = makeShell()
        let result = shell.run(source: "echo hello world")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testExitStatus() {
        let shell = makeShell()
        let result = shell.run(source: "echo ok")
        XCTAssertEqual(result.status, 0)
    }

    func testVariableExpansion() {
        let shell = makeShell()
        _ = shell.run(source: "export TESTVAR=hello123")
        let result = shell.run(source: "echo $TESTVAR")
        XCTAssertTrue(result.stdout.contains("hello123"))
    }

    func testLastExitStatus() {
        let shell = makeShell()
        _ = shell.run(source: "echo ok")
        let result = shell.run(source: "echo $?")
        XCTAssertTrue(result.stdout.contains("0"))
    }

    func testCommandSubstitution() {
        let shell = makeShell()
        let result = shell.run(source: "echo $(echo nested)")
        XCTAssertTrue(result.stdout.contains("nested"))
    }

    // MARK: - Pipelines

    func testSimplePipeline() {
        let shell = makeShell()
        let result = shell.run(source: "echo hello | cat")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("hello"))
    }

    func testPipelineExitStatus() {
        let shell = makeShell()
        let result = shell.run(source: "echo test | cat | cat")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("test"))
    }

    // MARK: - Conditionals

    func testAndIfSuccess() {
        let shell = makeShell()
        let result = shell.run(source: "echo first && echo second")
        XCTAssertTrue(result.stdout.contains("first"))
        XCTAssertTrue(result.stdout.contains("second"))
    }

    func testAndIfFailure() {
        let shell = makeShell()
        let result = shell.run(source: "/usr/bin/false && echo should_not_appear")
        XCTAssertFalse(result.stdout.contains("should_not_appear"))
    }

    func testOrIfFallback() {
        let shell = makeShell()
        let result = shell.run(source: "/usr/bin/false || echo fallback")
        XCTAssertTrue(result.stdout.contains("fallback"))
    }

    // MARK: - Redirections

    func testOutputRedirection() {
        let shell = makeShell()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("redir-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = shell.run(source: "echo redirected > \(tmp.path)")
        let content = try? String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(content?.contains("redirected") ?? false)
    }

    func testAppendRedirection() {
        let shell = makeShell()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("append-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = shell.run(source: "echo line1 > \(tmp.path)")
        _ = shell.run(source: "echo line2 >> \(tmp.path)")
        let content = try? String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(content?.contains("line1") ?? false)
        XCTAssertTrue(content?.contains("line2") ?? false)
    }

    // MARK: - Blocks

    func testBlockCreation() {
        let shell = makeShell()
        _ = shell.run(source: "echo block_test")
        XCTAssertEqual(shell.blockStore.count, 1)
        let block = shell.blockStore.latest
        XCTAssertNotNil(block)
        XCTAssertEqual(block?.command, "echo block_test")
        XCTAssertEqual(block?.exitCode, 0)
        XCTAssertTrue(block?.output.stdout.contains("block_test") ?? false)
    }

    func testBlockGitBranch() {
        let shell = makeShell()
        _ = shell.run(source: "echo test")
        // May or may not have git branch depending on cwd, just verify no crash
        XCTAssertEqual(shell.blockStore.count, 1)
    }

    func testBlockProofId() {
        let shell = makeShell()
        _ = shell.run(source: "echo provenance_test")
        let block = shell.blockStore.latest
        XCTAssertNotNil(block?.proofId)
    }

    func testBlockRepairOnFailure() {
        let shell = makeShell()
        _ = shell.run(source: "nonexistent_command_xyz")
        let block = shell.blockStore.latest
        XCTAssertNotNil(block)
        XCTAssertNotEqual(block?.exitCode, 0)
        XCTAssertNotNil(block?.repairId)
    }

    func testBlockSearch() {
        let shell = makeShell()
        _ = shell.run(source: "echo searchable_token")
        _ = shell.run(source: "echo another_command")
        let results = shell.blockStore.search(query: "searchable")
        XCTAssertEqual(results.count, 1)
    }

    func testOnBlockCreatedCallback() {
        let shell = makeShell()
        var callbackFired = false
        shell.onBlockCreated = { block in
            callbackFired = true
            XCTAssertEqual(block.command, "echo callback_test")
        }
        _ = shell.run(source: "echo callback_test")
        XCTAssertTrue(callbackFired)
    }

    // MARK: - Future Shell Primitives

    func testSimulate() {
        let shell = makeShell()
        let result = shell.run(source: "simulate rm -rf /tmp/test")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("risk") || result.stdout.contains("simulate"))
    }

    func testIntentLifecycle() {
        let shell = makeShell()
        _ = shell.run(source: "intent set deploy v2.1")
        let show = shell.run(source: "intent show")
        XCTAssertTrue(show.stdout.contains("deploy"))
    }

    func testLeaseGrantAndList() {
        let shell = makeShell()
        _ = shell.run(source: "lease grant --scope ./src --ops read --grantee agent")
        let list = shell.run(source: "lease list")
        XCTAssertTrue(list.stdout.contains("agent") || list.stdout.contains("lease"))
    }

    func testProveAfterExecution() {
        let shell = makeShell()
        _ = shell.run(source: "echo proof_check")
        let result = shell.run(source: "prove list")
        XCTAssertEqual(result.status, 0)
    }

    // MARK: - Builtins

    func testCdBuiltin() {
        let shell = makeShell()
        let original = FileManager.default.currentDirectoryPath
        defer { _ = FileManager.default.changeCurrentDirectoryPath(original) }
        _ = shell.run(source: "cd /tmp")
        let result = shell.run(source: "pwd")
        // /tmp may resolve to /private/tmp on macOS
        XCTAssertTrue(result.stdout.contains("tmp"))
    }

    func testExportAndEnv() {
        let shell = makeShell()
        _ = shell.run(source: "export MY_TEST_VAR=test_value_42")
        let result = shell.run(source: "env")
        XCTAssertTrue(result.stdout.contains("MY_TEST_VAR=test_value_42"))
    }

    func testHistoryBuiltin() {
        let shell = makeShell()
        _ = shell.run(source: "echo first")
        _ = shell.run(source: "echo second")
        let result = shell.run(source: "history")
        XCTAssertEqual(result.status, 0)
    }

    func testHelpBuiltin() {
        let shell = makeShell()
        let result = shell.run(source: "help")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("dodexabash") || result.stdout.contains("help"))
    }

    func testMcpStatusBuiltin() {
        let shell = makeShell()
        let result = shell.run(source: "mcp status")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("MCP") || result.stdout.contains("No MCP"))
    }

    func testBlocksListBuiltin() {
        let shell = makeShell()
        _ = shell.run(source: "echo test")
        let result = shell.run(source: "blocks list")
        XCTAssertEqual(result.status, 0)
    }

    func testJobsBuiltin() {
        let shell = makeShell()
        let result = shell.run(source: "jobs")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("No active jobs"))
    }

    // MARK: - Streaming Pipeline

    func testStreamingPipelineExternalOnly() {
        let shell = makeShell()
        // This should use the streaming (OS pipe) path since all are external commands
        let result = shell.run(source: "/bin/echo streaming_test | /usr/bin/tr 'a-z' 'A-Z'")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("STREAMING_TEST"))
    }

    // MARK: - Globbing

    func testGlobExpansion() {
        let shell = makeShell()
        let result = shell.run(source: "echo /usr/bin/sw*")
        XCTAssertEqual(result.status, 0)
        // Should expand to something like /usr/bin/sw_vers or /usr/bin/swift
    }

    // MARK: - Aliases

    func testAliasExpansion() {
        let shell = makeShell()
        // ll is a default alias for "ls -la"
        let result = shell.run(source: "ll")
        XCTAssertEqual(result.status, 0)
    }
}

import Foundation

// Minimal test harness: SwiftPM and XCTest are unavailable with this Command Line Tools install,
// so the self-tests are a plain executable that exits non-zero on any failure.

var testsPassed = 0
var testsFailed = 0
var currentTestFailed = false

func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    currentTestFailed = true
    let name = URL(fileURLWithPath: "\(file)").lastPathComponent
    print("    ✗ \(message)  [\(name):\(line)]")
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    if !condition { fail("expectation failed \(message())", file: file, line: line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if actual != expected { fail("expected «\(expected)» got «\(actual)» \(message)", file: file, line: line) }
}

func test(_ name: String, _ body: () throws -> Void) {
    currentTestFailed = false
    do { try body() } catch { fail("threw \(error)") }
    if currentTestFailed {
        testsFailed += 1
        print("FAIL \(name)")
    } else {
        testsPassed += 1
        print("ok   \(name)")
    }
}

/// Scratch directory for a test. CLAUDEDICT_TEST_TMP overrides the base (defaults to $TMPDIR).
func tempDir() -> String {
    let base = ProcessInfo.processInfo.environment["CLAUDEDICT_TEST_TMP"] ?? NSTemporaryDirectory()
    let path = (base as NSString).appendingPathComponent("claudedict-tests-" + UUID().uuidString)
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

func writeScript(_ dir: String, _ name: String, _ body: String) -> String {
    let path = (dir as NSString).appendingPathComponent(name)
    FileManager.default.createFile(atPath: path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o755])
    return path
}

func fixturePath(_ name: String) -> String {
    URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
        .appendingPathComponent("fixtures").appendingPathComponent(name).path
}

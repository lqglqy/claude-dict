import Foundation

print("ClaudeDict core self-tests")
runTextAnalyzerTests()
runPromptTests()
runStreamTests()
runMarkdownTests()
runLocatorTests()
runCommandTests()
runSettingsTests()
runEngineTests()
print("\n\(testsPassed) passed, \(testsFailed) failed")
exit(testsFailed == 0 ? 0 : 1)

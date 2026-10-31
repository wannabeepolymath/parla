import Foundation

/// Optional lifecycle evidence for test-owned directories; never selects or deletes paths.
func recordTestFixture(_ root: URL, _ action: String) throws {
    guard let path = ProcessInfo.processInfo.environment["PARLA_TEST_FIXTURE_MANIFEST"] else { return }
    let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? file.close() }
    try file.seekToEnd()
    try file.write(contentsOf: Data("\(action)\t\(ProcessInfo.processInfo.processIdentifier)\t\(root.path)\n".utf8))
}

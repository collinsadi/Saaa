import Foundation
import Testing
@testable import Matching

/// Archives sealed before agent provenance existed must still decode: the
/// new fields default instead of failing the whole session archive.
@Test func decodesCandidateJSONWithoutProvenanceFields() throws {
    let old = """
    {"path":"file:///p/acme/","name":"acme","hasClaudeMD":true,
     "profileTerms":["acme","api"]}
    """
    let candidate = try JSONDecoder().decode(
        ProjectCandidate.self, from: Data(old.utf8))
    #expect(candidate.name == "acme")
    #expect(candidate.hasClaudeMD == true)
    #expect(candidate.hasAgentsMD == false)
    #expect(candidate.knownTo.isEmpty)
}

@Test func nestedCwdIsFoundInSessionLogHead() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("matching-cwd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let log = dir.appendingPathComponent("rollout.jsonl")
    try #"{"type":"session_meta","payload":{"cwd":"/some/project"}}"#
        .write(to: log, atomically: true, encoding: .utf8)
    #expect(CandidateEnumerator.cwdFromLogHead(log)?.path == "/some/project")

    let flat = dir.appendingPathComponent("claude.jsonl")
    try #"{"cwd":"/other/project","sessionId":"x"}"#
        .write(to: flat, atomically: true, encoding: .utf8)
    #expect(CandidateEnumerator.cwdFromLogHead(flat)?.path == "/other/project")
}

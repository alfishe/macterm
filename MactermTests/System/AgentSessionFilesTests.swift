import Foundation
@testable import Macterm
import Testing

@MainActor
struct AgentSessionFilesTests {
    private let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSessionFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    private func files(alive: Set<pid_t> = []) -> AgentSessionFiles {
        AgentSessionFiles(home: home, isAlive: { alive.contains($0) })
    }

    private func write(_ text: String, to path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test
    func reads_a_claude_session_file() throws {
        try write(
            #"{"pid":4242,"sessionId":"abc","cwd":"/w","kind":"interactive","status":"idle","extra":1}"#,
            to: ".claude/sessions/4242.json"
        )
        let session = files().claudeSession(pid: 4242)
        #expect(session?.sessionId == "abc")
        #expect(session?.cwd == "/w")
        #expect(session?.status == "idle")
        #expect(files().claudeSession(pid: 1) == nil)
    }

    @Test
    func a_claude_session_runs_only_with_a_live_process() throws {
        try write(#"{"sessionId":"abc"}"#, to: ".claude/sessions/4242.json")
        #expect(files(alive: [4242]).claudeSessionIsRunning("abc"))
        #expect(!files(alive: []).claudeSessionIsRunning("abc"))
        #expect(!files(alive: [4242]).claudeSessionIsRunning("other"))
    }

    @Test
    func parses_the_pid_of_a_qoder_segment() {
        #expect(AgentSessionFiles.qoderPID(segmentFileName: "1763-2-p31337.jsonl") == 31337)
        #expect(AgentSessionFiles.qoderPID(segmentFileName: "notes.txt") == nil)
        #expect(AgentSessionFiles.qoderPID(segmentFileName: "x-pabc.jsonl") == nil)
    }

    @Test
    func finds_the_qoder_session_of_a_process() throws {
        try write("{}", to: ".qoder/logs/sessions/-w/sid-1/segments/1-p77.jsonl")
        try write("{}", to: ".qoder/logs/sessions/-w/sid-2/segments/2-p88.jsonl")
        #expect(files().qoderSessionID(pid: 77) == "sid-1")
        #expect(files().qoderSessionID(pid: 99) == nil)
        #expect(files(alive: [88]).qoderSessionIsRunning("sid-2"))
        #expect(!files(alive: [88]).qoderSessionIsRunning("sid-1"))
    }

    @Test
    func missing_directories_read_as_nothing() {
        let empty = files()
        #expect(empty.claudeSession(pid: 1) == nil)
        #expect(!empty.claudeSessionIsRunning("x"))
        #expect(empty.qoderSessionID(pid: 1) == nil)
    }
}

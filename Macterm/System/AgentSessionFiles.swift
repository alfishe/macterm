import Darwin
import Foundation

/// Fork: reads the files where the agent CLIs record their sessions, for
/// `AgentResume`. The formats belong to the agents, not to Macterm, and can
/// change with an agent update: every read fails soft (nil, false).
///
/// - Claude Code writes `~/.claude/sessions/<pid>.json` for each running
///   process: `sessionId`, `cwd`, `kind` (`interactive`, `bg`, ...) and
///   `status` (`idle`, `busy`, ...). The id changes in place after `/clear`
///   or `/resume`.
/// - Qoder CLI keeps `~/.qoder/logs/sessions/<cwd>/<sessionId>/segments/<run>-p<pid>.jsonl`
///   open for each run. The directory name is the session id.
struct AgentSessionFiles {
    /// The home directory to read from. Tests give a temporary directory.
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Whether a process runs. Tests inject a fake.
    var isAlive: (pid_t) -> Bool = AgentSessionFiles.processIsAlive

    /// One Claude Code session file.
    struct ClaudeSession: Decodable, Equatable {
        let pid: Int32?
        let sessionId: String
        let cwd: String?
        let kind: String?
        let status: String?
    }

    // MARK: - Claude Code

    private var claudeSessionsDirectory: URL {
        home.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// The session file of the Claude Code process `pid`, or nil.
    func claudeSession(pid: pid_t) -> ClaudeSession? {
        let url = claudeSessionsDirectory.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeSession.self, from: data)
    }

    /// Whether a running Claude Code process has the session `sessionID`.
    /// A session that runs (in another pane, another terminal, or as a
    /// background agent with a process) must not start a second time.
    func claudeSessionIsRunning(_ sessionID: String) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: claudeSessionsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in files where url.pathExtension == "json" {
            guard let pid = Int32(url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let session = try? JSONDecoder().decode(ClaudeSession.self, from: data),
                  session.sessionId == sessionID
            else { continue }
            if isAlive(pid) { return true }
        }
        return false
    }

    // MARK: - Qoder CLI

    private var qoderSessionsDirectory: URL {
        home.appendingPathComponent(".qoder/logs/sessions", isDirectory: true)
    }

    /// One segment file of a Qoder CLI run.
    private struct QoderSegment {
        let sessionID: String
        let pid: pid_t
        let modified: Date
    }

    /// The segment files of all Qoder CLI runs.
    private func qoderSegments() -> [QoderSegment] {
        let fm = FileManager.default
        var result: [QoderSegment] = []
        for cwdDir in (try? fm.contentsOfDirectory(at: qoderSessionsDirectory, includingPropertiesForKeys: nil)) ?? [] {
            for sessionDir in (try? fm.contentsOfDirectory(at: cwdDir, includingPropertiesForKeys: nil)) ?? [] {
                let segments = sessionDir.appendingPathComponent("segments", isDirectory: true)
                let files = (try? fm.contentsOfDirectory(
                    at: segments,
                    includingPropertiesForKeys: [.contentModificationDateKey]
                )) ?? []
                for file in files {
                    guard let pid = Self.qoderPID(segmentFileName: file.lastPathComponent) else { continue }
                    let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    result.append(QoderSegment(sessionID: sessionDir.lastPathComponent, pid: pid, modified: modified))
                }
            }
        }
        return result
    }

    /// The pid in a segment file name `<run>-p<pid>.jsonl`, or nil.
    static func qoderPID(segmentFileName name: String) -> pid_t? {
        guard name.hasSuffix(".jsonl"), let marker = name.range(of: "-p", options: .backwards) else { return nil }
        let digits = name[marker.upperBound...].dropLast(".jsonl".count)
        return pid_t(digits)
    }

    /// The session id of the Qoder CLI process `pid`, or nil. With more than
    /// one match (a `/resume` inside the run) the newest segment wins.
    func qoderSessionID(pid: pid_t) -> String? {
        qoderSegments()
            .filter { $0.pid == pid }
            .max { $0.modified < $1.modified }?
            .sessionID
    }

    /// Whether a running Qoder CLI process has the session `sessionID`.
    func qoderSessionIsRunning(_ sessionID: String) -> Bool {
        qoderSegments().contains { $0.sessionID == sessionID && isAlive($0.pid) }
    }

    // MARK: - Both

    /// Whether a running process has the agent session `resume`.
    func sessionIsRunning(_ resume: AgentResume) -> Bool {
        switch resume.agent {
        case .claude: claudeSessionIsRunning(resume.sessionID)
        case .qodercli: qoderSessionIsRunning(resume.sessionID)
        }
    }

    /// `kill(pid, 0)`: 0 or EPERM means the process exists.
    static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

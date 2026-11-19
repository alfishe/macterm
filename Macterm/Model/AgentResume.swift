import Foundation

/// Fork: the AI agent session that runs in a pane, recorded so that Macterm
/// can start the agent again in the same session after the pane's own session
/// died (a reboot, a crash of the session server, an update that ended the
/// sessions). A session that survived needs nothing: its agent still runs.
///
/// Captured each minute and at quit (`AppState.captureAgentResumes`), saved in
/// `PaneSnapshot.agentResume`, and used once at launch
/// (`AppState.restoreAgentSessions`). Pure: no file system, no processes.
struct AgentResume: Codable, Equatable {
    /// The agent CLI. The raw value is the command name.
    enum Agent: String, Codable, CaseIterable {
        case claude
        case qodercli
    }

    let agent: Agent
    /// The agent's own session id (a UUID string for both agents).
    let sessionID: String
    /// The directory the agent was started in. Both agents find their
    /// transcript from it, so the resume must start there.
    let directory: String
    /// The agent's original arguments without the session selectors
    /// (`--resume`, `--continue`, ...), for example `--dangerously-skip-permissions`.
    let arguments: [String]

    init(agent: Agent, sessionID: String, directory: String, arguments: [String] = []) {
        self.agent = agent
        self.sessionID = sessionID
        self.directory = directory
        self.arguments = arguments
    }

    /// The line to type at the shell prompt of the pane: change to the
    /// directory, then start the agent on its session. Every word is quoted
    /// for a POSIX shell (zsh, bash, fish accept the same single quotes).
    var shellCommand: String {
        let words = [agent.rawValue] + arguments + ["--resume", sessionID]
        return "cd \(Self.shellQuoted(directory)) && " + words.map(Self.shellQuoted).joined(separator: " ")
    }

    /// `word` in single quotes when it has a character a shell reads. A
    /// single quote inside becomes `'\''`.
    static func shellQuoted(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@%+,")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Recognition

    /// The agent that `argv` runs, or nil. Matches the invoked name
    /// (`ProcessInspector.invokedName(argv:)`, which also reads through
    /// `node script`) and the kernel `comm`. Claude Code's native install has
    /// a version as its `comm` (`2.1.326`) and `claude` as argv[0].
    static func agent(argv: [String], comm: String?) -> Agent? {
        let names = [ProcessInspector.invokedName(argv: argv), comm].compactMap { $0?.lowercased() }
        for name in names {
            for agent in Agent.allCases where name == agent.rawValue || name.hasPrefix(agent.rawValue + "-") {
                return agent
            }
        }
        return nil
    }

    /// Whether the agent runs a session that a person types into. A one-shot
    /// run (`claude -p "…"`) or a subcommand (`claude mcp list`) has no
    /// session to resume.
    static func isInteractive(agent: Agent, arguments: [String]) -> Bool {
        let oneShot: Set = ["-p", "--print", "-h", "--help", "-v", "--version", "--list-sessions"]
        if arguments.contains(where: { oneShot.contains($0) }) { return false }
        // A first word that is not an option is a subcommand or a prompt.
        // A prompt (`claude "fix it"`) still opens an interactive session.
        if let first = arguments.first, !first.hasPrefix("-") {
            return !subcommands(of: agent).contains(first)
        }
        return true
    }

    private static func subcommands(of agent: Agent) -> Set<String> {
        switch agent {
        case .claude:
            ["agents", "auth", "config", "doctor", "install", "mcp", "migrate-installer", "plugin", "setup-token", "update", "upgrade"]
        case .qodercli:
            ["config", "login", "logout", "mcp", "update", "version"]
        }
    }

    /// The arguments of the program in `argv`: without argv[0], and without
    /// the script when argv[0] is an interpreter (`node …/cli.js --flag`).
    static func programArguments(argv: [String]) -> [String] {
        var rest = Array(argv.dropFirst())
        if let first = argv.first,
           ProcessInspector.isInterpreterName((first as NSString).lastPathComponent),
           !rest.isEmpty
        {
            rest.removeFirst()
        }
        return rest
    }

    /// The arguments to keep for the resume: `argv` without argv[0] (and
    /// without the script of `node script`), without the options that select
    /// a session, and without a prompt word (a resume must not send the first
    /// prompt again).
    static func keptArguments(argv: [String]) -> [String] {
        let rest = programArguments(argv: argv)
        let selectorsWithValue: Set = ["-r", "--resume", "--session-id", "--from-pr"]
        let bareSelectors: Set = ["-c", "--continue", "--fork-session"]
        // Options whose value is a separate word, so the value is not taken
        // for a prompt.
        let optionsWithValue: Set = [
            "--model", "--permission-mode", "--add-dir", "--allowedTools", "--allowed-tools",
            "--disallowedTools", "--disallowed-tools", "--mcp-config", "--settings", "--agent",
            "--append-system-prompt", "--system-prompt", "--fallback-model", "--output-format",
            "--input-format", "--setting-sources", "--plugin-dir", "--betas", "--agents",
            "--max-turns", "--workspace", "-w",
        ]
        var kept: [String] = []
        var index = 0
        while index < rest.count {
            let word = rest[index]
            let name = String(word.split(separator: "=", maxSplits: 1).first ?? "")
            if selectorsWithValue.contains(word) {
                // `--resume` without a value opens a picker. Skip the value
                // only when it is there.
                let next = index + 1 < rest.count ? rest[index + 1] : nil
                index += next.map { $0.hasPrefix("-") } == false ? 2 : 1
                continue
            }
            if selectorsWithValue.contains(name) || bareSelectors.contains(word) {
                index += 1
                continue
            }
            if optionsWithValue.contains(word), index + 1 < rest.count {
                kept += [word, rest[index + 1]]
                index += 2
                continue
            }
            // A word that is not an option is a prompt. Drop it.
            if !word.hasPrefix("-") {
                index += 1
                continue
            }
            kept.append(word)
            index += 1
        }
        return kept
    }
}

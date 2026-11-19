import Foundation
@testable import Macterm
import Testing

@MainActor
struct AgentResumeTests {
    // MARK: Recognition

    @Test
    func recognizes_claude_native_install_by_argv0() {
        // The native install has a version as its comm.
        #expect(AgentResume.agent(argv: ["claude", "--dangerously-skip-permissions"], comm: "2.1.326") == .claude)
        #expect(AgentResume.agent(argv: ["/Users/u/.local/bin/claude"], comm: nil) == .claude)
    }

    @Test
    func recognizes_claude_run_by_node() {
        #expect(AgentResume.agent(argv: ["node", "/opt/homebrew/bin/claude"], comm: "node") == .claude)
    }

    @Test
    func recognizes_qodercli() {
        #expect(AgentResume.agent(argv: ["qodercli", "--yolo"], comm: "qodercli") == .qodercli)
    }

    @Test
    func ignores_other_programs() {
        #expect(AgentResume.agent(argv: ["zsh"], comm: "zsh") == nil)
        #expect(AgentResume.agent(argv: ["claudette"], comm: "claudette") == nil)
        #expect(AgentResume.agent(argv: ["vim", "claude.md"], comm: "vim") == nil)
    }

    // MARK: Interactive

    @Test
    func a_plain_or_prompted_session_is_interactive() {
        #expect(AgentResume.isInteractive(agent: .claude, arguments: []))
        #expect(AgentResume.isInteractive(agent: .claude, arguments: ["--model", "opus"]))
        #expect(AgentResume.isInteractive(agent: .claude, arguments: ["fix the build"]))
    }

    @Test
    func one_shot_runs_and_subcommands_are_not_interactive() {
        #expect(!AgentResume.isInteractive(agent: .claude, arguments: ["-p", "hello"]))
        #expect(!AgentResume.isInteractive(agent: .claude, arguments: ["--print", "hello"]))
        #expect(!AgentResume.isInteractive(agent: .claude, arguments: ["mcp", "list"]))
        #expect(!AgentResume.isInteractive(agent: .qodercli, arguments: ["--list-sessions"]))
    }

    // MARK: Arguments

    @Test
    func keeps_flags_and_drops_session_selectors() {
        let argv = ["claude", "--dangerously-skip-permissions", "--resume", "00000000-0000-4000-8000-000000000001", "--model", "opus"]
        #expect(AgentResume.keptArguments(argv: argv) == ["--dangerously-skip-permissions", "--model", "opus"])
    }

    @Test
    func drops_short_and_equals_forms_of_selectors() {
        #expect(AgentResume.keptArguments(argv: ["claude", "-r", "abc", "-c"]).isEmpty)
        #expect(AgentResume.keptArguments(argv: ["claude", "--resume=abc", "--session-id=def", "--verbose"]) == ["--verbose"])
    }

    @Test
    func a_resume_without_a_value_does_not_eat_the_next_flag() {
        #expect(AgentResume.keptArguments(argv: ["claude", "--resume", "--verbose"]) == ["--verbose"])
    }

    @Test
    func drops_the_first_prompt() {
        #expect(AgentResume.keptArguments(argv: ["claude", "--model", "opus", "fix the build"]) == ["--model", "opus"])
    }

    @Test
    func drops_the_script_of_an_interpreter() {
        #expect(AgentResume.keptArguments(argv: ["node", "/usr/local/bin/claude", "--verbose"]) == ["--verbose"])
        #expect(AgentResume.programArguments(argv: ["node", "/usr/local/bin/claude", "-p"]) == ["-p"])
    }

    // MARK: Command

    @Test
    func builds_the_resume_command() {
        let resume = AgentResume(
            agent: .claude,
            sessionID: "00000000-0000-4000-8000-000000000001",
            directory: "/tmp/project",
            arguments: ["--dangerously-skip-permissions"]
        )
        let expected = "cd /tmp/project && "
            + "claude --dangerously-skip-permissions --resume 00000000-0000-4000-8000-000000000001"
        #expect(resume.shellCommand == expected)
    }

    @Test
    func quotes_words_with_shell_characters() {
        #expect(AgentResume.shellQuoted("/Users/u/My Project") == "'/Users/u/My Project'")
        #expect(AgentResume.shellQuoted("it's") == "'it'\\''s'")
        #expect(AgentResume.shellQuoted("$(rm -rf ~)") == "'$(rm -rf ~)'")
        #expect(AgentResume.shellQuoted("") == "''")
        #expect(AgentResume.shellQuoted("--model=opus") == "--model=opus")
    }

    // MARK: Persistence

    @Test
    func pane_snapshot_round_trips_the_record() throws {
        let resume = AgentResume(agent: .qodercli, sessionID: "s1", directory: "/tmp/x", arguments: ["--yolo"])
        let snapshot = PaneSnapshot(id: UUID(), projectPath: "/tmp/x", sessionName: "macterm-x", agentResume: resume)
        let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.agentResume == resume)
    }

    @Test
    func an_older_pane_snapshot_decodes_without_a_record() throws {
        let json = #"{"id":"\#(UUID().uuidString)","projectPath":"/tmp/x"}"#
        let decoded = try JSONDecoder().decode(PaneSnapshot.self, from: Data(json.utf8))
        #expect(decoded.agentResume == nil)
    }
}

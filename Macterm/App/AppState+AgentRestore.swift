import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "AgentRestore")

/// Fork: automatic persistence and restore of AI agent sessions (`AgentResume`).
///
/// - **Capture.** Each minute and at quit, every LOCAL pane of an ordinary
///   workspace records the agent in its foreground: the agent, its session id,
///   its directory and its flags. A pane at a shell prompt records nothing.
///   The snapshot saves the record (`PaneSnapshot.agentResume`) when it
///   changed.
/// - **Restore.** At launch, a pane with a record waits in
///   `Pane.agentResumePending`. One pane at a time: start its terminal, wait
///   for its shell, and type `cd <dir> && <agent> <flags> --resume <id>`
///   only when the shell is idle at its prompt. A session that survived
///   already shows its agent, so it gets nothing. Then wait until the agent
///   is ready before the next pane: a resume loads the whole transcript, and
///   many at a time put the Mac into swap.
/// - **Never typed:** into a pane that runs another program, for a session
///   that runs somewhere else, for a directory that is gone, or into a dialog
///   of the agent. A failure is logged and the next pane goes on.
/// - `Preferences.agentAutoRestore` (default on) turns all of it off.
extension AppState {
    /// The capture interval.
    static let agentCaptureInterval: TimeInterval = 60

    /// Start the minute capture and, after the windows restore, the restore
    /// of the agents. Called once, from `restoreSelection`.
    func startAgentSessionPersistence(projectOrder: [UUID]) {
        agentCaptureTimer?.invalidate()
        let timer = Timer(timeInterval: Self.agentCaptureInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.captureAgentResumes() { self.saveWorkspaces() }
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        agentCaptureTimer = timer

        performWhenRestored { [weak self] in
            Task { @MainActor [weak self] in
                // Let the launch settle first: the windows draw their tabs and
                // the session server answers its first listing.
                try? await Task.sleep(for: .seconds(3))
                await self?.restoreAgentSessions(projectOrder: projectOrder)
            }
        }
    }

    // MARK: - Capture

    /// The panes that can hold an agent record, in sidebar order: every local
    /// pane of every ordinary workspace. Pinned tabs have their own respawn
    /// recipe, and remote panes run their agent on another host.
    private func agentCandidatePanes(projectOrder: [UUID] = []) -> [Pane] {
        let rank = Dictionary(projectOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return workspaces.values
            .filter { $0.kind != .pinned }
            .sorted { (rank[$0.id] ?? Int.max, $0.id.uuidString) < (rank[$1.id] ?? Int.max, $1.id.uuidString) }
            .flatMap(\.tabs)
            .flatMap { $0.splitRoot.allPanes() }
            .filter { !$0.isRemote }
    }

    /// Record the agent session of each pane. Returns whether a record
    /// changed, so that the caller saves only then. With the preference off,
    /// it removes every record: a record kept while off would go stale, and
    /// turning the preference on again would resume an old session.
    @discardableResult
    func captureAgentResumes(files: AgentSessionFiles = AgentSessionFiles()) -> Bool {
        guard Preferences.shared.agentAutoRestore else { return clearAgentResumes() }
        var changed = false
        for pane in agentCandidatePanes() where !pane.agentResumePending {
            // No foreground (a pane that never started, a session not listed
            // yet): nothing is known, so the record stays.
            guard let pid = ProcessInspector.resolvedForegroundPID(forPane: pane) else { continue }
            let next = Self.agentResume(pid: pid, files: files, current: pane.agentResume)
            if next != pane.agentResume {
                pane.agentResume = next
                changed = true
            }
        }
        return changed
    }

    /// Remove every record. Returns whether one was there.
    private func clearAgentResumes() -> Bool {
        var cleared = false
        for pane in agentCandidatePanes() where pane.agentResume != nil || pane.agentResumePending {
            pane.agentResume = nil
            pane.agentResumePending = false
            cleared = true
        }
        return cleared
    }

    /// The record for the foreground process `pid`. `current` stays when the
    /// process cannot be read yet: an agent that just started has no session
    /// file for a moment.
    static func agentResume(pid: pid_t, files: AgentSessionFiles, current: AgentResume?) -> AgentResume? {
        guard let argv = ProcessInspector.argv(pid: pid), !argv.isEmpty else { return current }
        guard let agent = AgentResume.agent(argv: argv, comm: ProcessInspector.comm(pid: pid)) else { return nil }
        guard AgentResume.isInteractive(agent: agent, arguments: AgentResume.programArguments(argv: argv)) else { return nil }
        let keep = current?.agent == agent ? current : nil
        switch agent {
        case .claude:
            guard let session = files.claudeSession(pid: pid) else { return keep }
            if let kind = session.kind, kind != "interactive" { return nil }
            guard let directory = session.cwd ?? ProcessInspector.workingDirectory(pid: pid) else { return keep }
            return AgentResume(
                agent: .claude,
                sessionID: session.sessionId,
                directory: directory,
                arguments: AgentResume.keptArguments(argv: argv)
            )
        case .qodercli:
            guard let sessionID = files.qoderSessionID(pid: pid),
                  let directory = ProcessInspector.workingDirectory(pid: pid)
            else { return keep }
            return AgentResume(
                agent: .qodercli,
                sessionID: sessionID,
                directory: directory,
                arguments: AgentResume.keptArguments(argv: argv)
            )
        }
    }

    // MARK: - Restore

    /// Start again, one at a time, the agent of each pane that waits in
    /// `agentResumePending`.
    func restoreAgentSessions(projectOrder: [UUID], files: AgentSessionFiles = AgentSessionFiles()) async {
        let pending = agentCandidatePanes(projectOrder: projectOrder).filter(\.agentResumePending)
        guard !pending.isEmpty else { return }
        guard Preferences.shared.agentAutoRestore else {
            if clearAgentResumes() { saveWorkspaces() }
            return
        }
        logger.info("agent restore: \(pending.count, privacy: .public) panes")
        for pane in pending {
            defer { pane.agentResumePending = false }
            guard Preferences.shared.agentAutoRestore, isPaneInWorkspaces(pane) else { continue }
            await restoreAgentSession(in: pane, files: files)
        }
        if captureAgentResumes(files: files) { saveWorkspaces() }
        logger.info("agent restore: done")
    }

    private func isPaneInWorkspaces(_ pane: Pane) -> Bool {
        workspaces[pane.projectID]?.tabs.contains { tab in tab.splitRoot.allPanes().contains { $0 === pane } } ?? false
    }

    private func restoreAgentSession(in pane: Pane, files: AgentSessionFiles) async {
        guard let resume = pane.agentResume else { return }
        let label = "\(resume.agent.rawValue) \(resume.sessionID) in \(pane.sessionName)"

        // The terminal of a tab that is not on screen does not exist yet.
        if SurfaceRegistry.shared.view(of: pane) == nil { warmPane(pane) }
        guard let pid = await waitForValue(timeout: 30, { ProcessInspector.resolvedForegroundPID(forPane: pane) }) else {
            logger.error("agent restore: \(label, privacy: .public): the pane has no foreground process")
            return
        }
        // The session survived: its agent still runs.
        if let argv = ProcessInspector.argv(pid: pid),
           AgentResume.agent(argv: argv, comm: ProcessInspector.comm(pid: pid)) == resume.agent
        {
            logger.info("agent restore: \(label, privacy: .public): already running")
            return
        }
        // Type only at an idle shell prompt, and only after the shell stayed
        // there for a moment (rc files, the replay of the scrollback).
        guard await waitUntil(timeout: 20, { ProcessInspector.foregroundProcessIsShell(forPane: pane) }) else {
            logger.info("agent restore: \(label, privacy: .public): the pane runs another program")
            return
        }
        try? await Task.sleep(for: .milliseconds(1500))
        guard ProcessInspector.foregroundProcessIsShell(forPane: pane) else {
            logger.info("agent restore: \(label, privacy: .public): the shell is not idle")
            return
        }
        if files.sessionIsRunning(resume) {
            logger.info("agent restore: \(label, privacy: .public): the session runs somewhere else")
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resume.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            logger.error("agent restore: \(label, privacy: .public): directory \(resume.directory, privacy: .public) is gone")
            return
        }
        await waitWhileMemoryIsCritical()
        guard let view = SurfaceRegistry.shared.view(of: pane), view.sendText(resume.shellCommand + "\n") else {
            logger.error("agent restore: \(label, privacy: .public): the terminal is not live")
            return
        }
        logger.info("agent restore: \(label, privacy: .public): started")
        // A large transcript takes minutes to load. A dialog of the agent (a
        // trust prompt) keeps it from ready; the timeout then moves on and
        // leaves the dialog to the user.
        let timeout: TimeInterval = resume.agent == .claude ? 600 : 300
        let ready = await waitUntil(timeout: timeout, interval: .seconds(1)) {
            Self.agentIsReady(in: pane, resume: resume, files: files)
        }
        if resume.agent == .qodercli, ready {
            // No status file: give the screen a moment after the session loads.
            try? await Task.sleep(for: .seconds(3))
        }
        logger.info("agent restore: \(label, privacy: .public): \(ready ? "ready" : "not ready in time", privacy: .public)")
    }

    /// Whether the resumed agent is ready for input.
    /// Claude Code: its session file says `idle`. Qoder CLI: its run has
    /// opened a segment file.
    private static func agentIsReady(in pane: Pane, resume: AgentResume, files: AgentSessionFiles) -> Bool {
        guard let pid = ProcessInspector.resolvedForegroundPID(forPane: pane),
              let argv = ProcessInspector.argv(pid: pid),
              AgentResume.agent(argv: argv, comm: ProcessInspector.comm(pid: pid)) == resume.agent
        else { return false }
        switch resume.agent {
        case .claude:
            return files.claudeSession(pid: pid)?.status == "idle"
        case .qodercli:
            return files.qoderSessionID(pid: pid) != nil
        }
    }

    // MARK: - Waits

    private func waitUntil(
        timeout: TimeInterval,
        interval: Duration = .milliseconds(500),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(for: interval)
        }
    }

    private func waitForValue<T>(timeout: TimeInterval, _ value: () -> T?) async -> T? {
        var result: T?
        _ = await waitUntil(timeout: timeout) {
            result = value()
            return result != nil
        }
        return result
    }

    /// Wait (at most two minutes) while the kernel reports critical memory
    /// pressure, so that the next resume does not push the Mac into swap.
    private func waitWhileMemoryIsCritical() async {
        let critical = await !waitUntil(timeout: 120, interval: .seconds(2)) { Self.memoryPressureLevel() < 4 }
        if critical { logger.info("agent restore: memory pressure stays critical, going on") }
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    static func memoryPressureLevel() -> Int32 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return level
    }
}

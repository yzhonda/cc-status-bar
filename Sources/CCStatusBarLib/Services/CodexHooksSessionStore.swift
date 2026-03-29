import Foundation

/// Session store for Codex hooks mode.
/// Maintains full CodexSession objects registered via hooks (SessionStart/Stop).
/// In hooks mode, this replaces CodexObserver's pgrep-based discovery.
@MainActor
final class CodexHooksSessionStore {
    static let shared = CodexHooksSessionStore()

    /// Active sessions keyed by "codex:<pid>"
    private(set) var activeSessions: [String: CodexSession] = [:]

    /// Interval for pruning dead processes (seconds)
    private let pruneInterval: TimeInterval = 30.0
    private var lastPruneTime: Date = .distantPast

    // MARK: - Session Management

    /// Register a new session from SessionStart hook event.
    /// Resolves TTY/tmux/terminal info via pgrep + lsof (one-time cost).
    func registerSession(cwd: String, sessionId: String?, model: String?) {
        // Find the Codex PID for this cwd
        guard let pid = CodexObserver.findPidForCwd(cwd) else {
            DebugLog.log("[CodexHooksSessionStore] Could not find PID for cwd: \(cwd)")
            return
        }

        var session = CodexSession(pid: pid, cwd: cwd, sessionId: sessionId)
        session.modelProvider = model

        // Resolve TTY and tmux info
        if let tty = CodexObserver.getTTYPublic(for: pid) {
            session.tty = tty
            if let paneInfo = TmuxHelper.getPaneInfo(for: tty) {
                session.tmuxSession = paneInfo.session
                session.tmuxWindow = paneInfo.window
                session.tmuxPane = paneInfo.pane
                session.tmuxSocketPath = paneInfo.socketPath

                if let terminalApp = TmuxHelper.getClientTerminalInfo(for: paneInfo.session) {
                    session.terminalApp = terminalApp
                }
            }
        }

        // Try extended session info from JSONL files
        if let extInfo = CodexObserver.findExtendedInfoPublic(for: cwd) {
            session.cliVersion = extInfo.cliVersion
            session.modelProvider = extInfo.modelProvider ?? model
            session.originator = extInfo.originator
            session.tokenUsage = extInfo.tokenUsage
            if session.sessionId == nil {
                session.sessionId = extInfo.sessionId
            }
        }

        let key = "codex:\(pid)"
        activeSessions[key] = session
        DebugLog.log("[CodexHooksSessionStore] Registered session: \(session.projectName) (PID \(pid))")
    }

    /// Remove a session by cwd
    func removeSession(cwd: String) {
        if let key = activeSessions.first(where: { $0.value.cwd == cwd })?.key {
            let session = activeSessions.removeValue(forKey: key)
            DebugLog.log("[CodexHooksSessionStore] Removed session: \(session?.projectName ?? cwd)")
        }
    }

    /// Get session for a specific cwd
    func getSession(for cwd: String) -> CodexSession? {
        activeSessions.values.first { $0.cwd == cwd }
    }

    /// Bootstrap: hydrate store from currently running Codex processes.
    /// Called once at app startup in hooks mode.
    func hydrateFromRunningProcesses() {
        let sessions = CodexObserver.fetchCodexSessionsPublic()
        for (key, session) in sessions {
            activeSessions[key] = session
        }
        DebugLog.log("[CodexHooksSessionStore] Hydrated \(sessions.count) sessions from running processes")
    }

    /// Prune sessions whose processes have died.
    /// Called periodically (every 30s).
    func pruneDeadProcesses(now: Date = Date()) {
        guard now.timeIntervalSince(lastPruneTime) >= pruneInterval else { return }
        lastPruneTime = now

        var removed: [String] = []
        for (key, session) in activeSessions {
            if !isProcessAlive(pid: session.pid) {
                activeSessions.removeValue(forKey: key)
                removed.append(session.projectName)
            }
        }

        if !removed.isEmpty {
            DebugLog.log("[CodexHooksSessionStore] Pruned dead processes: \(removed.joined(separator: ", "))")
        }
    }

    /// Clear all sessions
    func reset() {
        activeSessions.removeAll()
    }

    // MARK: - Private

    private func isProcessAlive(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}

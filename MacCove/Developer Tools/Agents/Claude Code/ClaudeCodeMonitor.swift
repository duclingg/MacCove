//
//  ClaudeCodeMonitor.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import AppKit

/// Claude Code sessions, as the island shows them: working, waiting for
/// you, then finished.
///
/// Claude Code runs the hook MacCove adds to ~/.claude/settings.json (see
/// `ClaudeCodeSetup`) for each event, which reaches `handle(_:)` through
/// `AgentBridge`. Most events only report. A permission request, a
/// question (AskUserQuestion) and a finished plan (ExitPlanMode) wait for
/// the island's answer, which goes back to Claude Code as the hook's.
@Observable
final class ClaudeCodeMonitor {
    enum Event {
        case started
        /// A permission request, question or plan is waiting on the island.
        case needsAnswer
        case answered
        case finished
        /// Dismissed, or its session ended.
        case ended
    }

    struct Approval: Equatable {
        let id = UUID()
        /// "Allow Bash command?"
        let title: String
        /// What it would run or change, a line or two.
        let detail: [String]
        /// A rule Claude Code suggests for not asking again, echoed back
        /// for Always Allow.
        let alwaysAllow: [String: Any]?

        static func == (lhs: Approval, rhs: Approval) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Claude's AskUserQuestion: one to four questions, each with a few
    /// options, answered one after another.
    struct Question: Equatable {
        struct Item {
            /// A short label: "Auth method".
            let header: String
            let question: String
            let options: [Option]
            let multiSelect: Bool
        }

        struct Option {
            let label: String
            let description: String
        }

        let id = UUID()
        let items: [Item]
        /// The tool's input, sent back with the answers.
        let input: [String: Any]
        /// The one being asked.
        var index = 0
        /// By question, the label chosen, or for a multiple choice the
        /// labels joined with commas, as Claude Code itself sends them.
        var answers: [String: String] = [:]
        /// Ticked so far in a multiple choice.
        var selected: Set<String> = []

        var current: Item { items[index] }

        static func == (lhs: Question, rhs: Question) -> Bool {
            lhs.id == rhs.id && lhs.index == rhs.index && lhs.selected == rhs.selected
        }
    }

    /// Claude's ExitPlanMode: the plan it wants to start on.
    struct Plan: Equatable {
        let id = UUID()
        /// Its first heading.
        let title: String
        /// The first of what follows the heading.
        let summary: String
        let filePath: String?
        /// The tool's input, sent back to approve it.
        let input: [String: Any]

        static func == (lhs: Plan, rhs: Plan) -> Bool {
            lhs.id == rhs.id
        }
    }

    enum Phase: Equatable {
        case working
        case approval(Approval)
        case question(Question)
        case plan(Plan)
        case finished

        /// What's waiting for an answer, `nil` when nothing is.
        var promptID: UUID? {
            switch self {
            case let .approval(approval): approval.id
            case let .question(question): question.id
            case let .plan(plan): plan.id
            case .working, .finished: nil
            }
        }
    }

    struct Session: Equatable, Identifiable {
        let id: String
        var folder: String
        /// The prompt that started this turn.
        var task: String
        /// What it's doing now: "Editing NotchWindowController.swift".
        var activity: String?
        /// From Claude's task list, when the model keeps one.
        var tasksDone = 0
        var taskCount = 0
        var toolUses = 0
        var editedFiles: Set<String> = []
        var startedAt: Date
        var finishedAt: Date?
        var phase: Phase
        /// The app the session's terminal runs in, its tty, and Claude
        /// Code's process.
        var appBundleIdentifier: String?
        var tty: String?
        var pid: pid_t?
        var updatedAt = Date.now
        /// Hidden once dismissed, until its next prompt.
        var isShown = true

        var project: String {
            (folder as NSString).lastPathComponent
        }

        var progress: Double? {
            taskCount > 0 ? Double(tasksDone) / Double(taskCount) : nil
        }
    }

    /// The session the island shows: one waiting for you first, then the
    /// one heard from last.
    var session: Session? {
        let shown = sessions.values.filter { $0.isShown }
        if let waiting = shown.filter({ $0.phase.promptID != nil }).min(by: { $0.updatedAt < $1.updatedAt }) {
            return waiting
        }
        return shown.max { $0.updatedAt < $1.updatedAt }
    }

    var needsAnswer: Bool {
        session?.phase.promptID != nil
    }

    @ObservationIgnored var onEvent: ((Event) -> Void)?

    private var sessions: [String: Session] = [:]
    /// Each waiting hook, by what it's asking.
    @ObservationIgnored private var pendingAnswers: [UUID: CheckedContinuation<AgentBridge.Response, Never>] = [:]
    @ObservationIgnored private var processCheck: Task<Void, Never>?
    @ObservationIgnored private var hooksRemovedObserver: NSObjectProtocol?

    init() {
        // Once the hooks are out, the sessions shown hear nothing more,
        // not even their SessionEnd, so they leave the island now.
        hooksRemovedObserver = NotificationCenter.default.addObserver(
            forName: .claudeCodeHooksRemoved,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endAll() }
        }
    }

    /// Just under the hook's 10 minutes, so Claude Code gets an answer,
    /// and asks in the terminal, rather than timing the hook out.
    private static let answerTimeout: Duration = .seconds(590)
    /// Asked through their own hook, which waits for the island.
    private static let toolsThatAsk: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
    private static let processCheckInterval: Duration = .seconds(5)

    // MARK: - Hook events

    func handle(_ request: AgentBridge.Request) async -> AgentBridge.Response {
        let event = (request.path as NSString).lastPathComponent
        guard let input = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let id = input["session_id"] as? String else { return .empty }
        let folder = input["cwd"] as? String ?? ""

        switch event {
        case "UserPromptSubmit":
            let prompt = (input["prompt"] as? String) ?? ""
            begin(id, folder: folder, task: Self.firstLine(prompt), request: request)
        case "PreToolUse":
            // Reported again, and waited on, as UserInput.
            guard !Self.toolsThatAsk.contains(input["tool_name"] as? String ?? "") else { break }
            update(id) { session in
                session.toolUses += 1
                session.activity = Self.describe(tool: input["tool_name"] as? String, input: input["tool_input"] as? [String: Any])
            }
        case "PostToolUse":
            update(id) { session in
                Self.record(tool: input["tool_name"] as? String, input: input["tool_input"] as? [String: Any], in: &session)
            }
        case "TaskCreated":
            update(id) { $0.taskCount += 1 }
        case "TaskCompleted":
            update(id) { $0.tasksDone = min($0.tasksDone + 1, $0.taskCount) }
        case "PermissionRequest":
            return await requestApproval(id, input: input, request: request)
        case "UserInput":
            return await requestInput(id, input: input, request: request)
        case "Notification":
            // A minute after the last reply with no Stop before it: the turn
            // was interrupted, which Stop doesn't report.
            if input["notification_type"] as? String == "idle_prompt", sessions[id]?.phase == .working {
                end(id)
            }
        case "Stop":
            finish(id)
        case "SessionEnd":
            end(id)
        default:
            break
        }
        return .empty
    }

    // MARK: - From the island

    func allow() {
        answer(Self.decision(behavior: "allow"))
    }

    /// Allows, and adds the rule Claude Code suggested so it doesn't ask
    /// again.
    func alwaysAllow() {
        guard case let .approval(approval)? = session?.phase, let rule = approval.alwaysAllow else {
            allow()
            return
        }
        answer(Self.decision(behavior: "allow", extra: ["updatedPermissions": [rule]]))
    }

    func deny() {
        answer(Self.decision(behavior: "deny", extra: ["message": "Denied from MacCove."]))
    }

    /// Picks an option. In a multiple choice it's ticked or unticked;
    /// otherwise it answers, and the next question comes up, or once
    /// they're all answered they go back to Claude.
    func choose(_ label: String) {
        guard case var .question(question)? = session?.phase else { return }
        if question.current.multiSelect {
            if question.selected.remove(label) == nil {
                question.selected.insert(label)
            }
            show(question)
        } else {
            answerCurrent(of: question, with: label)
        }
    }

    /// Answers a multiple choice with what's ticked, in the options' order.
    func submitChoices() {
        guard case let .question(question)? = session?.phase, !question.selected.isEmpty else { return }
        let labels = question.current.options.map(\.label).filter { question.selected.contains($0) }
        answerCurrent(of: question, with: labels.joined(separator: ", "))
    }

    /// Starts on the plan. Claude Code wants the plan echoed back.
    func approvePlan() {
        guard case let .plan(plan)? = session?.phase else { return }
        answer(Self.preToolUse(["permissionDecision": "allow", "updatedInput": plan.input]))
    }

    /// Turns the plan down, and Claude asks what to change.
    func keepPlanning() {
        answer(Self.preToolUse([
            "permissionDecision": "deny",
            "permissionDecisionReason": "The user chose to keep planning, from MacCove. Ask them what they'd like changed.",
        ]))
    }

    /// Opens the plan's file, which the island leaves waiting.
    func viewPlan() {
        guard case let .plan(plan)? = session?.phase, let path = plan.filePath else { return }
        NSWorkspace.shared.open(URL(filePath: path))
    }

    /// Leaves the island. It comes back with the session's next prompt.
    func dismiss() {
        guard let shown = session else { return }
        if let promptID = shown.phase.promptID {
            resolve(promptID, with: .empty)
        }
        sessions[shown.id]?.isShown = false
        onEvent?(.ended)
    }

    /// Brings its terminal forward. Something waiting goes there too, for
    /// Claude Code to ask itself.
    func openSession() {
        guard let shown = session else { return }
        TerminalWindow.bringForward(appBundleIdentifier: shown.appBundleIdentifier, tty: shown.tty)
        if shown.phase.promptID != nil {
            answer(.empty)
        } else if shown.phase == .finished {
            dismiss()
        }
    }

    /// Interrupts the turn with Esc in its terminal. Claude Code reports no
    /// Stop for that, so the session leaves the island here.
    func stop() {
        guard let shown = session, shown.phase == .working else { return }
        if TerminalWindow.pressEscape(appBundleIdentifier: shown.appBundleIdentifier, tty: shown.tty) {
            end(shown.id)
        }
    }

    // MARK: - Session changes

    private func begin(_ id: String, folder: String, task: String, request: AgentBridge.Request) {
        var session = sessions[id] ?? Session(id: id, folder: folder, task: task, startedAt: .now, phase: .working)
        // Interrupted while waiting, so it was never answered.
        if let promptID = session.phase.promptID {
            resolve(promptID, with: .empty)
        }
        session.folder = folder.isEmpty ? session.folder : folder
        session.task = task.isEmpty ? "Working" : task
        session.activity = nil
        session.tasksDone = 0
        session.taskCount = 0
        session.toolUses = 0
        session.editedFiles = []
        session.startedAt = .now
        session.finishedAt = nil
        session.phase = .working
        session.isShown = true
        session.updatedAt = .now
        Self.attach(request, to: &session)
        sessions[id] = session
        onEvent?(.started)
        watchProcesses()
    }

    /// Where the session runs, from what the hook script adds: the app its
    /// terminal is in, the terminal's tty and Claude Code's process.
    private static func attach(_ request: AgentBridge.Request, to session: inout Session) {
        let headers = request.headers
        if let app = headers["x-maccove-app"], !app.isEmpty {
            session.appBundleIdentifier = app
        }
        if let tty = headers["x-maccove-tty"], !tty.isEmpty, tty != "??" {
            session.tty = "/dev/" + tty
        }
        if let pid = headers["x-maccove-pid"].flatMap({ pid_t($0) }) {
            session.pid = pid
        }
    }

    /// Anything Claude does next means what was waiting was answered in
    /// the terminal instead.
    private func update(_ id: String, _ change: (inout Session) -> Void) {
        guard var session = sessions[id], session.isShown else { return }
        if let promptID = session.phase.promptID {
            session.phase = .working
            sessions[id] = session
            resolve(promptID, with: .empty)
            onEvent?(.answered)
        }
        change(&session)
        session.updatedAt = .now
        sessions[id] = session
    }

    private func finish(_ id: String) {
        guard var session = sessions[id], session.isShown else { return }
        if let promptID = session.phase.promptID {
            resolve(promptID, with: .empty)
        }
        session.phase = .finished
        session.finishedAt = .now
        session.updatedAt = .now
        sessions[id] = session
        onEvent?(.finished)
    }

    /// Every session, as if each had ended. Anything waiting goes back to
    /// Claude Code unanswered, so it asks in the terminal.
    private func endAll() {
        for id in sessions.keys {
            end(id)
        }
    }

    private func end(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if let promptID = session.phase.promptID {
            resolve(promptID, with: .empty)
        }
        onEvent?(.ended)
    }

    // MARK: - Waiting for you

    /// Shows the request and waits for the island's answer. Questions and
    /// plans come through their own hook and are asked there, not here.
    private func requestApproval(_ id: String, input: [String: Any], request: AgentBridge.Request) async -> AgentBridge.Response {
        let tool = input["tool_name"] as? String ?? "Tool"
        guard !Self.toolsThatAsk.contains(tool) else { return .empty }
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        let suggestions = input["permission_suggestions"] as? [[String: Any]] ?? []
        let approval = Approval(
            title: Self.approvalTitle(tool: tool, input: toolInput),
            detail: Self.approvalDetail(tool: tool, input: toolInput),
            alwaysAllow: suggestions.first { $0["type"] as? String == "addRules" && $0["behavior"] as? String == "allow" }
        )
        return await waitForAnswer(.approval(approval), in: id, input: input, request: request)
    }

    /// A question or a plan, from the PreToolUse that waits. Anything it
    /// can't show goes on to Claude Code to ask in the terminal.
    private func requestInput(_ id: String, input: [String: Any], request: AgentBridge.Request) async -> AgentBridge.Response {
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        switch input["tool_name"] as? String {
        case "AskUserQuestion":
            guard let question = Self.question(from: toolInput) else { return .empty }
            return await waitForAnswer(.question(question), in: id, input: input, request: request)
        case "ExitPlanMode":
            return await waitForAnswer(.plan(Self.plan(from: toolInput)), in: id, input: input, request: request)
        default:
            return .empty
        }
    }

    /// A session the island isn't showing yet (one started before MacCove)
    /// appears for it.
    private func waitForAnswer(_ phase: Phase, in id: String, input: [String: Any], request: AgentBridge.Request) async -> AgentBridge.Response {
        guard let promptID = phase.promptID else { return .empty }
        var session = sessions[id] ?? Session(id: id, folder: input["cwd"] as? String ?? "", task: "Working", startedAt: .now, phase: .working)
        Self.attach(request, to: &session)
        sessions[id] = session
        watchProcesses()

        return await withCheckedContinuation { continuation in
            pendingAnswers[promptID] = continuation
            sessions[id]?.phase = phase
            sessions[id]?.isShown = true
            sessions[id]?.updatedAt = .now
            onEvent?(.needsAnswer)

            Task { [weak self] in
                try? await Task.sleep(for: Self.answerTimeout)
                self?.expire(promptID, in: id)
            }
        }
    }

    /// The next question, or the answers once there are no more.
    private func answerCurrent(of question: Question, with answer: String) {
        var question = question
        question.answers[question.current.question] = answer
        question.selected = []
        guard question.index + 1 < question.items.count else {
            var input = question.input
            input["answers"] = question.answers
            self.answer(Self.preToolUse(["permissionDecision": "allow", "updatedInput": input]))
            return
        }
        question.index += 1
        show(question)
    }

    private func show(_ question: Question) {
        guard let shown = session, shown.phase.promptID == question.id else { return }
        sessions[shown.id]?.phase = .question(question)
    }

    private func answer(_ response: AgentBridge.Response) {
        guard let shown = session, let promptID = shown.phase.promptID else { return }
        sessions[shown.id]?.phase = .working
        sessions[shown.id]?.updatedAt = .now
        resolve(promptID, with: response)
        onEvent?(.answered)
    }

    /// Unanswered for too long: Claude Code asks in the terminal instead.
    private func expire(_ promptID: UUID, in id: String) {
        guard pendingAnswers[promptID] != nil else { return }
        if sessions[id]?.phase.promptID == promptID {
            sessions[id]?.phase = .working
            onEvent?(.answered)
        }
        resolve(promptID, with: .empty)
    }

    private func resolve(_ promptID: UUID, with response: AgentBridge.Response) {
        pendingAnswers.removeValue(forKey: promptID)?.resume(returning: response)
    }

    private static func decision(behavior: String, extra: [String: Any] = [:]) -> AgentBridge.Response {
        var decision: [String: Any] = ["behavior": behavior]
        decision.merge(extra) { _, new in new }
        return .json(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
    }

    private static func preToolUse(_ output: [String: Any]) -> AgentBridge.Response {
        var output = output
        output["hookEventName"] = "PreToolUse"
        return .json(["hookSpecificOutput": output])
    }

    /// A session whose Claude Code has quit, with its terminal, leaves.
    private func watchProcesses() {
        guard processCheck == nil else { return }
        processCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.processCheckInterval)
                guard let self, !self.sessions.isEmpty else { break }
                for (id, session) in self.sessions {
                    guard let pid = session.pid, kill(pid, 0) != 0, errno == ESRCH else { continue }
                    self.end(id)
                }
            }
            self?.processCheck = nil
        }
    }

    // MARK: - Describing what Claude does

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(119)) + "…" : trimmed
    }

    private static func fileName(_ input: [String: Any]?) -> String? {
        (input?["file_path"] as? String ?? input?["notebook_path"] as? String).map { ($0 as NSString).lastPathComponent }
    }

    /// "Editing IslandView.swift", "Running swift test", or the tool's name.
    static func describe(tool: String?, input: [String: Any]?) -> String? {
        guard let tool else { return nil }
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return fileName(input).map { "Editing \($0)" } ?? "Editing"
        case "Read":
            return fileName(input).map { "Reading \($0)" } ?? "Reading"
        case "Bash":
            if let description = input?["description"] as? String, !description.isEmpty { return description }
            return (input?["command"] as? String).map { "Running " + firstLine($0) } ?? "Running a command"
        case "Grep", "Glob":
            return "Searching"
        case "WebFetch", "WebSearch":
            return "Searching the web"
        case "Task", "Agent":
            return "Working with a subagent"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet":
            return nil
        default:
            return tool.hasPrefix("mcp__") ? "Using \(tool.split(separator: "__").dropFirst().first ?? "a tool")" : "Using \(tool)"
        }
    }

    /// Files it changed, and the task list when the model keeps it with
    /// TodoWrite rather than the task tools.
    private static func record(tool: String?, input: [String: Any]?, in session: inout Session) {
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            if let path = input?["file_path"] as? String ?? input?["notebook_path"] as? String {
                session.editedFiles.insert(path)
            }
        case "TodoWrite":
            let todos = input?["todos"] as? [[String: Any]] ?? []
            session.taskCount = todos.count
            session.tasksDone = todos.filter { $0["status"] as? String == "completed" }.count
            if let current = todos.first(where: { $0["status"] as? String == "in_progress" }),
               let doing = current["activeForm"] as? String ?? current["content"] as? String {
                session.activity = doing
            }
        default:
            break
        }
    }

    /// `nil` when there's nothing to ask, or an option without a label.
    static func question(from input: [String: Any]) -> Question? {
        let items = (input["questions"] as? [[String: Any]] ?? []).compactMap { item -> Question.Item? in
            guard let text = item["question"] as? String else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> Question.Option? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return Question.Option(label: label, description: option["description"] as? String ?? "")
            }
            guard !options.isEmpty else { return nil }
            return Question.Item(
                header: item["header"] as? String ?? "",
                question: text,
                options: options,
                multiSelect: item["multiSelect"] as? Bool ?? false
            )
        }
        guard !items.isEmpty else { return nil }
        return Question(items: items, input: input)
    }

    /// Claude Code adds the plan file's text to the tool's input.
    static func plan(from input: [String: Any]) -> Plan {
        let lines = (input["plan"] as? String ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let heading = lines.first { $0.hasPrefix("#") }
        let title = heading?.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) ?? ""
        let summary = lines.filter { !$0.hasPrefix("#") }
            .prefix(4)
            .map { $0.replacing(/^([-*]|\d+\.)\s+/, with: "") }
            .joined(separator: " ")
        return Plan(
            title: title.isEmpty ? "Plan ready" : title,
            summary: summary,
            filePath: input["planFilePath"] as? String,
            input: input
        )
    }

    static func approvalTitle(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash": "Allow Bash command?"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "Allow edit to \(fileName(input) ?? "a file")?"
        case "Read": "Allow reading \(fileName(input) ?? "a file")?"
        case "WebFetch": "Allow fetching a page?"
        default:
            tool.hasPrefix("mcp__")
                ? "Allow \(tool.split(separator: "__").last.map(String.init) ?? tool)?"
                : "Allow \(tool)?"
        }
    }

    /// The command, the file or the address, as Claude Code's own prompt
    /// shows it.
    static func approvalDetail(tool: String, input: [String: Any]) -> [String] {
        if let command = input["command"] as? String {
            return ["$ " + command.replacingOccurrences(of: "\n", with: " ")]
        }
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String {
            return [(path as NSString).abbreviatingWithTildeInPath]
        }
        if let url = input["url"] as? String {
            return [url]
        }
        return []
    }
}

#if DEBUG
extension ClaudeCodeMonitor {
    /// A session that stays as given, for SwiftUI previews.
    static func preview(_ session: Session) -> ClaudeCodeMonitor {
        let monitor = ClaudeCodeMonitor()
        monitor.sessions[session.id] = session
        return monitor
    }
}
#endif

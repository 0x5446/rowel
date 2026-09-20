/// What this conversation has cost, and what the agent is allowed to do.
///
/// Every number here was already arriving in the projections the app folds; it
/// was being thrown away. That matters for what this screen is allowed to be:
/// nothing on it costs a request, so it can be opened at any time, including
/// while the machine is unreachable, and it will show the last thing it knew
/// rather than a spinner.
///
/// It answers the two questions the transcript cannot. *Is it stuck* — turns,
/// steps, and time to first token say more than a scroll position. *Is this
/// getting expensive* — the context bar and the token counts.
///
/// The access mode lives here too, and it is the one control on the screen. It
/// is deliberately last, because it is the setting that decides what the agent
/// may do to the files on the other end of the connection. That one does need
/// the machine — everything else on this screen is the last thing it said.

import SwiftUI

struct SessionInfoView: View {
    @Environment(MachineSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    /// Whether the full-access confirmation is up. A flag rather than the preset
    /// it is about, because the dialog that asks is only ever about one of them
    /// — and because the binding is cleared as the sheet dismisses, so a value
    /// read from state inside the button's action is a value that may already be
    /// gone.
    @State private var confirmingFullAccess = false
    /// The preset being sent right now, so the row can say it is working rather
    /// than looking like a tap that missed.
    @State private var switching: String?
    @State private var accessError: String?

    // `conversation(_:)` rather than a dictionary read: the sheet can be
    // opened on a session whose history has not been fetched, and this is
    // the accessor that starts that fetch.
    private var conversation: Conversation? { session.conversation(sessionId) }
    private var summary: SessionSummary? { session.sessions.first { $0.id == sessionId } }

    var body: some View {
        NavigationStack {
            List {
                context
                work
                spend
                access
            }
            .task { await session.loadPresets() }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Give this conversation full access?",
                isPresented: $confirmingFullAccess,
                titleVisibility: .visible
            ) {
                Button("Turn on full access", role: .destructive) {
                    send("danger-full-access")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("No sandbox and no approval prompts for this conversation: everything your account can do on that Mac, it can do without asking. Only do this if you trust what it has been asked to run.")
            }
        }
    }

    // MARK: - Context

    @ViewBuilder
    private var context: some View {
        if let fraction = conversation?.contextFraction {
            Section {
                VStack(alignment: .leading, spacing: Metrics.tight) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Int((fraction * 100).rounded()))% full")
                            .font(.system(size: 22, weight: .semibold))
                        Spacer()
                        if let used = conversation?.contextTokens, let window = conversation?.contextWindow {
                            Text("\(Format.tokens(used)) / \(Format.tokens(window))")
                                .font(.code(12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ContextBar(fraction: fraction, breakdown: conversation?.contextBreakdown)
                    if let parts = conversation?.contextBreakdown, parts.total > 0 {
                        HStack(spacing: Metrics.gap) {
                            Legend(color: Palette.accent.opacity(0.35), label: "System", value: parts.system)
                            Legend(color: Palette.accent.opacity(0.6), label: "Tools", value: parts.tools)
                            Legend(color: Palette.accent, label: "Messages", value: parts.messages)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Context")
            } footer: {
                // The number people actually need is "how long until it
                // compacts", and saying which part is large is the only
                // actionable version of it: tools and system are fixed costs,
                // messages are the part a new conversation resets.
                Text(fraction > 0.8
                    ? "Nearly full. The agent will start compacting older messages, which loses detail. A fresh conversation keeps the system and tool cost but drops the message history."
                    : "System prompt and tool schemas are paid once per turn and do not shrink. Only the message history grows.")
            }
        }
    }

    // MARK: - Work

    @ViewBuilder
    private var work: some View {
        if let stats = conversation?.stats {
            Section("Work") {
                // Which agent this conversation runs as. Stated rather than
                // offered: the app never established a way to switch it, and a
                // row that looks like a control is worse than a fact.
                if let preset = summary?.agentPreset {
                    Row("Agent", session.presets.first { $0.id == preset }?.name ?? preset)
                }
                Row("Turns", "\(stats.turns)")
                Row("Steps", "\(stats.steps)")
                Row("Thinking", Format.duration(ms: stats.llmMs))
                if stats.toolMs > 0 {
                    Row("Running tools", Format.duration(ms: stats.toolMs))
                }
                if let ttft = stats.averageTtftMs {
                    Row("First token", "\(Format.duration(ms: ttft)) average")
                }
                if let rate = stats.tokensPerSecond, rate > 0 {
                    Row("Output speed", "\(Int(rate.rounded())) tok/s")
                }
            }
        }
    }

    // MARK: - Spend

    @ViewBuilder
    private var spend: some View {
        if let tokens = conversation?.tokens {
            Section {
                // Broken out rather than summed, because the three kinds of
                // input are not the same price. Cache reads are typically
                // around a tenth of fresh input and cache writes rather more
                // than it, so a single "sent" figure hides the one number that
                // decides what a long conversation costs.
                Row("Fresh input", Format.tokens(tokens.uncachedInput))
                if tokens.cacheWrite > 0 {
                    Row("Written to cache", Format.tokens(tokens.cacheWrite))
                }
                Row("Read from cache", Format.tokens(tokens.cacheRead))
                Row("Output", Format.tokens(tokens.output))
                if let hit = tokens.cacheHitRate {
                    Row("Cache hit rate", "\(Int((hit * 100).rounded()))%")
                }
            } header: {
                Text("Tokens")
            } footer: {
                Text(cacheFootnote(tokens))
            }
        }
    }

    // MARK: - Access

    /// What this conversation is allowed to touch, and the control that changes
    /// it.
    ///
    /// This section has been wrong twice, in opposite directions, so the finding
    /// is worth writing down properly. It began as a three-way picker that did
    /// nothing: tapping an option changed nothing on screen and the person
    /// reported it as a dead control. It then became a read-only badge with a
    /// note saying a session's mode is fixed at creation, and that note was the
    /// mistake. The measurement behind it was real but too narrow — after
    /// changing the machine default to `read-only` and running another turn, an
    /// existing session's `permissions` projection still read `workspace-write`
    /// — because the only write this app had was
    /// `settings.update {ns: permission, patch: {defaultPreset}}`, and
    /// `defaultPreset` is exactly what its name says: the mode *new*
    /// conversations start in. Nothing about a running session is fixed.
    ///
    /// The mode of a conversation is changed by the machine's `/permission`
    /// command, which appends `permission/preset` — and the sandbox and approval
    /// knobs that preset bundles — to **that session's own log**. So it is per
    /// session, it applies as the session runs, and the projection moves. That
    /// last part is what makes a picker honest here: the checkmark follows the
    /// machine, so it cannot claim a mode this conversation is not running
    /// under, which for this particular setting is the failure that matters.
    @ViewBuilder
    private var access: some View {
        if let permissions = conversation?.permissions {
            Section {
                ForEach(permissions.choices) { option in
                    row(option, current: permissions.current)
                }
                // A session composed outside the presets has a mode with no name
                // to check and nothing to switch to, so it is stated instead.
                if permissions.current == "custom" {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(PermissionChoice.label(for: "custom"))
                            .font(.system(size: 15, weight: .semibold))
                        Text(PermissionChoice.detail(for: "custom"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
                if let accessError {
                    Text(accessError)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.warn)
                }
            } header: {
                Text("Access")
            } footer: {
                Text("Applies to this conversation only — every other one keeps the mode it is running under. Settings ▸ New conversations sets what the next conversation starts in.")
            }
        }
    }

    /// One preset, as a row that can be chosen.
    private func row(_ option: PermissionChoice.Option, current: String) -> some View {
        Button {
            guard option.value != current else { return }
            accessError = nil
            // The one that removes the guard rails gets asked about first; the
            // two that tighten them do not.
            if option.value == "danger-full-access" {
                confirmingFullAccess = true
            } else {
                send(option.value)
            }
        } label: {
            HStack(alignment: .top, spacing: Metrics.gap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PermissionChoice.label(for: option.value))
                        .font(.system(size: 15, weight: .medium))
                    Text(PermissionChoice.detail(for: option.value))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Metrics.gap)
                if switching == option.value {
                    ProgressView().controlSize(.small)
                } else if option.value == current {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .foregroundStyle(.primary)
        .disabled(switching != nil)
        .accessibilityIdentifier("access.\(option.value)")
        // The checkmark is a picture, and a picture is not a state. Whoever is
        // not reading the screen — VoiceOver, or the UI test in
        // `RowelUITests/AccessMode.swift` — needs the current row to say so.
        .accessibilityAddTraits(option.value == current ? .isSelected : [])
    }

    /// Ask the machine to switch this conversation, and say so if it refuses.
    ///
    /// The badge is not moved here. The machine's answer is the projection, and
    /// it arrives within a round trip; a checkmark placed by this screen could
    /// survive a refusal that never got that far.
    private func send(_ preset: String) {
        confirmingFullAccess = false
        switching = preset
        Task {
            let failure = await session.setSessionPermission(sessionId: sessionId, preset: preset)
            switching = nil
            accessError = failure
        }
    }

    /// Say what the cache numbers mean for this particular conversation, since
    /// the same three figures read very differently at 5% and at 95%.
    private func cacheFootnote(_ tokens: TokenUsage) -> String {
        guard let hit = tokens.cacheHitRate else {
            return "Nothing has been sent yet."
        }
        if hit > 0.6 {
            return "Most of the input is being re-read from cache, which is charged at a fraction of fresh input. This is why a long conversation stays affordable."
        }
        if tokens.totalInput < 5_000 {
            return "Too early to say much — the cache warms up over the first few turns."
        }
        // A low rate late in a conversation usually means something keeps
        // changing near the front of the prompt, which invalidates everything
        // after it.
        return "A low hit rate this far in usually means something near the start of the prompt keeps changing, which throws away the cache behind it."
    }
}

// MARK: - Pieces

/// The context window as a bar, split by what is filling it.
private struct ContextBar: View {
    let fraction: Double
    let breakdown: ContextBreakdown?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.well)
                HStack(spacing: 1) {
                    if let parts = breakdown, parts.total > 0 {
                        // Widths are the *share of the window*, not of the
                        // breakdown, so the bar's total length still reads as
                        // the fill percentage.
                        segment(width, parts.system, parts.total, Palette.accent.opacity(0.35))
                        segment(width, parts.tools, parts.total, Palette.accent.opacity(0.6))
                        segment(width, parts.messages, parts.total, Palette.accent)
                    } else {
                        Capsule()
                            .fill(Palette.accent)
                            .frame(width: max(2, width * fraction))
                    }
                }
            }
        }
        .frame(height: 8)
    }

    private func segment(_ width: CGFloat, _ part: Int, _ total: Int, _ color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: max(0, width * fraction * (Double(part) / Double(total))))
    }
}

private struct Legend: View {
    let color: Color
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(Format.tokens(value))
                .font(.code(11))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct Row: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer(minLength: Metrics.gap)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }
}

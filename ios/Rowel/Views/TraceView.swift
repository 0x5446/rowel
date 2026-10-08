/// The whole conversation as one line per event.
///
/// A transcript is for reading; this is for finding. After twenty minutes of
/// work the transcript is several thousand words of rendered markdown, diffs,
/// and command output, and the question someone actually has on a phone is one
/// of three: *what has it been doing*, *where did it go wrong*, and *where was
/// that one command*. None of those survive scrolling.
///
/// Nothing here is fetched. It reads the same `conversation.items` the
/// transcript does, so it opens instantly, works offline, and cannot disagree
/// with the screen behind it. Tapping a row takes the transcript to that item —
/// finding something and then having to hunt for it again would be the whole
/// point missed.

import SwiftUI

struct TraceView: View {
    let conversation: Conversation
    /// Called with the item to scroll to, after this sheet closes.
    let onJump: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var lens: Lens = .everything

    /// What to keep. Deliberately not the web UI's Duration/Turns/Calls, which
    /// are analysis axes for a wide screen. On a phone the useful cuts follow
    /// the three questions: what did it say, what did it do, what broke.
    enum Lens: String, CaseIterable, Identifiable {
        case everything = "All"
        /// What was said, both directions — no reasoning, no injected context.
        /// This is the "catch me up" view after being away.
        case talk = "Talk"
        case tools = "Tools"
        case failures = "Problems"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    Placeholder(
                        icon: query.isEmpty ? "clock" : "magnifyingglass",
                        title: query.isEmpty ? "Nothing yet" : "No matches",
                        detail: query.isEmpty
                            ? "Steps appear here as the agent works."
                            : "Nothing in this conversation matches “\(query)”."
                    )
                } else {
                    List(rows) { row in
                        Button {
                            // Dismiss first: scrolling the view underneath while
                            // a sheet is still covering it lands on the wrong
                            // offset once the sheet animates away.
                            dismiss()
                            onJump(row.transcriptId)
                        } label: {
                            TraceRow(row: row)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: Metrics.gutter, bottom: 6, trailing: Metrics.gutter))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Trace")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Find a command, file, or message")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("Show", selection: $lens) {
                        ForEach(Lens.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("trace.list")
        }
    }

    private var rows: [TraceEntry] {
        let all = TraceEntry.timed(conversation.items.flatMap(TraceEntry.entries(for:)))
        let lensed: [TraceEntry]
        switch lens {
        case .everything: lensed = all
        case .talk: lensed = all.filter { $0.kind == .user || $0.kind == .reply }
        case .tools: lensed = all.filter { $0.kind == .tool }
        case .failures: lensed = all.filter { $0.failed }
        }
        guard !query.isEmpty else { return lensed }
        let needle = query.lowercased()
        return lensed.filter { $0.searchText.lowercased().contains(needle) }
    }
}

/// One line of the trace.
///
/// A conversation item is not one step. An assistant turn carries *both* the
/// model's reasoning and what it then said, and dsh shows those as two separate
/// things — a collapsed `Think` and the reply under it. Folding them into one
/// row labelled "Reply" loses the reasoning entirely whenever there is also
/// text, and mislabels it as a reply whenever there is not. So one item can
/// produce more than one entry.
struct TraceEntry: Identifiable, Equatable {
    /// What kind of step this is. These are the distinctions dsh itself draws;
    /// collapsing any of them makes the list less scannable, not simpler.
    enum Kind: String, Equatable {
        /// Something the person typed.
        case user
        /// Input the harness injected — a skill catalogue, an AGENTS.md, a
        /// file-change notice. Real model input that nobody wrote, and a large
        /// part of where the context window went.
        case context
        /// The model reasoning before it acts.
        case thinking
        /// What the model actually said.
        case reply
        case tool
        case notice
    }

    let id: String
    let kind: Kind
    let icon: String
    let label: String
    let detail: String
    let at: Date
    let failed: Bool
    let running: Bool
    /// `turn.step` for model output, so a long run can be navigated by number
    /// the way dsh's own trace numbers its rows. Nil for everything else.
    let step: String?
    /// How long this step took.
    ///
    /// Measured for tools, which have both a call and a result timestamp.
    /// **Inferred** for everything else, from the gap to the next step — the
    /// event log carries no duration field, so there is nothing better, and a
    /// sequential agent loop makes the gap a fair proxy. It stops being one
    /// when tool calls run in parallel, which is why only the measured kind is
    /// ever shown on a tool row.
    var took: TimeInterval?

    var searchText: String { "\(label) \(detail)" }

    /// Flatten one transcript item into the steps it actually represents.
    static func entries(for item: ConversationItem) -> [TraceEntry] {
        switch item {
        case .user(let turn):
            return [TraceEntry(
                id: turn.id,
                kind: turn.synthetic ? .context : .user,
                icon: turn.synthetic ? "arrow.down.doc" : "person",
                label: turn.synthetic ? "Context" : "You",
                detail: oneLine(turn.text),
                at: turn.at,
                failed: false,
                running: false,
                step: nil
            ,
                took: nil
            )]

        case .assistant(let turn):
            let number = "\(turn.turn).\(turn.step)"
            var made: [TraceEntry] = []
            // Reasoning first, because that is the order it happened in and the
            // order dsh draws it.
            if !turn.reasoning.isEmpty {
                made.append(TraceEntry(
                    id: "\(turn.id)#think",
                    kind: .thinking,
                    icon: "brain",
                    label: "Thinking",
                    detail: oneLine(turn.reasoning),
                    at: turn.at,
                    failed: false,
                    // Only the tail of a step is still streaming. Marking the
                    // reasoning as running once text has started would put a
                    // spinner on something already finished.
                    running: !turn.complete && turn.text.isEmpty,
                    step: number
                ,
                    took: nil
                ))
            }
            if !turn.text.isEmpty {
                made.append(TraceEntry(
                    id: turn.id,
                    kind: .reply,
                    icon: "text.alignleft",
                    label: "Reply",
                    detail: oneLine(turn.text),
                    at: turn.at,
                    failed: false,
                    running: !turn.complete,
                    step: number
                ,
                    took: nil
                ))
            }
            // A step that produced only a tool call has neither, and dsh labels
            // exactly that case rather than leaving a gap.
            return made

        case .tool(let card):
            return [TraceEntry(
                id: card.id,
                kind: .tool,
                icon: icon(for: card.presentation),
                label: card.name,
                detail: oneLine(card.headline),
                at: card.at,
                failed: card.failed,
                running: card.running,
                step: nil,
                took: card.duration
            )]

        case .notice(let notice):
            return [TraceEntry(
                id: notice.id,
                kind: .notice,
                icon: notice.kind == .failure ? "exclamationmark.triangle" : "info.circle",
                label: notice.kind == .failure ? "Error" : "Note",
                detail: oneLine(notice.text),
                at: notice.at,
                failed: notice.kind == .failure,
                running: false,
                step: nil
            ,
                took: nil
            )]
        }
    }

    /// Fill in the inferred durations, once the neighbours are known.
    ///
    /// A separate pass rather than something the initialiser could do: how long
    /// a step took is a property of the sequence, not of the step.
    static func timed(_ entries: [TraceEntry]) -> [TraceEntry] {
        var out = entries
        for index in out.indices where out[index].took == nil {
            // A row that is still running has no end yet, and guessing one from
            // the next row would be inventing an end for something unfinished.
            guard !out[index].running, index + 1 < out.count else { continue }
            let gap = out[index + 1].at.timeIntervalSince(out[index].at)
            // Sub-second gaps are noise on a phone row, and a negative one means
            // two events shared a timestamp or arrived out of order.
            out[index].took = gap >= 1 ? gap : nil
        }
        return out
    }

    /// The transcript item a row should scroll to. Reasoning and reply share
    /// one bubble down there, so the `#think` suffix has to come off.
    var transcriptId: String {
        id.hasSuffix("#think") ? String(id.dropLast("#think".count)) : id
    }

    /// Collapse to something that fits one row: no newlines, no runs of spaces.
    static func oneLine(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let squeezed = flattened.split(separator: " ").joined(separator: " ")
        return squeezed.count > 200 ? String(squeezed.prefix(200)) + "…" : squeezed
    }

    static func icon(for presentation: ToolPresentation) -> String {
        switch presentation {
        case .terminal: return "terminal"
        case .diff: return "plusminus"
        case .search: return "magnifyingglass"
        case .read: return "doc.text"
        case .question: return "questionmark.bubble"
        case .generic: return "wrench.and.screwdriver"
        }
    }
}

private struct TraceRow: View {
    let row: TraceEntry

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.tight) {
            Image(systemName: row.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(row.failed ? Palette.bad : .primary)
                    if let step = row.step {
                        // dsh numbers its own trace rows; the number is how you
                        // say "the one at 3.2" to yourself while scrolling.
                        Text(step)
                            .font(.code(10))
                            .foregroundStyle(.tertiary)
                    }
                    if row.running {
                        Text("running")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Metrics.tight)
                    if let took = row.took {
                        // The number people scan for. A 40-second command is the
                        // answer to "why is this taking so long", and it is
                        // invisible in the transcript.
                        Text(Format.duration(ms: Int(took * 1000)))
                            .font(.code(10))
                            .foregroundStyle(took >= 10 ? AnyShapeStyle(Palette.warn) : AnyShapeStyle(.tertiary))
                    }
                    Text(row.at, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(row.kind == .tool ? .code(12) : .system(size: 12.5))
                        // Reasoning and injected context are the bulk of a long
                        // run and the least of what anyone is looking for, so
                        // they are present but recede.
                        .foregroundStyle(row.kind == .thinking || row.kind == .context ? .tertiary : .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// One colour per kind, so the shape of a run is readable before any of it
    /// is. A wall of orange is a session that spent its time in the shell; a
    /// wall of grey is one that spent it thinking.
    private var tint: Color {
        if row.failed { return Palette.bad }
        switch row.kind {
        case .tool: return Palette.accent
        case .reply: return Palette.good
        case .user: return .primary
        case .thinking: return .init(uiColor: .tertiaryLabel)
        case .context: return .init(uiColor: .quaternaryLabel)
        case .notice: return Palette.warn
        }
    }
}

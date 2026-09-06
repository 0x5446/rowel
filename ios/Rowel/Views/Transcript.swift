/// The message renderers.
///
/// Three shapes: what the person said, what the agent said, and everything else.
/// The asymmetry is on purpose — a user turn is short and gets a bubble, an
/// assistant turn is long and gets the full width, because a phone-width bubble
/// with a 600-word answer in it wastes a third of the screen on margin.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TranscriptItem: View {
    let item: ConversationItem

    var body: some View {
        switch item {
        case .user(let turn): UserBubble(turn: turn)
        case .assistant(let turn): AssistantBlock(turn: turn)
        case .tool(let card): ToolCardView(card: card)
        case .notice(let notice): NoticeRow(notice: notice)
        }
    }
}

// MARK: - User

struct UserBubble: View {
    let turn: UserTurn
    @State private var expanded = false

    var body: some View {
        if turn.synthetic {
            synthetic
        } else {
            // `maxWidth: .infinity` is load-bearing, not decoration. The parent
            // is a `LazyVStack(alignment: .leading)`, which lays a child out at
            // its *ideal* width — and the ideal width of [Spacer, Text] is the
            // whole unwrapped line. Without this the bubble runs off the right
            // edge of the screen and the end of the message is simply gone,
            // which is what happened to every message longer than one line.
            HStack {
                Spacer(minLength: 44)
                VStack(alignment: .trailing, spacing: 6) {
                    if !turn.images.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(turn.images) { image in
                                AttachmentThumb(image: image)
                            }
                        }
                    }
                    if !turn.text.isEmpty {
                        Text(turn.text)
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .padding(.horizontal, Metrics.gap)
                            .padding(.vertical, 9)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Context the harness injected: a changed file, a skill body, an AGENTS.md.
    /// It is genuinely part of the conversation, so hiding it would misrepresent
    /// what the model saw, but it did not come from the person and must not look
    /// like it did.
    private var synthetic: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.down.left.circle")
                    .font(.system(size: 11))
                Text(turn.text)
                    .font(.system(size: 12))
                    .lineLimit(expanded ? nil : 1)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Metrics.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AttachmentThumb: View {
    let image: ImageAttachment

    /// Absent in the composer, where the photo is in hand and has no id yet.
    @Environment(AttachmentLoader.self) private var loader: AttachmentLoader?

    /// The side of the square, in points. Also what the loader downsamples to.
    private static let side: CGFloat = 56

    var body: some View {
        Group {
            if let uiImage = inline ?? loader?.thumbnail(image.id) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.side, height: Self.side)
        // Distinguishable from the placeholder to anything reading the screen —
        // VoiceOver included, which otherwise announces both states as the same
        // unnamed image.
        .accessibilityIdentifier((inline ?? loader?.thumbnail(image.id)) == nil
                                 ? "attachment.placeholder" : "attachment.loaded")
        .background(Palette.well)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
        .task(id: image.id) {
            // Only a message read back from the log needs fetching; one the
            // person just attached is already here.
            guard image.base64 == nil else { return }
            await loader?.load(image.id, side: Self.side)
        }
    }

    /// The photo the composer is holding, decoded from what it already has.
    private var inline: UIImage? {
        guard let base64 = image.base64, let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Assistant

struct AssistantBlock: View {
    let turn: AssistantTurn
    @State private var showReasoning = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            if !turn.reasoning.isEmpty {
                reasoning
            }
            if !turn.text.isEmpty {
                MarkdownText(source: turn.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !turn.complete && turn.reasoning.isEmpty {
                Thinking()
            }
        }
    }

    /// Reasoning, collapsed. It is worth having — it is often where the answer to
    /// "why did it do that" lives — and it is never worth showing by default,
    /// because it is longer than the answer and less useful.
    ///
    /// While it is still arriving there is a third state between "hidden" and
    /// "expanded": one line of the newest text, updating in place. A model that
    /// thinks for two minutes behind the word "Thinking…" looks identical to one
    /// that has hung, and the live line is the cheapest possible answer to
    /// "is it still going, and roughly where is it".
    private var reasoning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showReasoning.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "brain")
                        .font(.system(size: 10))
                    Text(turn.complete ? "Thought it through" : "Thinking…")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showReasoning ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Only while it runs, and only while collapsed. Once the turn is
            // done the fragment is frozen mid-sentence and says nothing — worse
            // than nothing, because a stray half-thought sitting under a reply
            // reads as part of it.
            if !turn.complete, !showReasoning {
                Text(AssistantBlock.tail(of: turn.reasoning))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    // The newest words are the point, so overflow eats the
                    // start of the line rather than the end.
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // No transition. Deltas land several times a second and
                    // anything that animates between them is a blur.
                    .animation(nil, value: turn.reasoning)
                    .accessibilityHidden(true)
            }

            if showReasoning {
                Text(turn.reasoning)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(Metrics.tight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.well, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
            }
        }
    }

    /// The newest line of a stream of reasoning, for the live one-liner.
    ///
    /// The last *non-empty* line, not the last N characters: reasoning arrives
    /// as prose with paragraph breaks, and a delta that lands just after a
    /// newline would otherwise blank the row for a moment and make it flicker.
    ///
    /// - Parameter reasoning: everything folded so far.
    /// - Returns: one line, whitespace trimmed, empty when there is nothing yet.
    static func tail(of reasoning: String) -> String {
        for line in reasoning.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}

// MARK: - Notice

struct NoticeRow: View {
    let notice: Notice

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(notice.text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Metrics.gap)
        .padding(.vertical, Metrics.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
    }

    private var icon: String {
        switch notice.kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .failure: return "xmark.octagon"
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .info: return .secondary
        case .warning: return Palette.warn
        case .failure: return Palette.bad
        }
    }
}

// MARK: - Checklist

/// The agent's todo list, pinned under the header while it has one.
///
/// This is the single best answer to "what is it doing and how far along is it",
/// which is the question someone opens the app to ask.
struct TodoStrip: View {
    let todos: [TodoItem]
    @State private var expanded = false

    var body: some View {
        let done = todos.filter { $0.status == .completed }.count
        let current = todos.first { $0.status == .inProgress }

        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Metrics.tight) {
                    Text(current?.content ?? (done == todos.count ? "All steps done" : "Working"))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Text("\(done)/\(todos.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(todos) { todo in
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: symbol(todo.status))
                                    .font(.system(size: 11))
                                    .foregroundStyle(colour(todo.status))
                                Text(todo.content)
                                    .font(.system(size: 13))
                                    .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                                    .strikethrough(todo.status == .completed, color: .secondary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.top, 2)
                } else {
                    ProgressView(value: Double(done), total: Double(max(todos.count, 1)))
                        .tint(Palette.accent)
                        .scaleEffect(x: 1, y: 0.6, anchor: .center)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, Metrics.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Divider().overlay(Palette.line) }
    }

    private func symbol(_ status: TodoItem.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func colour(_ status: TodoItem.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return Palette.accent
        case .completed: return Palette.good
        }
    }
}

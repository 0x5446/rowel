/// The two moments the agent stops and waits.
///
/// An approval and a question are the only things in this app with a deadline —
/// the machine is idle until one is answered — so they get the bottom of the
/// screen, above the composer, where a thumb already is. They are not sheets: a
/// sheet hides the transcript, and the transcript is how someone decides.

import SwiftUI

// MARK: - Approval

struct ApprovalCard: View {
    let request: ApprovalRequest
    let onAnswer: (Bool) -> Void
    @State private var answering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            HStack(spacing: Metrics.tight) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.warn)
                Text("Run \(request.toolName)?")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }
            if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Metrics.tight) {
                Button {
                    answering = true
                    onAnswer(false)
                } label: {
                    Text("Don’t")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Palette.well, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
                }
                .foregroundStyle(.primary)
                Button {
                    answering = true
                    onAnswer(true)
                } label: {
                    Text("Allow")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
                }
            }
            .disabled(answering)
        }
        .padding(Metrics.gap)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .stroke(Palette.warn.opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Questions

struct QuestionCard: View {
    let request: QuestionRequest
    let onAnswer: ([String: QuestionAnswer]) -> Void

    /// How much of a card the questions may take before they scroll.
    ///
    /// Sized so the whole card — capped questions, the Send button, the card's
    /// own padding — stays inside the band above the composer
    /// (`ConversationView.bandCeiling`), on the smallest phone the app supports.
    static let questionsCeiling: CGFloat = 260

    @State private var selections: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var writing: String?
    @State private var answering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            if request.items.count == 1, let item = request.items[0].isPlanReview ? request.items[0] : nil {
                plan(item)
            } else {
                // The questions scroll; the Send button below them does not. The
                // card is as tall as the questions it was asked — three of them
                // with described options is taller than a phone — and a Send
                // button that scrolls away with the last option is a card that
                // cannot be answered without hunting for the button first.
                CappedScroll(ceiling: QuestionCard.questionsCeiling) {
                    VStack(alignment: .leading, spacing: Metrics.gap) {
                        ForEach(request.items) { item in
                            question(item)
                        }
                    }
                }
                Button("Send") { submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(answering || !complete)
            }
        }
        .padding(Metrics.gap)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .stroke(Palette.accent.opacity(0.45), lineWidth: 1)
        )
        .sheet(item: Binding(get: { writing.map(Identified.init) }, set: { writing = $0?.value })) { held in
            CustomAnswerSheet(
                prompt: request.items.first { $0.id == held.value }?.question ?? "Your answer",
                text: Binding(
                    get: { custom[held.value] ?? "" },
                    set: { custom[held.value] = $0 }
                )
            )
        }
    }

    // MARK: A plan waiting for a verdict

    /// Plan review is a question in the wire protocol and a different thing on
    /// screen: one long document and a yes/no, not a menu. Rendering it as a menu
    /// buries the plan itself in an option label.
    @ViewBuilder
    private func plan(_ item: QuestionItem) -> some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            HStack(spacing: 6) {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(item.header ?? "Ready to start")
                    .font(.system(size: 15, weight: .semibold))
            }
            if let detail = item.detail, !detail.isEmpty {
                // Same reason as the questions above, and the same treatment:
                // the verdict buttons are the point of the card, and a plan is
                // always longer than the room left for it.
                CappedScroll(ceiling: QuestionCard.questionsCeiling) {
                    MarkdownText(source: detail, size: 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(item.question)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Metrics.tight) {
                if let decline = item.options.first(where: { $0.label != item.approveLabel }) {
                    Button {
                        answering = true
                        onAnswer([item.id: QuestionAnswer(selected: [decline.label])])
                    } label: {
                        Text(decline.label)
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(Palette.well, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
                    }
                    .foregroundStyle(.primary)
                }
                Button {
                    answering = true
                    onAnswer([item.id: QuestionAnswer(selected: [item.approveLabel ?? "Yes"])])
                } label: {
                    Text(item.approveLabel ?? "Go ahead")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
                }
            }
            .disabled(answering)
        }
    }

    // MARK: An ordinary question

    @ViewBuilder
    private func question(_ item: QuestionItem) -> some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            if let header = item.header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            Text(item.question)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 6) {
                ForEach(item.options) { option in
                    OptionRow(
                        option: option,
                        chosen: selections[item.id]?.contains(option.label) == true,
                        multi: item.multiSelect
                    ) {
                        choose(item, option.label)
                    }
                }
                OptionRow(
                    option: QuestionOption(label: custom[item.id]?.isEmpty == false ? custom[item.id]! : "Something else…", description: nil),
                    chosen: custom[item.id]?.isEmpty == false,
                    multi: item.multiSelect
                ) {
                    writing = item.id
                }
            }
        }
    }

    private func choose(_ item: QuestionItem, _ label: String) {
        var held = selections[item.id] ?? []
        if item.multiSelect {
            if held.contains(label) { held.remove(label) } else { held.insert(label) }
            selections[item.id] = held
            return
        }
        selections[item.id] = [label]
        custom[item.id] = nil
        // One question, one choice, no confirm step: the tap is the answer.
        if request.items.count == 1 {
            answering = true
            onAnswer([item.id: QuestionAnswer(selected: [label])])
        }
    }

    private var complete: Bool {
        request.items.allSatisfy { item in
            selections[item.id]?.isEmpty == false || custom[item.id]?.isEmpty == false
        }
    }

    private func submit() {
        answering = true
        var answers: [String: QuestionAnswer] = [:]
        for item in request.items {
            answers[item.id] = QuestionAnswer(
                selected: Array(selections[item.id] ?? []),
                custom: custom[item.id]?.isEmpty == false ? custom[item.id] : nil
            )
        }
        onAnswer(answers)
    }
}

private struct OptionRow: View {
    let option: QuestionOption
    let chosen: Bool
    let multi: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Metrics.tight) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(chosen ? Palette.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 14.5, weight: .medium))
                        .multilineTextAlignment(.leading)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(Metrics.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous)
                    .fill(chosen ? Palette.accent.opacity(0.10) : Palette.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous)
                    .stroke(chosen ? Palette.accent.opacity(0.5) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        if multi { return chosen ? "checkmark.square.fill" : "square" }
        return chosen ? "largecircle.fill.circle" : "circle"
    }
}

private struct CustomAnswerSheet: View {
    let prompt: String
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                Text(prompt)
                    .font(.system(size: 15, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(.system(size: 15))
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(Metrics.tight)
                    .background(Palette.well, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
                Spacer()
            }
            .padding(Metrics.gutter)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

/// A `String` that can drive `.sheet(item:)`.
struct Identified: Identifiable {
    let value: String
    var id: String { value }
}

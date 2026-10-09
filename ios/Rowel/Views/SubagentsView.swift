/// The children a conversation spawned.
///
/// A subagent is where the time goes and the one place the transcript stops
/// explaining itself: the parent shows a tool call, the tool call sits there
/// for four minutes, and everything the child did happens somewhere the app
/// could not see. The conversation list leaves subagents out on purpose, so
/// without this screen they do not exist as far as the phone is concerned.
///
/// Read-only, deliberately. A child can be messaged and interrupted, and that
/// is not here: talking to a child behind the parent's back is a way to
/// confuse the parent's own accounting of it, and "what is it doing" is the
/// question a phone actually has.

import SwiftUI

struct SubagentsView: View {
    let session: MachineSession
    let conversation: Conversation
    /// Open a child's own conversation. A child is a real session, so this is
    /// the same push as any other.
    let onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading && conversation.subagents.isEmpty {
                    Placeholder(icon: "ellipsis", title: "Looking…")
                } else if conversation.subagents.isEmpty {
                    Placeholder(
                        icon: conversation.subagentsKnown ? "person.2.slash" : "questionmark.circle",
                        title: conversation.subagentsKnown ? "No subagents" : "Can’t tell",
                        // "None" and "cannot say" are different answers and the
                        // machine distinguishes them, so this does too.
                        detail: conversation.subagentsKnown
                            ? "This conversation has not handed anything off to a child agent."
                            : "The Mac could not enumerate this conversation’s children."
                    )
                } else {
                    List(conversation.subagents) { child in
                        Button {
                            dismiss()
                            onOpen(child.id)
                        } label: {
                            ChildRow(child: child)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: Metrics.gutter, bottom: 8, trailing: Metrics.gutter))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Subagents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await session.loadSubagents(conversation) }
            .task {
                await session.loadSubagents(conversation)
                loading = false
            }
        }
    }
}

private struct ChildRow: View {
    let child: SubagentChild

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.tight) {
            Image(systemName: child.hasChildren ? "person.2" : "person")
                .font(.system(size: 13))
                .foregroundStyle(child.running ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(child.displayLabel)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    // Activity, not outcome. The machine is explicit that
                    // `inactive` says nothing about whether the child
                    // succeeded, so this must not become a tick.
                    Text(child.running ? "Running" : "Not running")
                        .font(.system(size: 11.5, weight: child.running ? .semibold : .regular))
                        .foregroundStyle(child.running ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.secondary))
                    if let elapsed = child.elapsed {
                        Text(Format.duration(ms: Int(elapsed * 1000)))
                            .font(.code(11))
                            .foregroundStyle(.secondary)
                    }
                    Text(child.mode == .continuable ? "resumable" : "one-shot")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: Metrics.tight)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .contentShape(Rectangle())
    }
}

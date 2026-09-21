/// The slash commands this machine knows.
///
/// Two kinds arrive by different routes, and they behave differently when sent,
/// so the list has to say which is which:
///
/// - a **skill** is text. `session.prompt` needs nothing new for those: the
///   words go to the model and the model reads the skill. What was missing was
///   only discovery — nobody can be expected to remember thirty names.
/// - a **command** is something the machine runs: `/permission read-only`
///   switches *this* session's access mode. It is not text at all. Measured: a
///   `session.prompt` carrying a slash line lands in the log as an ordinary user
///   message and starts a turn, with the model left to work out what the words
///   meant. So a command has to be recognised here and handed to
///   `commands/execute` instead — which is exactly what the browser's composer
///   does with the same line.
///
/// It appears while the message is a bare `/word` with no space yet, which is
/// exactly the window in which someone is trying to remember a name and no
/// other window. After the first space they are writing arguments and a list
/// covering the screen would be in the way.
///
/// The list is fetched once per session and kept. It changes when someone adds a
/// skill file or mounts a plugin on the Mac, which is not something that happens
/// mid-sentence, and a request on every keystroke would be.

import SwiftUI

/// One entry the composer offers after a slash.
public struct SlashCommand: Identifiable, Equatable, Sendable {
    /// Which of the two mechanisms sends this one.
    public enum Kind: Equatable, Sendable {
        /// Text the model reads (`skill.list`).
        case skill
        /// Something the machine runs (`commands/list`).
        case command
    }

    public var id: String { name }
    public var name: String
    public var detail: String
    public var kind: Kind
    /// What arguments the command takes, as the machine advertises them —
    /// `<preset>`, `[off|message]`. Nil for skills, and for a command that
    /// takes none.
    public var hint: String?

    /// A skill, from `skill.list`.
    public init?(_ value: JSONValue) {
        guard let name = value["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        detail = value["description"]?.stringValue ?? ""
        kind = .skill
        hint = nil
    }

    /// A command, from `commands/list`.
    public init?(command value: JSONValue) {
        guard let name = value["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        detail = value["description"]?.stringValue ?? ""
        kind = .command
        hint = value.path("input", "hint")?.stringValue
    }

    /// The first sentence, which is all that fits and usually all there is worth
    /// reading — these descriptions are written for a model, at model length.
    public var summary: String {
        let cut = detail.firstIndex { $0 == "." || $0 == "。" }
        let head = cut.map { String(detail[detail.startIndex..<$0]) } ?? detail
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Whether `text` is someone partway through typing a command name.
///
/// - Returns: the partial name, or nil when this is not that.
public func commandPrefix(in text: String) -> String? {
    guard text.hasPrefix("/") else { return nil }
    let body = text.dropFirst()
    // A space means they have moved on to arguments; a newline means they are
    // writing a message that merely starts with a slash.
    guard !body.contains(where: { $0 == " " || $0.isNewline }) else { return nil }
    return String(body)
}

/// The machine command this line names, if it names one.
///
/// The one place this is decided, because two callers need the same answer for
/// different reasons: the composer refuses a command that is carrying a photo
/// before anything leaves the phone, and the store sends a command to
/// `commands/execute` instead of handing it to the model. A skill under the same
/// slash is deliberately not a match — it is text the model reads.
///
/// The comparison is exact and against a list the machine gave us. Anything else
/// — a path, a sentence, a name the machine never offered — has to stay a
/// message, which is what all of it was before commands were routable.
public func machineCommand(in text: String, among commands: [SlashCommand]) -> SlashCommand? {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard body.hasPrefix("/") else { return nil }
    let name = body.dropFirst().prefix { !$0.isWhitespace }
    guard !name.isEmpty else { return nil }
    return commands.first { $0.kind == .command && $0.name == name }
}

/// Why this draft must not be sent, when the reason is about the draft itself.
///
/// One case today: a command carrying a photo. A command takes no attachments —
/// the machine's own `/permission` declares no image input — and nothing can
/// un-attach one after the fact, so the draft stays where it is and this is what
/// the composer says instead. Refusing is the only option that neither drops the
/// photo nor hands the command to the model as words, and it is what dsh's own
/// composer does with the same line.
public func draftRefusal(text: String, hasImages: Bool, among commands: [SlashCommand]) -> String? {
    guard hasImages, let named = machineCommand(in: text, among: commands) else { return nil }
    return "A /\(named.name) command cannot carry a photo. Remove the picture and send it again."
}

struct CommandPicker: View {
    let commands: [SlashCommand]
    let filter: String
    let onPick: (SlashCommand) -> Void

    private var matches: [SlashCommand] {
        guard !filter.isEmpty else { return commands }
        let needle = filter.lowercased()
        // Prefix matches first: someone typing `/co` means the command starting
        // with "co", not the one whose description mentions it.
        let starts = commands.filter { $0.name.lowercased().hasPrefix(needle) }
        let contains = commands.filter {
            !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle)
        }
        return starts + contains
    }

    var body: some View {
        if !matches.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { command in
                        Button {
                            onPick(command)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                // The arguments ride on the name rather than
                                // sitting in a second column: `/permission` on
                                // its own says nothing about the fact that it
                                // wants a preset, and that is the one thing
                                // someone who does not know the command needs.
                                Text("/\(command.name)\(command.hint.map { " \($0)" } ?? "")")
                                    .font(.code(14))
                                    .foregroundStyle(.primary)
                                if !command.summary.isEmpty {
                                    Text(command.summary)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Metrics.gutter)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        Divider().padding(.leading, Metrics.gutter)
                    }
                }
            }
            // Tall enough for three or four without becoming the screen. The
            // transcript is how someone decides what to run next, so covering
            // it would trade one kind of blindness for another.
            .frame(maxHeight: 210)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityIdentifier("command.picker")
        }
    }
}

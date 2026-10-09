/// Tool calls, drawn by kind.
///
/// `Conversation.callPresentation` picks the kind — terminal, diff, search, read,
/// or generic — from the tool's name and arguments, since dsh 0.2 attaches no
/// rendering hints. A tool it does not know, such as one a plugin added last
/// week, still gets the generic card with its most telling argument.
///
/// Every card is collapsed by default. A transcript where each tool call takes
/// half a screen is unreadable on a phone; the headline is what matters, and the
/// body is one tap away.

import SwiftUI

struct ToolCardView: View {
    let card: ToolCard
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // A question is shown open: what was asked and what was picked is
            // the whole point of the card, and it is a few short lines.
            if case .question(let items, let answers) = card.presentation {
                Divider().overlay(Palette.line)
                QuestionBody(items: items, answers: answers, waiting: card.running)
                    .padding(Metrics.gap)
            } else if expanded {
                Divider().overlay(Palette.line)
                body(for: card.presentation)
                    .padding(Metrics.gap)
            }
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous)
                .stroke(card.failed ? Palette.bad.opacity(0.4) : Palette.line, lineWidth: 0.5)
        )
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: Metrics.tight) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 16)
                Text(card.headline)
                    .font(headlineFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                trailing
                if !isQuestion {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .padding(.horizontal, Metrics.gap)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var isQuestion: Bool {
        if case .question = card.presentation { return true }
        return false
    }

    @ViewBuilder
    private var trailing: some View {
        if card.running {
            ProgressView().controlSize(.mini)
        } else if card.failed {
            Pill("failed", color: Palette.bad)
        } else if case .terminal(_, _, _, let exitCode) = card.presentation, let exitCode, exitCode != 0 {
            Pill("exit \(exitCode)", color: Palette.bad)
        } else if case .search(_, let lines, _, let total) = card.presentation {
            Pill("\(total > lines.count ? total : lines.count)")
        } else if case .diff(_, let files) = card.presentation, files.count > 1 {
            Pill("\(files.count) files")
        } else if case .question(_, let answers) = card.presentation {
            Pill(answers == nil ? "not answered" : "answered", color: answers == nil ? .secondary : Palette.good)
        }
    }

    private var headlineFont: Font {
        switch card.presentation {
        case .terminal, .read: return .code(13)
        default: return .system(size: 14, weight: .medium)
        }
    }

    private var icon: String {
        switch card.presentation {
        case .terminal: return "terminal"
        case .diff: return "plusminus"
        case .search: return "magnifyingglass"
        case .read: return "doc.text"
        case .question: return "questionmark.bubble"
        case .generic(_, let kind, _):
            switch kind {
            case "fetch", "search": return "globe"
            case "write", "edit": return "square.and.pencil"
            default: return "wrench.and.screwdriver"
            }
        }
    }

    private var tint: Color {
        if card.failed { return Palette.bad }
        if card.running { return Palette.accent }
        return .secondary
    }

    // MARK: - Bodies

    @ViewBuilder
    private func body(for presentation: ToolPresentation) -> some View {
        switch presentation {
        case .terminal(let command, let cwd, let output, _):
            TerminalBody(command: command, cwd: cwd, output: output ?? card.resultText)
        case .diff(_, let files):
            DiffBody(files: files)
        case .search(_, let lines, let truncated, let total):
            SearchBody(lines: lines, truncated: truncated, total: total)
        case .read(_, let lines, let totalLines):
            ReadBody(lines: lines, totalLines: totalLines)
        case .generic(_, _, let detail):
            GenericBody(detail: detail, arguments: card.arguments, result: card.resultText)
        case .question(let items, let answers):
            QuestionBody(items: items, answers: answers, waiting: card.running)
        }
    }
}

// MARK: - Question

/// What the agent asked, with what the person picked marked — the transcript's
/// record of a question card answered earlier, live or on another device.
private struct QuestionBody: View {
    let items: [QuestionItem]
    let answers: [String: QuestionAnswer]?
    let waiting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            ForEach(items) { item in
                let answer = answers?[item.id]
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.question)
                        .font(.system(size: 14, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(item.options) { option in
                        row(option.label, picked: answer?.selected.contains(option.label) == true)
                    }
                    // A pick that is not one of the options — dsh lets a person
                    // choose "other" — still shows, checked.
                    ForEach(extraPicks(item, answer), id: \.self) { label in
                        row(label, picked: true)
                    }
                    if let custom = answer?.custom, !custom.isEmpty {
                        Text("“\(custom)”")
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .padding(.leading, 22)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if answers == nil {
                Text(waiting ? "Waiting for your answer" : "Not answered")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, picked: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(picked ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
            Text(label)
                .font(.system(size: 13, weight: picked ? .semibold : .regular))
                .foregroundStyle(picked ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func extraPicks(_ item: QuestionItem, _ answer: QuestionAnswer?) -> [String] {
        let labels = Set(item.options.map(\.label))
        return (answer?.selected ?? []).filter { !labels.contains($0) }
    }
}

// MARK: - Terminal

private struct TerminalBody: View {
    let command: String
    let cwd: String?
    let output: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            if let cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.code(11))
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text("$ " + command)
                    .font(.code(12.5))
                    .textSelection(.enabled)
            }
            if let output, !output.isEmpty {
                Output(text: output)
            }
        }
    }
}

/// Fixed-height scrolling output. A 4000-line build log inside a scroll view
/// inside another scroll view is a gesture fight; capping the height and letting
/// it scroll on its own is the version that works with a thumb.
private struct Output: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            Text(text)
                .font(.code(12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.tight)
        }
        .frame(maxHeight: 260)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Diff

private struct DiffBody: View {
    let files: [FileDiff]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            ForEach(files) { file in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text((file.path as NSString).lastPathComponent)
                            .font(.code(12))
                            .fontWeight(.semibold)
                        let counts = DiffLine.counts(old: file.oldText, new: file.newText)
                        if counts.added > 0 {
                            Text("+\(counts.added)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.good)
                        }
                        if counts.removed > 0 {
                            Text("−\(counts.removed)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.bad)
                        }
                    }
                    Text(file.path)
                        .font(.code(10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    DiffPane(old: file.oldText, new: file.newText)
                }
            }
        }
    }
}

/// One line of a rendered diff.
struct DiffLine: Identifiable, Equatable {
    enum Kind { case same, added, removed }

    let id: Int
    let kind: Kind
    let text: String

    /// A line-level diff, longest-common-subsequence.
    ///
    /// Quadratic in the number of lines, which is fine for the size of edit an
    /// agent makes and bounded below anyway: past the cap it degrades to "all
    /// removed, then all added", which is still true, just less pretty.
    static func diff(old: String?, new: String) -> [DiffLine] {
        let newLines = new.components(separatedBy: "\n")
        guard let old, !old.isEmpty else {
            return newLines.enumerated().map { DiffLine(id: $0.offset, kind: .added, text: $0.element) }
        }
        let oldLines = old.components(separatedBy: "\n")
        let budget = 1200
        guard oldLines.count * newLines.count <= budget * budget else {
            let removed = oldLines.enumerated().map { DiffLine(id: $0.offset, kind: .removed, text: $0.element) }
            let added = newLines.enumerated().map { DiffLine(id: oldLines.count + $0.offset, kind: .added, text: $0.element) }
            return removed + added
        }

        var table = [[Int]](repeating: [Int](repeating: 0, count: newLines.count + 1), count: oldLines.count + 1)
        for i in stride(from: oldLines.count - 1, through: 0, by: -1) {
            for j in stride(from: newLines.count - 1, through: 0, by: -1) {
                table[i][j] = oldLines[i] == newLines[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var lines: [DiffLine] = []
        var i = 0, j = 0
        while i < oldLines.count && j < newLines.count {
            if oldLines[i] == newLines[j] {
                lines.append(DiffLine(id: lines.count, kind: .same, text: oldLines[i]))
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                lines.append(DiffLine(id: lines.count, kind: .removed, text: oldLines[i]))
                i += 1
            } else {
                lines.append(DiffLine(id: lines.count, kind: .added, text: newLines[j]))
                j += 1
            }
        }
        while i < oldLines.count {
            lines.append(DiffLine(id: lines.count, kind: .removed, text: oldLines[i]))
            i += 1
        }
        while j < newLines.count {
            lines.append(DiffLine(id: lines.count, kind: .added, text: newLines[j]))
            j += 1
        }
        return lines
    }

    /// Collapse long runs of unchanged lines to a few lines of context either
    /// side, the way every diff viewer does.
    static func trimmed(_ lines: [DiffLine], context: Int = 3) -> [DiffLine] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return Array(lines.prefix(context * 2)) }
        var keep = Set<Int>()
        for index in changed {
            for offset in -context...context {
                let candidate = index + offset
                if lines.indices.contains(candidate) { keep.insert(candidate) }
            }
        }
        return lines.indices.filter { keep.contains($0) }.map { lines[$0] }
    }

    static func counts(old: String?, new: String) -> (added: Int, removed: Int) {
        let lines = diff(old: old, new: new)
        return (
            lines.filter { $0.kind == .added }.count,
            lines.filter { $0.kind == .removed }.count
        )
    }
}

private struct DiffPane: View {
    let old: String?
    let new: String

    var body: some View {
        let lines = DiffLine.trimmed(DiffLine.diff(old: old, new: new))
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text(marker(line.kind))
                            .font(.code(11))
                            .foregroundStyle(colour(line.kind))
                            .frame(width: 10, alignment: .leading)
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.code(11.5))
                            .foregroundStyle(line.kind == .same ? .secondary : .primary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(line.kind))
                }
            }
            .frame(minWidth: 260, alignment: .leading)
        }
        .frame(maxHeight: 300)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .same: return " "
        }
    }

    private func colour(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Palette.good
        case .removed: return Palette.bad
        case .same: return .secondary.opacity(0.5)
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Palette.added
        case .removed: return Palette.removed
        case .same: return .clear
        }
    }
}

// MARK: - Search and read

private struct SearchBody: View {
    let lines: [String]
    let truncated: Bool
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if lines.isEmpty {
                Text("No matches")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.prefix(200).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.code(11.5))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(Metrics.tight)
                }
                .frame(maxHeight: 300)
                .background(Palette.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if truncated || total > lines.count {
                Text("Showing \(min(lines.count, 200)) of \(total)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ReadBody: View {
    let lines: [NumberedLine]
    let totalLines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(line.number)")
                                .font(.code(10.5))
                                .foregroundStyle(.tertiary)
                                .frame(width: 34, alignment: .trailing)
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.code(11.5))
                        }
                        .padding(.vertical, 0.5)
                    }
                }
                .padding(Metrics.tight)
            }
            .frame(maxHeight: 320)
            .background(Palette.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            if totalLines > lines.count {
                Text("\(lines.count) of \(totalLines) lines")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Generic

private struct GenericBody: View {
    let detail: String?
    let arguments: String
    let result: String?
    @State private var showArguments = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            if let detail, !detail.isEmpty {
                Output(text: detail)
            }
            if let result, !result.isEmpty, result != detail {
                Text("Result")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Output(text: result)
            }
            if detail == nil && (result ?? "").isEmpty {
                Text("No output")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if arguments != "{}" && !arguments.isEmpty {
                Button(showArguments ? "Hide input" : "Show input") {
                    withAnimation(.easeInOut(duration: 0.15)) { showArguments.toggle() }
                }
                .font(.system(size: 12, weight: .medium))
                if showArguments {
                    Output(text: arguments)
                }
            }
        }
    }
}

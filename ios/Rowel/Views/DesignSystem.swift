/// The visual vocabulary.
///
/// One place for colour, type, and spacing so screens stay consistent without
/// each one restating the rules. The palette is deliberately narrow: a paper
/// background, one ink, one accent, and three semantic colours for states that
/// carry meaning. Everything else is opacity.
///
/// Colours are defined in code rather than in an asset catalog because there are
/// six of them and a catalog would hide them from anyone reading this file.

import SwiftUI

public enum Palette {
    /// The one saturated colour, used for the send button, links, and selection.
    public static let accent = Color(light: .init(red: 0.11, green: 0.36, blue: 0.94), dark: .init(red: 0.42, green: 0.62, blue: 1.0))
    /// Page background.
    public static let paper = Color(light: .init(white: 0.98), dark: .init(white: 0.07))
    /// Raised surfaces: cards, the composer, sheets.
    public static let surface = Color(light: .white, dark: .init(white: 0.12))
    /// Recessed surfaces: code blocks, terminal output.
    public static let well = Color(light: .init(white: 0.955), dark: .init(white: 0.16))
    /// Hairlines.
    public static let line = Color(light: .init(white: 0.88), dark: .init(white: 0.24))

    public static let good = Color(light: .init(red: 0.06, green: 0.55, blue: 0.32), dark: .init(red: 0.30, green: 0.80, blue: 0.52))
    public static let warn = Color(light: .init(red: 0.72, green: 0.45, blue: 0.03), dark: .init(red: 0.95, green: 0.72, blue: 0.28))
    public static let bad = Color(light: .init(red: 0.76, green: 0.17, blue: 0.17), dark: .init(red: 1.0, green: 0.45, blue: 0.42))

    /// Diff colours, kept low-saturation so a long diff is readable.
    public static let added = Color(light: .init(red: 0.85, green: 0.95, blue: 0.87), dark: .init(red: 0.10, green: 0.24, blue: 0.15))
    public static let removed = Color(light: .init(red: 0.99, green: 0.89, blue: 0.89), dark: .init(red: 0.28, green: 0.12, blue: 0.13))
}

public extension Color {
    /// A colour that differs between light and dark, without an asset catalog.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self = Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        self = light
        #endif
    }
}

public enum Metrics {
    public static let gutter: CGFloat = 16
    public static let gap: CGFloat = 12
    public static let tight: CGFloat = 8
    public static let radius: CGFloat = 14
    public static let smallRadius: CGFloat = 9
}

public extension Font {
    /// Monospaced text at body size, for paths, commands, and code.
    static func code(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}

// MARK: - Shared pieces

/// A small labelled chip. Used for connection state, exit codes, and tool kinds.
public struct Pill: View {
    let text: String
    var color: Color = .secondary
    var icon: String?

    public init(_ text: String, color: Color = .secondary, icon: String? = nil) {
        self.text = text
        self.color = color
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
    }
}

/// A card: the standard raised container.
public struct Card<Content: View>: View {
    var padding: CGFloat = Metrics.gap
    @ViewBuilder var content: Content

    public init(padding: CGFloat = Metrics.gap, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .stroke(Palette.line, lineWidth: 0.5)
            )
    }
}

/// A run of content that scrolls only once it would be taller than `ceiling`.
///
/// For the two places where content of unknown length has to share the screen
/// with something that must stay reachable: the questions in a question card,
/// and the interrupt band above the composer. Sized to its content until that
/// exceeds the ceiling, so a short one looks like nothing was wrapped around it
/// at all.
///
/// The height is measured from the inside rather than asked for from the
/// outside. A scroll view hands its content the height the content wants, so
/// the preference below is the natural height whatever the frame turns out to
/// be — and nothing here has to assume whether a `ScrollView` asked for a
/// bounded height would have taken it or not.
public struct CappedScroll<Content: View>: View {
    var ceiling: CGFloat
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    public init(ceiling: CGFloat, @ViewBuilder content: () -> Content) {
        self.ceiling = ceiling
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            content
                .background(GeometryReader { inner in
                    Color.clear.preference(key: ContentHeight.self, value: inner.size.height)
                })
        }
        // So a short card neither rubber-bands nor claims the room it does not
        // need.
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(height, 1), ceiling))
        .onPreferenceChange(ContentHeight.self) { height = $0 }
    }
}

/// How tall a `CappedScroll`'s content is, reported from inside it.
private struct ContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The three dots that mean the agent is thinking. Deliberately quiet: a spinner
/// implies a wait with an end, and a turn can run for minutes.
public struct Thinking: View {
    @State private var phase = 0.0

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 5, height: 5)
                    .opacity(0.25 + 0.75 * pulse(index))
            }
        }
        .foregroundStyle(.secondary)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 3 }
        }
    }

    private func pulse(_ index: Int) -> Double {
        let distance = abs(phase - Double(index))
        return max(0, 1 - min(distance, 3 - distance))
    }
}

/// A full-screen state: an icon, a line, and one action. Used for every empty,
/// error, and waiting screen so they all read the same way.
public struct Placeholder<Action: View>: View {
    let icon: String
    let title: String
    let detail: String?
    @ViewBuilder var action: Action

    public init(icon: String, title: String, detail: String? = nil, @ViewBuilder action: () -> Action) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.action = action()
    }

    public var body: some View {
        VStack(spacing: Metrics.gap) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            action.padding(.top, 4)
        }
        .padding(Metrics.gutter * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

public extension Placeholder where Action == EmptyView {
    init(icon: String, title: String, detail: String? = nil) {
        self.init(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}

/// The app's primary button.
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }
}

/// A quieter button for the second choice on a screen.
public struct SecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Palette.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }
}

// MARK: - Formatting

public enum Format {
    /// "just now", "12m", "3h", "Tuesday", "12 Mar" — the shortest thing that is
    /// still unambiguous at a glance in a list.
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 604_800 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }

    /// A path with the home directory collapsed, the way a shell prompt shows it.
    public static func path(_ path: String, home: String? = nil) -> String {
        guard let home, !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A token count, short enough to sit in a row without wrapping.
    ///
    /// Deliberately coarse above a thousand. Nobody compares 687,412 to
    /// 688,003; they want to know it is most of a million.
    public static func tokens(_ count: Int) -> String {
        if count < 1_000 { return "\(count)" }
        if count < 1_000_000 {
            let thousands = Double(count) / 1_000
            return thousands < 10
                ? String(format: "%.1fk", thousands)
                : "\(Int(thousands.rounded()))k"
        }
        return String(format: "%.1fM", Double(count) / 1_000_000)
    }

    /// A duration in the largest unit that still says something useful.
    public static func duration(ms: Int) -> String {
        if ms < 1_000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1_000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        if minutes < 60 { return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m"
    }
}

/// The composer's text field.
///
/// SwiftUI's own `TextField(text:axis:.vertical)` is the obvious thing to use
/// here and it is what shipped, but it cannot be trusted with text of unknown
/// length. It is a `UITextView` with scrolling switched off, so SwiftUI sizes it
/// by asking for an intrinsic height — and `-[UITextView _intrinsicSizeWithinSize:]`
/// answers by laying the *entire* string out in TextKit 2 before anything is
/// clamped to `lineLimit(1...6)`. Measured on the simulator, per change:
///
///     10 KB     366 ms
///     50 KB     878 ms
///     200 KB  2,452 ms
///
/// and it is paid again on every keystroke, because typing invalidates the
/// cached intrinsic size. Paste a build log into the composer and the app stops
/// answering. That is the freeze in the field reports and the four `0x8BADF00D`
/// watchdog kills behind them: iOS asked the app to suspend while the main
/// thread was inside that measurement, and five seconds was not enough.
///
/// So: leave scrolling on, which makes TextKit 2 lay out by viewport rather than
/// whole-document, and never let anything ask for an intrinsic size. The height
/// comes from a direct measurement — but only while the text is short enough for
/// that to be cheap. Past the ceiling the answer is certainly "the maximum", so
/// it is not asked. The same ladder with this view: 370 ms, 363 ms, 366 ms —
/// flat, which is the point.
///
/// No placeholder lives in here. A label constrained inside a `UITextView` is a
/// subview of a scroll view, and Auto Layout resolving it wants the scroll
/// content size, which is the whole-document layout again by another road. The
/// caller already knows whether the text is empty; it can draw the prompt.

import SwiftUI
import UIKit

struct GrowingField: UIViewRepresentable {
    @Binding var text: String
    /// Two-way, and the reason this is not `@FocusState`: that only drives
    /// SwiftUI's own focusable views, and this one is a first responder. The
    /// binding is written from the delegate and read in `updateUIView`.
    @Binding var focused: Bool
    /// How tall it may grow before it starts scrolling instead.
    var maxLines: Int = 6
    var font: UIFont = .systemFont(ofSize: 16)
    /// Set on the text view itself, not through SwiftUI's modifiers. A
    /// `UIViewRepresentable` does not forward `.accessibilityIdentifier` or
    /// `.accessibilityLabel` down to the view it wraps — the wrapped view keeps
    /// its own accessibility, and a modifier applied outside is simply lost.
    /// Losing it here made the composer unreachable to VoiceOver and invisible
    /// to every UI test that looks for it by name.
    var identifier: String?
    var label: String?

    /// Above this many UTF-8 bytes the field is certainly at `maxLines`, and
    /// measuring only proves it slowly. Six lines of a 16pt font on the widest
    /// phone is around 300 characters, so this has an order of magnitude of
    /// headroom and still bounds the work at a few milliseconds. Bytes rather
    /// than characters because `String.count` walks the whole string to break
    /// graphemes, and an O(n) check guarding O(n) work is not a guard.
    private static let measurementCeiling = 4_000

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        // The whole point: viewport layout, not whole-document layout.
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = font
        view.delegate = context.coordinator
        view.adjustsFontForContentSizeCategory = true
        // Without these the view reports a content-driven intrinsic size and
        // SwiftUI is back to measuring the whole string.
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = label
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = label
        // Assigning unconditionally would reset the selection on every parent
        // render, which moves the caret while someone is typing. The comparison
        // is against the coordinator's copy rather than `view.text`, because
        // that getter builds a fresh String out of the text storage every time
        // it is read.
        if context.coordinator.lastSet != text {
            view.text = text
            context.coordinator.lastSet = text
        }
        if focused, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !focused, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    /// The one place a height comes from. This is what SwiftUI calls, and
    /// answering it without measuring is the entire fix.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        let line = uiView.font?.lineHeight ?? font.lineHeight
        let ceiling = (line * CGFloat(maxLines)).rounded(.up)
        guard text.utf8.count <= Self.measurementCeiling else {
            return CGSize(width: width, height: ceiling)
        }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(ceiling, max(line, fitted.rounded(.up))))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingField
        /// What was last written into the view, so `updateUIView` can tell a
        /// real change from a re-render without reading the view back.
        var lastSet = ""

        init(parent: GrowingField) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            lastSet = textView.text
            parent.text = textView.text
        }

        // Writing the binding from here rather than from `updateUIView` — the
        // keyboard can be dismissed by a drag or by the system, and the parent
        // has to hear about it either way.
        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focused { parent.focused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused { parent.focused = false }
        }
    }
}

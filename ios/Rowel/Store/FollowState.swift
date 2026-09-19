/// Whether the transcript is following its tail.
///
/// Extracted from `ConversationView` for one reason: it is a decision, and a
/// decision buried in view state cannot be tested. `DragGesture` does not fire
/// under XCTest — its recognizer's state machine belongs to the window server —
/// so "the reader scrolled back and the next streamed line must leave them
/// there" was unverifiable where it lived. Here it is a value with three inputs
/// and one question, and the view only renders it.
///
/// Two faults met in that state before it was named:
///
///  1. A conversation opened at the top of its own history. The open position
///     is now the scroll view's own anchor (`.defaultScrollAnchor`), which is
///     part of layout rather than a `scrollTo` asked for after layout, and that
///     anchor is this state: following means anchored to the end.
///  2. Only a drag could stop the following. Someone who flicked back to the
///     bottom stayed disarmed, and the next answer slid in under their thumb.
///     Reaching the end re-arms, which is what `reachedEnd` records.

import CoreGraphics

@MainActor
final class FollowState {
    /// Is the transcript pinned to its own end?
    ///
    /// False the moment a drag heads back through the history, true again when
    /// the thumb reaches the end. It is the anchor for the open position and
    /// the guard on every follow, so it is one value and not two.
    private(set) var follows = true

    /// Start already scrolled away, for a caller that states the post-drag
    /// world at construction — a drag cannot be performed by a test.
    init(follows: Bool = true) {
        self.follows = follows
    }

    /// How far a drag has to head downward before it counts as reading back.
    ///
    /// A drag that follows a link, or the small travel of a tap, is not a
    /// person leaving the tail.
    private static let backThreshold: CGFloat = 24

    /// The transcript is at its end: follow again, and anchor the next open
    /// there. Called where the reader's own hand arrives at the end — the
    /// button that returns to the bottom, and sending, which puts their words
    /// there — and by an upward drag, which is the tail coming to meet them.
    func reachedEnd() {
        follows = true
    }

    /// A drag moved by this much on screen. Only the direction matters:
    /// downward is reading back, upward is the tail coming to meet the reader.
    /// - Parameter translation: the drag's translation, in points.
    func drag(_ translation: CGFloat) {
        if translation > FollowState.backThreshold { follows = false }
        else if translation < 0 { follows = true }
    }

    /// A new arrival: should the transcript be pulled to the end?
    ///
    /// The reader's answer, not the content's — a conversation someone is
    /// reading backwards must not be yanked down by a streaming answer, which
    /// is exactly what a `scrollTo` on every append does.
    func shouldFollow() -> Bool { follows }
}

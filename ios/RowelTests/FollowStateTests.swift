/// The rules that decide whether the transcript follows its tail.
///
/// These became testable the moment they stopped being view state. A drag
/// cannot be performed under XCTest — the pan recognizer's state machine lives
/// in the window server — so the reading-back rules could not be checked where
/// they were, and the fault that survived was exactly there: a reader flicked
/// back to the bottom and stayed disarmed, with the next answer sliding in
/// under their thumb. See `FollowState`.

import XCTest
@testable import Rowel

@MainActor
final class FollowStateTests: XCTestCase {

    func testAFreshConversationFollowsItsTail() {
        XCTAssertTrue(FollowState().shouldFollow())
    }

    /// The report, as a rule: opening a session shows the end.
    func testAFreshConversationAnchorsAtItsEnd() {
        XCTAssertTrue(FollowState().follows)
    }

    func testDraggingBackStopsFollowing() {
        let follow = FollowState()
        follow.drag(200)
        XCTAssertFalse(follow.shouldFollow(), "a reader in the history is not following the tail")
    }

    /// A tap, a link press, or the few points a finger moves while selecting
    /// text is not someone leaving the end.
    func testATinyDragIsNotReadingBack() {
        let follow = FollowState()
        follow.drag(24)
        XCTAssertTrue(follow.shouldFollow())
        follow.drag(25)
        XCTAssertFalse(follow.shouldFollow())
    }

    /// Scrolling further up stays away; it does not toggle back.
    func testScrollingFurtherBackStaysAway() {
        let follow = FollowState()
        follow.drag(200)
        follow.drag(50)
        XCTAssertFalse(follow.shouldFollow())
    }

    /// The other direction is the tail coming to meet the reader, so the
    /// conversation follows again without them having to do anything else.
    func testDraggingUpFollowsAgain() {
        let follow = FollowState()
        follow.drag(300)
        follow.drag(-40)
        XCTAssertTrue(follow.shouldFollow())
    }

    /// The send path: own words must be visible, so sending re-arms whatever
    /// the reader was doing.
    func testReachingTheEndFollowsAgain() {
        let follow = FollowState()
        follow.drag(400)
        follow.reachedEnd()
        XCTAssertTrue(follow.shouldFollow())
    }

    /// A caller that states the post-drag world at construction — the field
    /// report came from a device, and a test cannot drag one.
    func testScrolledAwayCanBeStatedAtConstruction() {
        XCTAssertFalse(FollowState(follows: false).shouldFollow())
    }
}

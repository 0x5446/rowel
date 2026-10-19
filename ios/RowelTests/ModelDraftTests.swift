/// Choosing a model and its thinking level before anything is sent.
///
/// The sheet used to switch the session the moment a model was tapped, and
/// close. That made the level unreachable for any model the session was not
/// already on — the levels only appear under the model in use. `ModelDraft`
/// holds both choices until Done, and these are the cases where what it holds
/// is not obvious: coming back to the model in use, a level the next model does
/// not offer, and a session that never named a level at all.

import XCTest
@testable import Rowel

final class ModelDraftTests: XCTestCase {
    private let flash = ModelOption(provider: "commandcode", providerName: "Command Code", model: "deepseek/deepseek-v4.1-flash-fast", name: "DeepSeek V4.1 Flash Fast")
    private let pro = ModelOption(provider: "commandcode", providerName: "Command Code", model: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro")
    private let sol = ModelOption(provider: "commandcode", providerName: "Command Code", model: "gpt-5.6-sol", name: "GPT-5.6 Sol")
    private let kimi = ModelOption(provider: "commandcode", providerName: "Command Code", model: "moonshotai/Kimi-K2.5", name: "Kimi K2.5")

    private func levels(_ ids: String...) -> [ReasoningEffort] {
        ids.map { ReasoningEffort(id: $0, name: $0.capitalized) }
    }

    private func catalog(current: ModelOption?, effort: String?, defaults: [String: String] = [:]) -> ModelCatalog {
        ModelCatalog(
            current: current,
            options: [flash, pro, sol, kimi],
            failures: [],
            efforts: [
                flash.id: levels("low", "high", "max"),
                pro.id: levels("high", "max"),
                sol.id: levels("low", "medium", "high", "xhigh", "max"),
            ],
            defaultEfforts: defaults,
            currentEffort: effort
        )
    }

    func testTappingAModelChangesNothingUntilDone() {
        var draft = ModelDraft(catalog(current: flash, effort: "high"))
        XCTAssertFalse(draft.changed)

        draft.choose(sol)

        XCTAssertEqual(draft.option, sol)
        XCTAssertTrue(draft.changed)
        XCTAssertEqual(draft.base.current, flash, "the live session is untouched until Done")
    }

    func testALevelPickedUnderTheNewModelTravelsWithIt() {
        var draft = ModelDraft(catalog(current: flash, effort: "high"))
        draft.choose(sol)
        draft.choose(effort: "xhigh")

        XCTAssertEqual(draft.option, sol)
        XCTAssertEqual(draft.effort, "xhigh")
    }

    func testAnotherModelStartsFromItsOwnDefaultNotThePreviousLevel() {
        var draft = ModelDraft(catalog(current: flash, effort: "low", defaults: [pro.id: "max"]))
        draft.choose(pro)
        XCTAssertEqual(draft.effort, "max")

        // No default declared: name no level rather than carry "low" across,
        // which the next model may not even offer.
        draft.choose(sol)
        XCTAssertNil(draft.effort)
    }

    func testComingBackToTheModelInUseRestoresItsLiveLevel() {
        var draft = ModelDraft(catalog(current: flash, effort: "max"))
        draft.choose(sol)
        draft.choose(effort: "medium")
        draft.choose(flash)

        XCTAssertEqual(draft.effort, "max")
        XCTAssertFalse(draft.changed)
    }

    func testTappingTheChosenModelAgainKeepsTheLevelJustPicked() {
        var draft = ModelDraft(catalog(current: flash, effort: "high"))
        draft.choose(effort: "low")
        draft.choose(flash)

        XCTAssertEqual(draft.effort, "low")
        XCTAssertTrue(draft.changed)
    }

    func testANeverNamedLevelStaysUnnamedInsteadOfShowingTheFirstOne() {
        // The bug that started this: no level set, and the sheet lit "Low" —
        // while the machine sent nothing and the model ran at its own default.
        let draft = ModelDraft(catalog(current: flash, effort: nil))
        XCTAssertNil(draft.effort)
    }

    func testALevelTheModelDoesNotOfferIsNeverHeld() {
        var draft = ModelDraft(catalog(current: pro, effort: "low"))
        XCTAssertNil(draft.effort, "a stale live level outside the model's set is not shown as chosen")
        XCTAssertFalse(draft.changed, "and hiding it is not an edit to send")

        draft.choose(effort: "medium")
        XCTAssertNil(draft.effort)

        draft.choose(kimi)
        draft.choose(effort: "high")
        XCTAssertNil(draft.effort, "a model without levels takes none")
    }

    func testNoSessionModelMeansNothingToSendYet() {
        var draft = ModelDraft(catalog(current: nil, effort: nil))
        XCTAssertFalse(draft.changed)
        draft.choose(effort: "high")
        XCTAssertNil(draft.effort)

        draft.choose(kimi)
        XCTAssertTrue(draft.changed)
    }
}

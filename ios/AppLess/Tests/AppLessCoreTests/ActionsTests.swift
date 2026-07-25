import Foundation
import GenOSCore
import OpenUILang
import Testing

@testable import AppLessCore

/// ActionPlan → ActionEvent, pinned against `spec/openui-lang.md` §9.3-9.4.
@Suite struct ActionsTests {

    private func plan(_ steps: PropObject...) -> ActionPlan {
        ActionPlan(steps: steps.map { PropValue.object($0) })
    }

    // MARK: - Step decoding

    @Test func decodesEveryRuntimeStepType() {
        let decoded = GenosActions.steps(
            of: plan(
                ["type": .string("continue_conversation"), "message": .string("Open settings")],
                [
                    "type": .string("continue_conversation"), "message": .string("Go"),
                    "context": .string("cart"),
                ],
                ["type": .string("open_url"), "url": .string("https://example.com")],
                ["type": .string("set"), "target": .string("$q"), "valueAST": .string("x")],
                ["type": .string("reset"), "targets": .array([.string("$a"), .string("$b")])],
                ["type": .string("run"), "statementId": .string("s1"), "refType": .string("mutation")],
                ["type": .string("nope")]
            ))

        #expect(decoded.count == 7)
        #expect(decoded[0] == .continueConversation(message: "Open settings", context: nil))
        #expect(decoded[1] == .continueConversation(message: "Go", context: "cart"))
        #expect(decoded[2] == .openURL("https://example.com"))
        #expect(decoded[3] == .set(target: "$q", value: .string("x")))
        #expect(decoded[4] == .reset(targets: ["$a", "$b"]))
        #expect(decoded[5] == .run(statementId: "s1", refType: "mutation"))
        #expect(decoded[6] == .unknown("nope"))
    }

    @Test func dropsStepsWithoutAType() {
        let steps = ActionPlan(steps: [
            .string("garbage"),
            .object(["message": .string("no type")]),
            .object(["type": .string("open_url"), "url": .string("u")]),
        ])
        #expect(GenosActions.steps(of: steps) == [.openURL("u")])
    }

    @Test func missingMessageCoercesLikeStringUndefined() {
        let decoded = GenosActions.steps(
            of: plan(["type": .string("continue_conversation")]))
        #expect(decoded == [.continueConversation(message: "", context: nil)])

        let numeric = GenosActions.steps(
            of: plan(["type": .string("continue_conversation"), "message": .number(42)]))
        #expect(numeric == [.continueConversation(message: "42", context: nil)])
    }

    // MARK: - Dispatch

    @Test func noActionSendsTheLabel() {
        // §9.4 step 3 - this is what makes an action-less Button work.
        let outcomes = GenosActions.outcomes(plan: nil, userMessage: "Save draft")
        #expect(outcomes.count == 1)
        guard case .dispatch(let event) = outcomes[0] else {
            Issue.record("expected a dispatch")
            return
        }
        #expect(event.type == .continueConversation)
        #expect(event.humanFriendlyMessage == "Save draft")
        #expect(event.params.isEmpty)
    }

    @Test func toAssistantStepCarriesItsOwnMessageNotTheLabel() {
        let outcomes = GenosActions.outcomes(
            plan: plan([
                "type": .string("continue_conversation"),
                "message": .string("Show the March invoice"),
            ]),
            userMessage: "View")
        guard case .dispatch(let event) = outcomes[0] else {
            Issue.record("expected a dispatch")
            return
        }
        #expect(event.humanFriendlyMessage == "Show the March invoice")
    }

    @Test func contextBecomesAParam() {
        let outcomes = GenosActions.outcomes(
            plan: plan([
                "type": .string("continue_conversation"),
                "message": .string("Go"),
                "context": .string("order 12"),
            ]),
            userMessage: "")
        guard case .dispatch(let event) = outcomes[0] else {
            Issue.record("expected a dispatch")
            return
        }
        #expect(event.params == ["context": .string("order 12")])
    }

    @Test func openUrlCarriesAnEmptyMessage() {
        let outcomes = GenosActions.outcomes(
            plan: plan(["type": .string("open_url"), "url": .string("genos://home")]),
            userMessage: "Home")
        guard case .dispatch(let event) = outcomes[0] else {
            Issue.record("expected a dispatch")
            return
        }
        #expect(event.type == .openURL)
        #expect(event.humanFriendlyMessage == "")
        #expect(event.url == "genos://home")
    }

    @Test func stepsRunInOrderAndStateStepsStayStateSteps() {
        let outcomes = GenosActions.outcomes(
            plan: plan(
                ["type": .string("set"), "target": .string("$filter"), "valueAST": .string("open")],
                ["type": .string("continue_conversation"), "message": .string("Refresh")],
                ["type": .string("reset"), "targets": .array([.string("$filter")])]
            ),
            userMessage: "ignored")
        #expect(outcomes.count == 3)
        #expect(outcomes[0] == .setState(target: "$filter", value: .string("open")))
        #expect(outcomes[2] == .resetState(targets: ["$filter"]))
        guard case .dispatch(let event) = outcomes[1] else {
            Issue.record("expected a dispatch")
            return
        }
        #expect(event.humanFriendlyMessage == "Refresh")
    }

    @Test func anEmptyPlanDispatchesNothing() {
        // react-lang loops the steps; the label default only fires when there
        // is NO plan at all.
        #expect(GenosActions.outcomes(plan: ActionPlan(), userMessage: "Save").isEmpty)
    }

    @Test func formStateAndFormNameRideAlong() {
        var model = FormStateModel()
        model.set(form: "compose", name: "body", componentType: "TextArea", value: .string("hi"))
        let outcomes = GenosActions.outcomes(
            plan: nil,
            userMessage: "Send",
            formName: "compose",
            formState: model.payload(formName: "compose"))
        guard case .dispatch(let event) = outcomes[0] else {
            Issue.record("expected a dispatch")
            return
        }
        #expect(event.formName == "compose")
        #expect(
            event.formState.stringified
                == #"{"compose":{"body":{"componentType":"TextArea","value":"hi"}}}"#)
    }

    // MARK: - Tap gating and Chips

    @Test func onlyActionCarryingRowsAreTappable() {
        #expect(!GenosActions.isTappable(action: nil))
        #expect(GenosActions.isTappable(action: ActionPlan()))
    }

    @Test func chipsMessageIsTheExactRNString() {
        #expect(
            GenosActions.chipsMessage("Unread")
                == "Apply the \"Unread\" filter and re-render this screen with only matching content"
        )
    }

    @Test func chipsMessageMatchesTheSourceLiteral() throws {
        // The literal lives in components.tsx; a drift there must fail here.
        let source = try Repo.text("src/genos/ui/cupertino/components.tsx")
        #expect(source.contains("filter and re-render this screen with only matching content"))
    }
}

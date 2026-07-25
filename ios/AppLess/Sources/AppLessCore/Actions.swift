//
//  Actions.swift
//  AppLessCore
//
//  ActionPlan → ActionEvent, exactly as `spec/openui-lang.md` §9.4 specifies
//  react-lang's `triggerAction(userMessage, formName?, action?)`.
//
//  The shell (`GenOS.tsx handleAction`) consumes only
//  `{ params, humanFriendlyMessage, formState }` plus `formName`, so that is
//  what ``ActionEvent`` carries. Turning an event into a screen is
//  `GenOSCore.Controller.resolveAction`'s job, not this file's.
//
//  NO SwiftUI in this file.
//

import Foundation
import GenOSCore
import OpenUILang

// MARK: - ActionEvent

/// The event a tap dispatches to the shell.
/// `spec/openui-lang.md` Appendix A (`ActionEvent`).
public struct ActionEvent: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable {
        case continueConversation = "continue_conversation"
        case openURL = "open_url"
    }

    public let type: Kind
    /// `{ url }` for `open_url`, `{ context }` when `@ToAssistant` carried one,
    /// empty otherwise.
    public let params: [String: GenosJSONValue]
    /// The `@ToAssistant` message, or the tapped element's label.
    public let humanFriendlyMessage: String
    /// The form payload (see ``FormStateModel/payload(formName:)``).
    public let formState: OrderedJSON
    /// The enclosing `Form`'s name, when the tap happened inside one.
    public let formName: String?

    public init(
        type: Kind,
        params: [String: GenosJSONValue] = [:],
        humanFriendlyMessage: String,
        formState: OrderedJSON = OrderedJSON(),
        formName: String? = nil
    ) {
        self.type = type
        self.params = params
        self.humanFriendlyMessage = humanFriendlyMessage
        self.formState = formState
        self.formName = formName
    }

    /// `params.url`, the value the shell routes on first.
    public var url: String? { params["url"]?.stringValue }
}

// MARK: - Steps

/// One decoded step of an `ActionPlan`.
/// Runtime step type strings: `spec/openui-lang.md` §9.3.
public enum ActionStep: Sendable, Equatable {
    /// `@ToAssistant(msg, ctx?)`.
    case continueConversation(message: String, context: String?)
    /// `@OpenUrl(url)`.
    case openURL(String)
    /// `@Set($var, valueExpr)` - `value` is the DEFERRED expression, evaluated
    /// at click time (`.ast` when it needs the evaluator).
    case set(target: String, value: PropValue?)
    /// `@Reset($a, $b, …)`.
    case reset(targets: [String])
    /// `@Run(ref)` - Query/Mutation, unused in AppLess.
    case run(statementId: String, refType: String?)
    /// A step whose `type` is missing or unrecognized; ignored at dispatch.
    case unknown(String)
}

/// What executing a plan produces, in order: events to dispatch and state
/// writes to apply.
public enum ActionOutcome: Sendable, Equatable {
    case dispatch(ActionEvent)
    case setState(target: String, value: PropValue?)
    case resetState(targets: [String])
    case runStatement(id: String)
}

// MARK: - Dispatch

public enum GenosActions {

    /// Chips carry no action: the tapped LABEL becomes the request.
    /// `components.tsx` L591-596 / `spec/openui-lang.md` §9.4.
    public static func chipsMessage(_ label: String) -> String {
        "Apply the \"\(label)\" filter and re-render this screen with only matching content"
    }

    /// Decode a plan's steps. Non-object entries and entries without a `type`
    /// are already filtered by the parser (§9.3), but the decoder is defensive
    /// anyway.
    public static func steps(of plan: ActionPlan) -> [ActionStep] {
        plan.steps.compactMap { step in
            guard let object = step.objectValue else { return nil }
            guard let type = object["type"]?.stringValue else { return nil }
            switch type {
            case "continue_conversation":
                return .continueConversation(
                    message: jsString(object["message"]),
                    context: object["context"]?.stringValue
                )
            case "open_url":
                return .openURL(jsString(object["url"]))
            case "set":
                return .set(
                    target: object["target"]?.stringValue ?? "",
                    value: object["valueAST"]
                )
            case "reset":
                let targets = (object["targets"]?.arrayValue ?? []).compactMap(\.stringValue)
                return .reset(targets: targets)
            case "run":
                return .run(
                    statementId: object["statementId"]?.stringValue ?? "",
                    refType: object["refType"]?.stringValue
                )
            default:
                return .unknown(type)
            }
        }
    }

    /// The full `triggerAction(userMessage, formName?, action?)` behavior.
    ///
    /// - With an `ActionPlan`, each step becomes an outcome IN ORDER.
    /// - With no plan (an action-less `Button`, or a prop that is not a plan),
    ///   the default `continue_conversation` carrying `userMessage` fires -
    ///   this is what makes an action-less Button "send its label"
    ///   (`spec/openui-lang.md` §9.4 step 3).
    /// - An EMPTY plan produces nothing, matching react-lang: the step loop
    ///   runs zero times and the default only applies when there is no plan.
    public static func outcomes(
        plan: ActionPlan?,
        userMessage: String,
        formName: String? = nil,
        formState: OrderedJSON = OrderedJSON()
    ) -> [ActionOutcome] {
        guard let plan else {
            return [
                .dispatch(
                    ActionEvent(
                        type: .continueConversation,
                        params: [:],
                        humanFriendlyMessage: userMessage,
                        formState: formState,
                        formName: formName
                    ))
            ]
        }
        return steps(of: plan).compactMap { step in
            switch step {
            case .continueConversation(let message, let context):
                var params: [String: GenosJSONValue] = [:]
                if let context { params["context"] = .string(context) }
                return .dispatch(
                    ActionEvent(
                        type: .continueConversation,
                        params: params,
                        humanFriendlyMessage: message,
                        formState: formState,
                        formName: formName
                    ))
            case .openURL(let url):
                return .dispatch(
                    ActionEvent(
                        type: .openURL,
                        params: ["url": .string(url)],
                        humanFriendlyMessage: "",
                        formState: formState,
                        formName: formName
                    ))
            case .set(let target, let value):
                return .setState(target: target, value: value)
            case .reset(let targets):
                return .resetState(targets: targets)
            case .run(let statementId, _):
                return .runStatement(id: statementId)
            case .unknown:
                return nil
            }
        }
    }

    /// `useTap(label, action)` - an element with NO action is inert (the RN
    /// hook returns `undefined` and the row is not pressable), which is why
    /// `ListItem` only shows its chevron when this is `true`.
    /// `shared/actions.ts` L10-16, `components.tsx` L218.
    public static func isTappable(action: ActionPlan?) -> Bool { action != nil }

    /// `String(x ?? "")` for the handful of step fields react-lang coerces.
    private static func jsString(_ value: PropValue?) -> String {
        switch value {
        case .some(.string(let s)): return s
        case .some(.bool(let b)): return b ? "true" : "false"
        case .some(.number(let n)):
            // `JSON.stringify` writes non-finite numbers as null; `String()`
            // spells them out, and that is what a message would show.
            guard n.isFinite else { return n.isNaN ? "NaN" : (n > 0 ? "Infinity" : "-Infinity") }
            return GenosJSONValue.number(n).stringified()
        default: return ""
        }
    }
}

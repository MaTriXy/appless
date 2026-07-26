package dev.appless.uicore

import dev.appless.openuilang.ActionPlan
import dev.appless.openuilang.JsonValue
import dev.appless.openuilang.PropValue

/**
 * ActionPlan -> ActionEvent, exactly as `spec/openui-lang.md` §9.4 specifies
 * react-lang's `triggerAction(userMessage, formName?, action?)`.
 *
 * The shell (`GenOS.tsx handleAction`) consumes only
 * `{ params, humanFriendlyMessage, formState }` plus `formName`, so that is what
 * [ActionEvent] carries. Turning an event into a screen is the controller's job,
 * not this file's.
 *
 * NO Compose in this file.
 */

/** The event a tap dispatches to the shell — `spec/openui-lang.md` Appendix A. */
public data class ActionEvent(
    val type: Kind,
    /**
     * `{ url }` for `open_url`, `{ context }` when `@ToAssistant` carried one,
     * empty otherwise.
     */
    val params: Map<String, JsonValue> = emptyMap(),
    /** The `@ToAssistant` message, or the tapped element's label. */
    val humanFriendlyMessage: String,
    /** The form payload (see [FormStateModel.payload]). */
    val formState: OrderedJson = OrderedJson(),
    /** The enclosing `Form`'s name, when the tap happened inside one. */
    val formName: String? = null,
) {
    public enum class Kind(public val wire: String) {
        CONTINUE_CONVERSATION("continue_conversation"),
        OPEN_URL("open_url"),
    }

    /** `params.url`, the value the shell routes on first. */
    public val url: String? get() = (params["url"] as? JsonValue.Str)?.value
}

/** One decoded step of an `ActionPlan` — runtime step types, `spec/openui-lang.md` §9.3. */
public sealed interface ActionStep {
    /** `@ToAssistant(msg, ctx?)`. */
    public data class ContinueConversation(val message: String, val context: String?) : ActionStep

    /** `@OpenUrl(url)`. */
    public data class OpenUrl(val url: String) : ActionStep

    /**
     * `@Set($var, valueExpr)` — `value` is the DEFERRED expression, evaluated at
     * click time (a `PropValue.Ast` when it needs the evaluator).
     */
    public data class Set(val target: String, val value: PropValue?) : ActionStep

    /** `@Reset($a, $b, …)`. */
    public data class Reset(val targets: List<String>) : ActionStep

    /** `@Run(ref)` — Query/Mutation, unused in AppLess. */
    public data class Run(val statementId: String, val refType: String?) : ActionStep

    /** A step whose `type` is missing or unrecognized; ignored at dispatch. */
    public data class Unknown(val type: String) : ActionStep
}

/**
 * What executing a plan produces, in order: events to dispatch and state writes
 * to apply.
 */
public sealed interface ActionOutcome {
    public data class Dispatch(val event: ActionEvent) : ActionOutcome
    public data class SetState(val target: String, val value: PropValue?) : ActionOutcome
    public data class ResetState(val targets: List<String>) : ActionOutcome
    public data class RunStatement(val id: String) : ActionOutcome
}

public object GenosActions {

    /**
     * Chips carry no action: the tapped LABEL becomes the request —
     * `material/components.tsx` L570-575 / `spec/openui-lang.md` §9.4.
     */
    public fun chipsMessage(label: String): String =
        "Apply the \"$label\" filter and re-render this screen with only matching content"

    /**
     * Decode a plan's steps. Non-object entries and entries without a `type` are
     * already filtered by the parser (§9.3); the decoder is defensive anyway.
     */
    public fun steps(plan: ActionPlan): List<ActionStep> = plan.steps.mapNotNull { step ->
        val obj = (step as? PropValue.Obj)?.entries ?: return@mapNotNull null
        val type = (obj["type"] as? PropValue.Str)?.value ?: return@mapNotNull null
        when (type) {
            "continue_conversation" -> ActionStep.ContinueConversation(
                message = jsString(obj["message"]),
                context = (obj["context"] as? PropValue.Str)?.value,
            )
            "open_url" -> ActionStep.OpenUrl(jsString(obj["url"]))
            "set" -> ActionStep.Set(
                target = (obj["target"] as? PropValue.Str)?.value ?: "",
                value = obj["valueAST"],
            )
            "reset" -> ActionStep.Reset(
                targets = ((obj["targets"] as? PropValue.Arr)?.items ?: emptyList())
                    .mapNotNull { (it as? PropValue.Str)?.value },
            )
            "run" -> ActionStep.Run(
                statementId = (obj["statementId"] as? PropValue.Str)?.value ?: "",
                refType = (obj["refType"] as? PropValue.Str)?.value,
            )
            else -> ActionStep.Unknown(type)
        }
    }

    /**
     * The full `triggerAction(userMessage, formName?, action?)` behavior.
     *
     * - With an `ActionPlan`, each step becomes an outcome IN ORDER.
     * - With NO plan (an action-less `Button`, or a prop that is not a plan),
     *   the default `continue_conversation` carrying `userMessage` fires — this
     *   is what makes an action-less Button "send its label"
     *   (`spec/openui-lang.md` §9.4 step 3).
     * - An EMPTY plan produces nothing, matching react-lang: the step loop runs
     *   zero times and the default only applies when there is no plan at all.
     */
    public fun outcomes(
        plan: ActionPlan?,
        userMessage: String,
        formName: String? = null,
        formState: OrderedJson = OrderedJson(),
    ): List<ActionOutcome> {
        if (plan == null) {
            return listOf(
                ActionOutcome.Dispatch(
                    ActionEvent(
                        type = ActionEvent.Kind.CONTINUE_CONVERSATION,
                        params = emptyMap(),
                        humanFriendlyMessage = userMessage,
                        formState = formState,
                        formName = formName,
                    )
                )
            )
        }
        return steps(plan).mapNotNull { step ->
            when (step) {
                is ActionStep.ContinueConversation -> ActionOutcome.Dispatch(
                    ActionEvent(
                        type = ActionEvent.Kind.CONTINUE_CONVERSATION,
                        params = step.context?.let { mapOf("context" to JsonValue.Str(it)) } ?: emptyMap(),
                        humanFriendlyMessage = step.message,
                        formState = formState,
                        formName = formName,
                    )
                )
                is ActionStep.OpenUrl -> ActionOutcome.Dispatch(
                    ActionEvent(
                        type = ActionEvent.Kind.OPEN_URL,
                        params = mapOf("url" to JsonValue.Str(step.url)),
                        humanFriendlyMessage = "",
                        formState = formState,
                        formName = formName,
                    )
                )
                is ActionStep.Set -> ActionOutcome.SetState(step.target, step.value)
                is ActionStep.Reset -> ActionOutcome.ResetState(step.targets)
                is ActionStep.Run -> ActionOutcome.RunStatement(step.statementId)
                is ActionStep.Unknown -> null
            }
        }
    }

    /**
     * `useTap(label, action)` — an element with NO action is inert (the RN hook
     * returns `undefined` and the row is not pressable), which is why `ListItem`
     * only shows its chevron when this is `true` (`shared/actions.ts` L10-16,
     * `material/components.tsx` L207).
     */
    public fun isTappable(action: ActionPlan?): Boolean = action != null

    /** `String(x ?? "")` for the handful of step fields react-lang coerces. */
    private fun jsString(value: PropValue?): String = when (value) {
        is PropValue.Str -> value.value
        is PropValue.Bool -> if (value.value) "true" else "false"
        is PropValue.Num -> {
            // `JSON.stringify` writes non-finite numbers as null; `String()`
            // spells them out, and that is what a message would show.
            val n = value.value
            if (!n.isFinite()) {
                if (n.isNaN()) "NaN" else if (n > 0) "Infinity" else "-Infinity"
            } else {
                JsonWriter.number(n)
            }
        }
        else -> ""
    }
}

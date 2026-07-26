package dev.appless.app.render

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import dev.appless.openuilang.ActionPlan
import dev.appless.openuilang.ElementNode
import dev.appless.openuilang.PropValue
import dev.appless.uicore.ActionEvent
import dev.appless.uicore.ActionOutcome
import dev.appless.uicore.FormStateModel
import dev.appless.uicore.FormValue
import dev.appless.uicore.GenosActions
import dev.appless.uicore.OrderedJson

/**
 * The Compose equivalents of react-lang's three renderer contexts:
 * `FormNameContext`, `useTriggerAction()` and the field-state store.
 *
 * A renderer is a plain `@Composable` that reads what it needs from these
 * locals, exactly as the RN renderer reads its hooks — which is what keeps
 * `Form` able to scope its fields by name without threading a parameter
 * through every intermediate component.
 */

/** One design system's renderer for one contract component. */
public interface ComposeRenderer {
    /** Draw `node`. Reads context from the composition locals in this file. */
    @Composable
    public fun Render(node: ElementNode)
}

/**
 * `FormNameContext.Provider value={props.name}` — `material/forms.tsx` `Form`.
 *
 * `null` outside any `Form`, which is react-lang's `useFormName()` returning
 * undefined; fields written there land in [FormStateModel.UNSCOPED_FORM_NAME]
 * so a bare `Button` still submits them.
 */
public val LocalFormName: ProvidableCompositionLocal<String?> = compositionLocalOf { null }

/** `useTriggerAction()`. */
public val LocalTriggerAction: ProvidableCompositionLocal<TriggerAction> =
    staticCompositionLocalOf { TriggerAction { _, _, _ -> } }

/** The field-state store every input binds into. */
public val LocalFormStore: ProvidableCompositionLocal<FormStore> =
    staticCompositionLocalOf { FormStore() }

/** `true` while the screen is still generating — `isStreaming` on the Renderer. */
public val LocalIsStreaming: ProvidableCompositionLocal<Boolean> = compositionLocalOf { false }

/** `triggerAction(userMessage, formName?, action?)` — spec §9.4. */
public fun interface TriggerAction {
    public operator fun invoke(userMessage: String, formName: String?, action: ActionPlan?)
}

/**
 * Compose-observable wrapper over `ui-core`'s [FormStateModel].
 *
 * The model is the tested part (ordering, wrapping, payload shape); this adds
 * only the snapshot bookkeeping: every mutation bumps [version], and every read
 * touches it, so a field's composable recomposes when its value changes and
 * nothing else does more work than react-lang's store did.
 */
@Stable
public class FormStore {

    private val model = FormStateModel()

    private var version by mutableIntStateOf(0)

    private fun key(form: String?): String = form ?: FormStateModel.UNSCOPED_FORM_NAME

    /** Current value of a bound field, or `null` when it was never written. */
    public fun value(form: String?, name: String): FormValue? {
        @Suppress("UNUSED_EXPRESSION") version // read: subscribes the caller
        return model.value(key(form), name)
    }

    /** `setFieldValue(formName, componentType, name, next, persist)`. */
    public fun set(form: String?, name: String, componentType: String, value: FormValue) {
        model.set(key(form), name, componentType, value)
        version++
    }

    /**
     * `useSetDefaultValue` — seed the model-supplied `value`/`defaultValue`
     * only while the field has none, so typing is never clobbered by a re-parse
     * mid-stream.
     */
    public fun seedDefault(form: String?, name: String, componentType: String, value: FormValue) {
        if (model.seedDefault(key(form), name, componentType, value)) version++
    }

    /** `@Reset($a, $b, …)`; an empty list clears the whole form. */
    public fun reset(form: String?, names: List<String>) {
        model.reset(key(form), names)
        version++
    }

    /** The `formState` an ActionEvent carries (spec §9.4 step 1). */
    public fun payload(formName: String?): OrderedJson {
        @Suppress("UNUSED_EXPRESSION") version
        return model.payload(formName)
    }
}

/**
 * Turns a tap into [ActionEvent]s, applying the non-dispatch steps in place.
 *
 * The decision table lives in `ui-core`'s [GenosActions] (which is what makes
 * "an action-less Button still sends its label" a tested property rather than
 * an if-statement here); this only routes the outcomes.
 */
public class ActionDispatcher(
    private val formStore: FormStore,
    private val onEvent: (ActionEvent) -> Unit,
) : TriggerAction {

    /**
     * `@Set($var, …)` writes, recorded in call order.
     *
     * openui-lang materializes state from DECLARATIONS at parse time and has no
     * re-evaluation entry point, so a `@Set` cannot re-render the tree the way
     * react-lang's store does. AppLess's system prompt never emits `@Set`
     * (it is not in the contract the model is given), so this is a recorded
     * no-op rather than a silent wrong answer — see the module README.
     */
    public val stateWrites: MutableMap<String, PropValue?> = LinkedHashMap()

    override fun invoke(userMessage: String, formName: String?, action: ActionPlan?) {
        val payload = formStore.payload(formName)
        for (outcome in GenosActions.outcomes(action, userMessage, formName, payload)) {
            when (outcome) {
                is ActionOutcome.Dispatch -> onEvent(outcome.event)
                is ActionOutcome.SetState -> stateWrites[outcome.target] = outcome.value
                is ActionOutcome.ResetState -> formStore.reset(formName, outcome.targets)
                is ActionOutcome.RunStatement -> Unit // Query/Mutation: unused in AppLess.
            }
        }
    }
}

/**
 * `useTap(label, action)` — `ui/shared/actions.tsx`.
 *
 * Returns `null` when there is no action, which is what makes `ListItem`
 * non-pressable (and un-chevroned) without one. Note the RN hook passes
 * `undefined` as the form name: only `Button` submits form state.
 */
@Composable
public fun useTap(label: String?, action: ActionPlan?): (() -> Unit)? {
    val trigger = LocalTriggerAction.current
    if (action == null) return null
    return { trigger(label ?: "", null, action) }
}

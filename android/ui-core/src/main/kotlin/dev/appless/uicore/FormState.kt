package dev.appless.uicore

import dev.appless.openuilang.JsonValue
import dev.appless.openuilang.PropValue
import kotlin.math.abs
import kotlin.math.floor

/**
 * The form-state model the Material form renderers bind into, ported from
 * react-lang's state store as `src/genos/ui/shared/forms.ts` uses it
 * (`useFieldState`) and as `spec/openui-lang.md` §9.4 specifies the payload.
 *
 * Field values are stored per FORM NAME, in UI insertion order, and are wrapped
 * `{ value, componentType }` on the way out — that wrapper is what the model
 * actually receives in "Submitted form values: {...}".
 *
 * NO Compose in this file: the Compose layer wraps this in a `StateFlow`.
 */

/**
 * A value a GenOS input can hold. `Slider` writes a number array (react-lang's
 * range-slider convention, `material/forms.tsx` L199-201); every other input
 * writes a string.
 */
public sealed interface FormValue {
    public data class Str(val value: String) : FormValue
    public data class Num(val value: Double) : FormValue
    public data class Numbers(val values: List<Double>) : FormValue
    public data class Bool(val value: Boolean) : FormValue
    public data object Null : FormValue

    /** The value as it is serialized into the request JSON. */
    public val json: JsonValue
        get() = when (this) {
            is Str -> JsonValue.Str(value)
            is Num -> JsonValue.Num(value)
            is Numbers -> JsonValue.Arr(values.map { JsonValue.Num(it) })
            is Bool -> JsonValue.Bool(value)
            Null -> JsonValue.Null
        }

    /**
     * `typeof field.value === "string" ? field.value : ""` — the guard every
     * text input in `forms.tsx` applies before handing the value to `TextInput`
     * (`material/forms.tsx` L45, L69, L92).
     */
    public val textValue: String
        get() = (this as? Str)?.value ?: ""

    /**
     * `Array.isArray(field.value) ? field.value : [min]` for the Slider —
     * `material/forms.tsx` L199-201.
     */
    public val numbersValue: List<Double>?
        get() = when (this) {
            is Numbers -> values
            is Num -> listOf(value)
            else -> null
        }

    public companion object {
        /**
         * Seed a field from the model-supplied `value` / `defaultValue` prop.
         *
         * Returns `null` for `undefined`-like props (absent or explicit `null`),
         * so an unseeded field stays absent from form state instead of
         * submitting `null`.
         */
        public fun seed(prop: PropValue?): FormValue? = when (prop) {
            null, PropValue.Null -> null
            is PropValue.Str -> Str(prop.value)
            is PropValue.Num -> Num(prop.value)
            is PropValue.Bool -> Bool(prop.value)
            is PropValue.Arr -> {
                val numbers = prop.items.mapNotNull { (it as? PropValue.Num)?.value }
                if (numbers.size == prop.items.size && numbers.isNotEmpty()) Numbers(numbers) else null
            }
            else -> null
        }
    }
}

/**
 * Every named input's value, grouped by the enclosing `Form`'s `name`.
 *
 * Insertion order is preserved per form because the request JSON must list
 * fields in UI order.
 */
public class FormStateModel {

    /** One bound input. */
    public data class Field(
        val name: String,
        /**
         * The contract component that owns the field — `"Input"`, `"Select"`,
         * `"Slider"`, … It ships to the model inside the value wrapper.
         */
        val componentType: String,
        val value: FormValue,
    ) {
        /** `{ value, componentType }` — `spec/openui-lang.md` §9.4 step 1. */
        public val wrapped: JsonValue
            get() = JsonValue.Obj(
                linkedMapOf("value" to value.json, "componentType" to JsonValue.Str(componentType))
            )
    }

    private val formOrder = mutableListOf<String>()
    private val fieldsByForm = LinkedHashMap<String, MutableList<Field>>()

    // ------------------------------------------------------------------ reads

    /** Form names in the order their first field was written. */
    public val formNames: List<String> get() = formOrder.toList()

    /** Fields of one form, in insertion order. */
    public fun fields(form: String): List<Field> = fieldsByForm[form]?.toList() ?: emptyList()

    public fun field(form: String, name: String): Field? =
        fieldsByForm[form]?.firstOrNull { it.name == name }

    public fun value(form: String, name: String): FormValue? = field(form, name)?.value

    public val isEmpty: Boolean get() = formOrder.isEmpty()

    // ----------------------------------------------------------------- writes

    /**
     * Write a field, creating it (and its form bucket) if needed. An existing
     * field keeps its position — this is `setFieldValue`.
     */
    public fun set(form: String, name: String, componentType: String, value: FormValue) {
        val fields = fieldsByForm.getOrPut(form) {
            if (form !in formOrder) formOrder += form
            mutableListOf()
        }
        val index = fields.indexOfFirst { it.name == name }
        if (index >= 0) {
            fields[index] = fields[index].copy(value = value)
        } else {
            fields += Field(name, componentType, value)
        }
    }

    /**
     * Seed a model-supplied default, but only when the field has no value yet —
     * `useSetDefaultValue` (`shared/forms.ts` L24-30).
     *
     * @return `true` when the seed was applied.
     */
    public fun seedDefault(
        form: String,
        name: String,
        componentType: String,
        value: FormValue,
    ): Boolean {
        if (field(form, name) != null) return false
        set(form, name, componentType, value)
        return true
    }

    /**
     * `@Reset($a, $b, …)` — drop the named fields back to "not set". Passing no
     * names clears the whole form.
     */
    public fun reset(form: String, names: List<String> = emptyList()) {
        val fields = fieldsByForm[form] ?: return
        if (names.isEmpty()) {
            fields.clear()
        } else {
            fields.removeAll { it.name in names }
        }
        if (fields.isEmpty()) {
            fieldsByForm.remove(form)
            formOrder.remove(form)
        }
    }

    // ---------------------------------------------------------------- payload

    /** One form as `{ field: { value, componentType }, … }`. */
    public fun payloadObject(form: String): JsonValue {
        val obj = LinkedHashMap<String, JsonValue>()
        for (field in fields(form)) obj[field.name] = field.wrapped
        return JsonValue.Obj(obj)
    }

    /**
     * The `formState` an ActionEvent carries (`spec/openui-lang.md` §9.4 step 1):
     * with a `formName` that HAS data, just that form; otherwise the whole store
     * snapshot.
     */
    public fun payload(formName: String?): OrderedJson {
        if (formName != null && fields(formName).isNotEmpty()) {
            return OrderedJson(listOf(formName to payloadObject(formName)))
        }
        return OrderedJson(formOrder.map { it to payloadObject(it) })
    }

    public companion object {
        /**
         * Fields written outside any `Form` land here (react-lang's
         * `useFormName()` is undefined there); kept as its own bucket so a bare
         * `Button` still submits them in the whole-store snapshot.
         */
        public const val UNSCOPED_FORM_NAME: String = ""
    }
}

/**
 * A JSON object whose key order is meaningful — the shape the controller
 * serializes with `JSON.stringify`, which preserves insertion order.
 */
public data class OrderedJson(public val pairs: List<Pair<String, JsonValue>> = emptyList()) {

    public val keys: List<String> get() = pairs.map { it.first }
    public val values: List<JsonValue> get() = pairs.map { it.second }
    public val isEmpty: Boolean get() = pairs.isEmpty()
    public val size: Int get() = pairs.size

    public operator fun get(key: String): JsonValue? = pairs.firstOrNull { it.first == key }?.second

    /**
     * `JSON.stringify(formState)`.
     *
     * The FORM-NAME level is an object like any other, so it gets
     * [JsonWriter.jsOwnKeyOrder] too - a form named `"2"` hoists ahead of one
     * named `"checkout"`.
     */
    public fun stringified(): String {
        val byKey = pairs.associate { it }
        return JsonWriter.jsOwnKeyOrder(pairs.map { it.first })
            .joinToString(",", prefix = "{", postfix = "}") { k ->
                JsonWriter.string(k) + ":" + JsonWriter.write(byKey.getValue(k))
            }
    }
}

/**
 * `JSON.stringify` for [JsonValue], matching JS number formatting and string
 * escaping.
 *
 * Object keys follow `OrdinaryOwnPropertyKeys` (ES 10.1.11.1) at EVERY depth,
 * NOT raw map order: every canonical array index first in ascending NUMERIC
 * order, then the remaining keys in insertion order (the maps built here are
 * `LinkedHashMap`s, so that is the order they were written in).
 */
public object JsonWriter {

    public fun write(value: JsonValue): String = when (value) {
        JsonValue.Null -> "null"
        is JsonValue.Bool -> if (value.value) "true" else "false"
        is JsonValue.Num -> number(value.value)
        is JsonValue.Str -> string(value.value)
        is JsonValue.Arr -> value.value.joinToString(",", "[", "]") { write(it) }
        is JsonValue.Obj -> jsOwnKeyOrder(value.value.keys).joinToString(",", "{", "}") { k ->
            string(k) + ":" + write(value.value.getValue(k))
        }
    }

    /** Largest canonical array index: 2^32 - 2. `"4294967295"` is NOT one. */
    private const val MAX_ARRAY_INDEX: Long = 4294967294L

    /**
     * The numeric value of [key] when it is a *canonical array index* - a
     * string `k` with `ToString(ToUint32(k)) === k` - else -1.
     *
     * Canonical rules out a leading zero (`"01"`), a sign, whitespace, a
     * decimal point, an exponent, and anything above 2^32 - 2.
     */
    private fun canonicalArrayIndex(key: String): Long {
        val n = key.length
        if (n == 0 || n > 10) return -1
        if (key[0] == '0' && n > 1) return -1
        var value = 0L
        for (c in key) {
            if (c < '0' || c > '9') return -1
            value = value * 10 + (c - '0')
        }
        return if (value > MAX_ARRAY_INDEX) -1 else value
    }

    /**
     * `OrdinaryOwnPropertyKeys`: indices first, ascending numerically; then
     * every other key in the order given (for a `LinkedHashMap`, insertion
     * order).
     *
     * Pinned against node:
     * ```
     * let h={}; for (const k of ["b","10","2","a","4294967294","4294967295","01"])
     *   h={...h,[k]:1};
     * Object.keys(h)
     * // ["2","10","4294967294","b","a","4294967295","01"]
     * ```
     *
     * Note this is NOT the same total order as the parser's
     * `JS_OWN_KEY_ORDER`: that one serves `serialize.mjs`, which does
     * `Object.keys(v).sort()` first, so its non-index keys come out in
     * code-unit order. Here the non-index keys keep INSERTION order, because
     * react-lang's form store never sorts - it writes
     * `{ ...formData, [name]: wrapped }`.
     */
    internal fun jsOwnKeyOrder(keys: Collection<String>): List<String> {
        val indices = ArrayList<String>()
        val rest = ArrayList<String>()
        for (k in keys) if (canonicalArrayIndex(k) >= 0) indices.add(k) else rest.add(k)
        if (indices.isEmpty()) return rest
        indices.sortBy { canonicalArrayIndex(it) }
        return indices + rest
    }

    /** `JSON.stringify(n)`: non-finite numbers become `null`, integers lose `.0`. */
    public fun number(n: Double): String {
        if (!n.isFinite()) return "null"
        if (n == 0.0) return "0"
        if (n == floor(n) && abs(n) < 1e21) return n.toLong().toString()
        val s = n.toString()
        return if (s.endsWith(".0")) s.dropLast(2) else s
    }

    public fun string(s: String): String {
        val sb = StringBuilder(s.length + 2)
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
            }
        }
        sb.append('"')
        return sb.toString()
    }
}

/** Input behavior derived from the contract's input `type` — `shared/forms.ts` L36-52. */
public object InputBehavior {

    /** `KEYBOARD` — `shared/forms.ts` L36-40. */
    public val keyboardTypes: Map<String, String> = linkedMapOf(
        "email" to "email-address",
        "number" to "numeric",
        "url" to "url",
    )

    /** `secureTextEntry: type === "password"` — `shared/forms.ts` L45. */
    public fun isSecure(type: String?): Boolean = type == "password"

    /** `KEYBOARD[type ?? "text"] ?? "default"` — `shared/forms.ts` L46. */
    public fun keyboardType(type: String?): String =
        keyboardTypes[type ?: "text"] ?: "default"

    /**
     * `type === "email" || type === "url" ? "none" : "sentences"` —
     * `shared/forms.ts` L47-50.
     */
    public fun autoCapitalize(type: String?): String =
        if (type == "email" || type == "url") "none" else "sentences"
}

/** One decoded `SelectItem` — `shared/forms.ts` `SelectItemProps` L55-58. */
public data class SelectOption(val value: String?, val label: String?) {
    /** `it.label ?? it.value` — `material/forms.tsx` L175. */
    public val displayLabel: String? get() = label ?: value
}

/**
 * `readSelectItems` — `shared/forms.ts` L61-65. Decodes react-lang's evaluated
 * `SelectItem` elements into plain options; entries without props are dropped.
 */
public fun readSelectItems(items: PropValue?): List<SelectOption> =
    (items as? PropValue.Arr)?.items.orEmpty().mapNotNull { entry ->
        val props = when (entry) {
            is PropValue.Element -> entry.node.props
            is PropValue.Obj -> entry.entries.entries.toMap()
            else -> return@mapNotNull null
        }
        SelectOption(
            value = (props["value"] as? PropValue.Str)?.value,
            label = (props["label"] as? PropValue.Str)?.value,
        )
    }

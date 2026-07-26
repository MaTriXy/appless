package dev.appless.openuilang

/**
 * A generic, order-agnostic JSON tree. Used to hold the raw contract schema
 * body loaded from `spec/contract/genos.schema.json`.
 *
 * Mirrors `JSONValue.swift` in the Swift port. Hand-rolled rather than
 * delegated to a JSON library so the module has no third-party runtime
 * dependency and so number handling stays IEEE-double exactly like JS.
 */
public sealed interface JsonValue {
    public data object Null : JsonValue
    public data class Bool(val value: Boolean) : JsonValue
    public data class Num(val value: Double) : JsonValue
    public data class Str(val value: String) : JsonValue
    public data class Arr(val value: List<JsonValue>) : JsonValue
    public data class Obj(val value: Map<String, JsonValue>) : JsonValue

    public operator fun get(key: String): JsonValue? =
        (this as? Obj)?.value?.get(key)

    public val stringValue: String?
        get() = (this as? Str)?.value

    public val arrayValue: List<JsonValue>?
        get() = (this as? Arr)?.value

    public val objectValue: Map<String, JsonValue>?
        get() = (this as? Obj)?.value

    public val boolValue: Boolean?
        get() = (this as? Bool)?.value

    public val numberValue: Double?
        get() = (this as? Num)?.value

    public companion object {
        /** Parses a complete JSON document. Throws [JsonParseException] on bad input. */
        public fun parse(text: String): JsonValue = JsonReader(text).parseDocument()
    }
}

public class JsonParseException(message: String) : RuntimeException(message)

/**
 * Minimal recursive-descent JSON reader over UTF-16 code units. Only used to
 * load the contract; it is not on the openui-lang parsing path.
 */
private class JsonReader(private val src: String) {
    private var i = 0

    fun parseDocument(): JsonValue {
        skipWhitespace()
        val value = parseValue()
        skipWhitespace()
        if (i != src.length) fail("trailing content at offset $i")
        return value
    }

    private fun fail(what: String): Nothing = throw JsonParseException("invalid JSON: $what")

    private fun skipWhitespace() {
        while (i < src.length) {
            when (src[i]) {
                ' ', '\t', '\n', '\r' -> i++
                else -> return
            }
        }
    }

    private fun parseValue(): JsonValue {
        if (i >= src.length) fail("unexpected end of input")
        return when (val c = src[i]) {
            '{' -> parseObject()
            '[' -> parseArray()
            '"' -> JsonValue.Str(parseString())
            't' -> { expect("true"); JsonValue.Bool(true) }
            'f' -> { expect("false"); JsonValue.Bool(false) }
            'n' -> { expect("null"); JsonValue.Null }
            else -> if (c == '-' || c in '0'..'9') parseNumber() else fail("unexpected '$c' at $i")
        }
    }

    private fun expect(literal: String) {
        if (!src.startsWith(literal, i)) fail("expected '$literal' at $i")
        i += literal.length
    }

    private fun parseObject(): JsonValue {
        i++ // '{'
        val out = LinkedHashMap<String, JsonValue>()
        skipWhitespace()
        if (i < src.length && src[i] == '}') { i++; return JsonValue.Obj(out) }
        while (true) {
            skipWhitespace()
            if (i >= src.length || src[i] != '"') fail("expected object key at $i")
            val key = parseString()
            skipWhitespace()
            if (i >= src.length || src[i] != ':') fail("expected ':' at $i")
            i++
            skipWhitespace()
            out[key] = parseValue()
            skipWhitespace()
            if (i >= src.length) fail("unterminated object")
            when (src[i]) {
                ',' -> i++
                '}' -> { i++; return JsonValue.Obj(out) }
                else -> fail("expected ',' or '}' at $i")
            }
        }
    }

    private fun parseArray(): JsonValue {
        i++ // '['
        val out = ArrayList<JsonValue>()
        skipWhitespace()
        if (i < src.length && src[i] == ']') { i++; return JsonValue.Arr(out) }
        while (true) {
            skipWhitespace()
            out.add(parseValue())
            skipWhitespace()
            if (i >= src.length) fail("unterminated array")
            when (src[i]) {
                ',' -> i++
                ']' -> { i++; return JsonValue.Arr(out) }
                else -> fail("expected ',' or ']' at $i")
            }
        }
    }

    private fun parseString(): String {
        i++ // opening quote
        val sb = StringBuilder()
        while (true) {
            if (i >= src.length) fail("unterminated string")
            when (val c = src[i]) {
                '"' -> { i++; return sb.toString() }
                '\\' -> {
                    i++
                    if (i >= src.length) fail("unterminated escape")
                    when (val e = src[i]) {
                        '"' -> { sb.append('"'); i++ }
                        '\\' -> { sb.append('\\'); i++ }
                        '/' -> { sb.append('/'); i++ }
                        'b' -> { sb.append('\b'); i++ }
                        'f' -> { sb.append(''); i++ }
                        'n' -> { sb.append('\n'); i++ }
                        'r' -> { sb.append('\r'); i++ }
                        't' -> { sb.append('\t'); i++ }
                        'u' -> {
                            if (i + 4 >= src.length) fail("truncated \\u escape at $i")
                            val hex = src.substring(i + 1, i + 5)
                            val code = hex.toIntOrNull(16) ?: fail("bad \\u escape '$hex'")
                            // Kotlin String is UTF-16 like JS: a lone surrogate
                            // survives verbatim, exactly as JSON.parse keeps it.
                            sb.append(code.toChar())
                            i += 5
                        }
                        else -> fail("bad escape '\\$e' at $i")
                    }
                }
                else -> { sb.append(c); i++ }
            }
        }
    }

    private fun parseNumber(): JsonValue {
        val start = i
        if (i < src.length && src[i] == '-') i++
        while (i < src.length && src[i] in '0'..'9') i++
        if (i < src.length && src[i] == '.') {
            i++
            while (i < src.length && src[i] in '0'..'9') i++
        }
        if (i < src.length && (src[i] == 'e' || src[i] == 'E')) {
            i++
            if (i < src.length && (src[i] == '+' || src[i] == '-')) i++
            while (i < src.length && src[i] in '0'..'9') i++
        }
        val text = src.substring(start, i)
        val d = text.toDoubleOrNull() ?: fail("bad number '$text'")
        return JsonValue.Num(d)
    }
}

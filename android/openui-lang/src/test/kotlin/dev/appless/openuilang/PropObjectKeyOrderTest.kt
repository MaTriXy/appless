package dev.appless.openuilang

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

/**
 * [PropObject] is public API, so its iteration order is part of the contract.
 *
 * It is `Object.keys(o)` order — `OrdinaryOwnPropertyKeys` (ES 10.1.11.1):
 * canonical array indices FIRST in ascending numeric order, then every
 * remaining key in insertion order. Not raw insertion order (which would
 * mis-place index keys) and not the serializer's order (which additionally
 * SORTS the string group, because the reference serializer does
 * `Object.keys(v).sort()` before re-inserting — fixture
 * `075-object-key-index-order` pins that side).
 *
 * Not a corpus fixture: the serializer re-orders anyway, so nothing here is
 * tree-observable — this test exists precisely because a renderer iterating
 * props directly WOULD observe it.
 */
class PropObjectKeyOrderTest {

    private fun of(vararg keys: String): PropObject =
        PropObject(keys.mapIndexed { i, k -> k to (PropValue.Num(i.toDouble()) as PropValue) })

    /** Index keys hoist ahead of string keys, numerically — `"10"` after `"2"`. */
    @Test
    fun indicesHoistAheadOfStringKeys() {
        val o = of("beta", "10", "alpha", "2", "0")
        assertEquals(listOf("0", "2", "10", "beta", "alpha"), o.keys)
        assertEquals(o.keys, o.entries.map { it.first })
    }

    /** Without any index key the order is plain insertion order. */
    @Test
    fun stringOnlyObjectKeepsInsertionOrder() {
        val o = of("zeta", "alpha", "mid")
        assertEquals(listOf("zeta", "alpha", "mid"), o.keys)
    }

    /**
     * `"4294967295"` is 2^32-1 and therefore NOT an array index; `"01"` has a
     * redundant leading zero. Both stay in the string group.
     */
    @Test
    fun nonCanonicalDigitStringsStayInTheStringGroup() {
        val o = of("4294967295", "01", "4294967294", "-0")
        assertEquals(listOf("4294967294", "4294967295", "01", "-0"), o.keys)
    }

    /** A re-assignment keeps the original slot, exactly like JS. */
    @Test
    fun rewriteKeepsOriginalPosition() {
        val o = of("a", "b", "c")
        o["a"] = PropValue.Str("again")
        assertEquals(listOf("a", "b", "c"), o.keys)
        assertEquals(PropValue.Str("again"), o["a"])
    }

    /**
     * The serializer's order is a DIFFERENT order — string keys sorted, not in
     * insertion order — and must stay that way.
     */
    @Test
    fun serializerOrderStillSortsTheStringGroup() {
        val result = ParseResult(
            state = mapOf("\$s" to PropValue.Obj(of("beta", "10", "alpha", "2"))),
        )
        val json = TreeSerializer.serialize(result)
        val body = json.substringAfter("\"\$s\": {").substringBefore("}")
        val order = Regex("\"([^\"]+)\":").findAll(body).map { it.groupValues[1] }.toList()
        assertEquals(listOf("2", "10", "alpha", "beta"), order)
    }
}

package dev.appless.openuilang

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Schema `default` application (`Materialize.materializeComp`, port of
 * lang-core `materializeValue` + `getSchemaDefaultValue`): a missing or `null`
 * REQUIRED prop takes the JSON Schema property's `default` BEFORE
 * `missing-required` / `null-required` is reported.
 *
 * The shipped GenOS contract declares no `default` anywhere, so this branch is
 * dead across all 97 fixtures — which is exactly why it needs a unit test: a
 * regression in it would be invisible to the oracle suite. The schema below is
 * hand-built for that reason.
 *
 * Mirrors `SchemaDefaultValueTests` in
 * `ios/Packages/OpenUILang/Tests/OpenUILangTests/StreamingSemanticsTests.swift`.
 */
class SchemaDefaultValueTest {

    private fun makeSchema(): LibrarySchema = LibrarySchema(
        root = "Card",
        components = listOf("Card", "Badge"),
        paramOrder = mapOf(
            "Card" to listOf(LibrarySchema.Param("children", required = true)),
            "Badge" to listOf(
                LibrarySchema.Param(
                    name = "label",
                    required = true,
                    defaultValue = JsonValue.Str("fallback"),
                ),
                LibrarySchema.Param(name = "count", required = true),
            ),
        ),
        schema = JsonValue.Obj(emptyMap()),
    )

    /** An explicit `null` in a required slot is replaced by the default. */
    @Test
    fun defaultFillsNullRequiredProp() {
        val result = OpenUIParser(makeSchema()).parse("root = Card([Badge(null, 3)])\n")
        assertTrue(result.meta.errors.isEmpty(), "unexpected errors: ${result.meta.errors}")

        val children = result.root?.children
        assertTrue(children is PropValue.Arr, "expected an array of children, got $children")
        val badge = (children as PropValue.Arr).items.firstOrNull()
        assertTrue(badge is PropValue.Element, "expected a Badge element child, got $badge")
        val node = (badge as PropValue.Element).node

        assertEquals("Badge", node.component)
        assertEquals(PropValue.Str("fallback"), node.props["label"])
        assertEquals(PropValue.Num(3.0), node.props["count"])
    }

    /**
     * `label`'s default is applied, but `count` has none: exactly one
     * `missing-required` error and the element is dropped from the array.
     */
    @Test
    fun missingPropWithoutDefaultStillErrors() {
        val result = OpenUIParser(makeSchema()).parse("root = Card([Badge(null)])\n")

        assertEquals(1, result.meta.errors.size, "errors: ${result.meta.errors}")
        assertEquals(ParseError.Code.MISSING_REQUIRED, result.meta.errors[0].code)
        assertEquals("/count", result.meta.errors[0].path)

        val children = result.root?.children
        assertTrue(children is PropValue.Arr, "expected an array of children, got $children")
        assertTrue((children as PropValue.Arr).items.isEmpty(), "Badge should have been dropped")
    }

    /**
     * Guard on the premise: the real contract file currently carries no
     * `default` for any property, so loading it must yield null defaultValues
     * everywhere. If a `default` ever ships, the fixtures must be regenerated
     * and this test updated deliberately.
     */
    @Test
    fun shippedContractHasNoDefaults() {
        val schema = LibrarySchema.load(FixtureCorpus.schemaFile)
        val withDefaults = schema.paramOrder.entries
            .flatMap { (component, params) ->
                params.filter { it.defaultValue != null }.map { "$component.${it.name}" }
            }
        assertTrue(withDefaults.isEmpty(), "contract gained defaults: $withDefaults")
    }
}
